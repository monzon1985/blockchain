// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {AllocatorVault} from "../../src/AllocatorVault.sol";
import {VaultRoles} from "../../src/access/VaultRoles.sol";
import {IAllocatorVault} from "../../src/interfaces/IAllocatorVault.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {
    MockIlliquidStrategy,
    MockLiquidStrategy,
    MockLossyStrategy,
    MockPausableStrategy,
    MockStrategyBase
} from "../mocks/MockStrategies.sol";

/// @dev Minimal HEVM cheat-code interface (supported by Medusa and Foundry).
interface IHevm {
    function warp(uint256 timestamp) external;
}

/// @notice Second share holder, so solvency is checked across several holders. It lets the harness spend its shares.
contract MedusaActor {
    constructor(IERC4626 vault) {
        vault.approve(msg.sender, type(uint256).max);
    }
}

/// @notice Medusa harness. It deploys an AccessManager, the vault (fees on) and four strategies (one of them
///         pausable), holds every role, and acts as depositor, allocator, curator, guardian, keeper and "the market"
///         (strategy yield, losses, donations, lending, pauses). Medusa calls the actions in random order with random
///         time gaps.
///         Property mode checks the seven `property_*` functions after every call; they mirror the Foundry invariants
///         I1-I6 and I8:
///         - solvency: the redeemable value of all holders never exceeds `totalAssets`;
///         - backing: the counted gross assets never exceed idle plus each strategy's own valuation of the vault's
///           shares, and the locked profit is part of the booked value;
///         - the share price never decreases within an action unless the action can lose value;
///         - fee shares minted by an accrual are worth at most fee rate x gain above the high-water mark, both priced
///           at the totals that accrual used, plus the management fee for the elapsed time;
///         - the high-water mark never decreases; an accrual writes what `previewAccrual` predicted;
///         - the rate-limited price is never above the share price.
///         Assertion mode checks the `assert`s inside the four ERC-4626 actions: `deposit`, `mint`, `withdraw` and
///         `redeem` execute exactly at their preview, and a `withdraw`/`redeem` bounded by `maxWithdraw`/`maxRedeem`
///         (and a deposit allowed by `maxDeposit`) never reverts. State is kept internal so that Medusa does not list
///         getters, which cannot fail, as assertion tests.
contract AllocatorVaultMedusa {
    IHevm internal constant HEVM = IHevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
    uint256 internal constant V = 1e6;
    uint256 internal constant RAY = 1e27;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant YEAR = 365 days;
    uint256 internal constant MAX_AMOUNT = 1e30;
    uint256 internal constant CAP = 1e36;
    address internal constant FEE_RECIPIENT = address(0xFEE);

    AccessManager internal immutable manager;
    AllocatorVault internal immutable vault;
    MockERC20 internal immutable asset;
    MockLiquidStrategy internal immutable liquid;
    MockLossyStrategy internal immutable lossy;
    MockIlliquidStrategy internal immutable illiquid;
    MockPausableStrategy internal immutable pausable;
    MedusaActor internal immutable actor;

    bool internal priceDroppedWithoutLoss;
    bool internal feeAboveBound;
    bool internal highWaterMarkDecreased;
    bool internal accrualMismatch;

    struct Pre {
        uint256 totalAssets;
        uint256 supplyWithFees;
        uint256 supply;
        uint256 hwm;
        uint256 lastAccrual;
        uint256 recipientShares;
        uint256 tolerance;
    }

    constructor() {
        asset = new MockERC20("Mock USD", "mUSD", 18);
        manager = new AccessManager(address(this));
        vault = new AllocatorVault(
            AllocatorVault.InitParams({
                asset: IERC20(address(asset)),
                name: "Curated USD Vault",
                symbol: "cvUSD",
                authority: address(manager),
                feeRecipient: FEE_RECIPIENT,
                performanceFee: 0.2e18,
                managementFee: 0.02e18,
                maxSharePriceGrowthPerYear: 0.25e18
            })
        );
        VaultRoles.configure(manager, address(vault));
        manager.grantRole(VaultRoles.CURATOR, address(this), 0);
        manager.grantRole(VaultRoles.ALLOCATOR, address(this), 0);
        manager.grantRole(VaultRoles.GUARDIAN, address(this), 0);

        liquid = new MockLiquidStrategy(IERC20(address(asset)));
        lossy = new MockLossyStrategy(IERC20(address(asset)));
        illiquid = new MockIlliquidStrategy(IERC20(address(asset)));
        pausable = new MockPausableStrategy(IERC20(address(asset)));
        vault.submitCap(liquid, CAP);
        vault.submitCap(lossy, CAP);
        vault.submitCap(illiquid, CAP);
        vault.submitCap(pausable, CAP);
        HEVM.warp(block.timestamp + vault.TIMELOCK());
        vault.acceptCap(liquid);
        vault.acceptCap(lossy);
        vault.acceptCap(illiquid);
        vault.acceptCap(pausable);

        actor = new MedusaActor(vault);
        asset.approve(address(vault), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                                ACTIONS
    //////////////////////////////////////////////////////////////*/

    function deposit(uint256 assets, bool toActor) external {
        assets = _clamp(assets, 0, MAX_AMOUNT);
        if (vault.maxDeposit(address(this)) == 0) return; // paused while a position is impaired
        uint256 expected = vault.previewDeposit(assets);
        if (assets != 0 && expected == 0) return; // reverts with ZeroShares by design
        asset.mint(address(this), assets);
        Pre memory p = _pre(false);
        try vault.deposit(assets, toActor ? address(actor) : address(this)) returns (uint256 shares) {
            assert(shares == expected);
        } catch {
            assert(false); // allowed by maxDeposit and previewDeposit: must not revert
        }
        _post(p, false);
    }

    function mint(uint256 shares, bool toActor) external {
        if (vault.maxMint(address(this)) == 0) return; // paused while a position is impaired
        shares = _clamp(shares, 0, vault.convertToShares(MAX_AMOUNT));
        uint256 expected = vault.previewMint(shares);
        asset.mint(address(this), expected);
        Pre memory p = _pre(false);
        try vault.mint(shares, toActor ? address(actor) : address(this)) returns (uint256 assets) {
            assert(assets == expected);
        } catch {
            assert(false);
        }
        _post(p, false);
    }

    function withdraw(uint256 assets, bool fromActor) external {
        address owner = fromActor ? address(actor) : address(this);
        assets = _clamp(assets, 0, vault.maxWithdraw(owner));
        uint256 expected = vault.previewWithdraw(assets);
        Pre memory p = _pre(true);
        try vault.withdraw(assets, address(this), owner) returns (uint256 shares) {
            assert(shares == expected);
        } catch {
            assert(false); // bounded by maxWithdraw: must not revert
        }
        _post(p, false);
    }

    function redeem(uint256 shares, bool fromActor) external {
        address owner = fromActor ? address(actor) : address(this);
        shares = _clamp(shares, 0, vault.maxRedeem(owner));
        uint256 expected = vault.previewRedeem(shares);
        Pre memory p = _pre(true);
        try vault.redeem(shares, address(this), owner) returns (uint256 assets) {
            assert(assets == expected);
        } catch {
            assert(false); // bounded by maxRedeem: must not revert
        }
        _post(p, false);
    }

    function reallocate(uint256 strategySeed, uint256 target) external {
        IERC4626 strategy = _strategy(strategySeed);
        if (!vault.config(strategy).enabled) return;
        if (address(strategy) == address(pausable) && pausable.paused()) return;
        uint256 shares = strategy.balanceOf(address(vault));
        uint256 current = shares == 0 ? 0 : strategy.previewRedeem(shares);
        uint256 withdrawable = strategy.maxWithdraw(address(vault));
        uint256 lower = current > withdrawable ? current - withdrawable : 0;
        uint256 upper = Math.min(current + asset.balanceOf(address(vault)), vault.config(strategy).cap);
        if (upper < lower) return;
        target = _clamp(target, lower, upper);
        if (target == 0 && shares != 0 && strategy.maxRedeem(address(vault)) < shares) return;

        IAllocatorVault.Allocation[] memory allocations = new IAllocatorVault.Allocation[](1);
        allocations[0] = IAllocatorVault.Allocation({strategy: strategy, assets: target});
        Pre memory p = _pre(true);
        vault.reallocate(allocations);
        _post(p, false);
    }

    function strategyYield(uint256 strategySeed, uint256 amount) external {
        MockStrategyBase strategy = MockStrategyBase(address(_strategy(strategySeed)));
        amount = _clamp(amount, 0, strategy.totalAssets() / 10 + 1e18);
        Pre memory p = _pre(false);
        strategy.simulateYield(amount);
        _post(p, false);
    }

    function strategyLoss(uint256 amount) external {
        amount = _clamp(amount, 0, asset.balanceOf(address(lossy)));
        Pre memory p = _pre(false);
        lossy.simulateLoss(amount);
        _post(p, true);
    }

    function donate(uint256 amount) external {
        amount = _clamp(amount, 0, 1e24);
        Pre memory p = _pre(false);
        asset.mint(address(vault), amount);
        _post(p, false);
    }

    function lend(uint256 amount) external {
        amount = _clamp(amount, 0, illiquid.cash());
        Pre memory p = _pre(false);
        illiquid.lend(amount);
        _post(p, false); // the vault never counts a position at the strategy's live liquidity
    }

    function repay(uint256 amount) external {
        amount = _clamp(amount, 0, illiquid.lentOut());
        Pre memory p = _pre(false);
        illiquid.repay(amount);
        _post(p, false);
    }

    function setPaused(bool paused) external {
        Pre memory p = _pre(false);
        pausable.setPaused(paused);
        _post(p, paused);
    }

    function startRemoval(uint256 strategySeed) external {
        IERC4626 strategy = _removable(strategySeed);
        IAllocatorVault.StrategyConfig memory cfg = vault.config(strategy);
        if (!cfg.enabled || cfg.removableAt != 0) return;
        vault.zeroCap(strategy);
        Pre memory p = _pre(false);
        vault.submitStrategyRemoval(strategy);
        _post(p, true);
    }

    function revokeRemoval(uint256 strategySeed) external {
        IERC4626 strategy = _removable(strategySeed);
        if (vault.config(strategy).removableAt == 0) return;
        Pre memory p = _pre(false);
        vault.revokePendingRemoval(strategy);
        _post(p, false);
    }

    function removeStrategy(uint256 strategySeed) external {
        IERC4626 strategy = _removable(strategySeed);
        IAllocatorVault.StrategyConfig memory cfg = vault.config(strategy);
        if (!cfg.enabled) return;
        if (cfg.removableAt == 0 || block.timestamp < cfg.removableAt) {
            if (address(strategy) == address(pausable) && pausable.paused()) return;
            uint256 shares = strategy.balanceOf(address(vault));
            if (shares != 0 && strategy.maxRedeem(address(vault)) < shares) return;
        }
        if (cfg.cap != 0) vault.zeroCap(strategy);
        // `removeStrategy` accrues twice: first at the current state, then, after redeeming and dropping the position,
        // again to realize the write-off or, if the position was impaired and has been recovered since, the deferred
        // PnL. Its first accrual is made explicit here (and checked like any other), so the removal's own first accrual
        // is a no-op and every fee share the removal mints comes from its final accrual. That accrual prices the fee at
        // the post-removal totals, which the pre-action preview does not include.
        _accrueChecked();
        Pre memory p = _pre(true);
        vault.removeStrategy(strategy);
        _checkPriceAndMark(p, false);
        _checkFees(p, vault.totalAssets());
    }

    function relist(uint256 strategySeed) external {
        IERC4626 strategy = _removable(strategySeed);
        if (vault.config(strategy).enabled) return;
        uint256 validAt = vault.pendingCap(strategy).validAt;
        if (validAt == 0) {
            vault.submitCap(strategy, CAP);
        } else if (block.timestamp >= validAt) {
            Pre memory p = _pre(false);
            vault.acceptCap(strategy);
            _post(p, false);
        }
    }

    function accrue() external {
        _accrueChecked();
    }

    /*//////////////////////////////////////////////////////////////
                               PROPERTIES
    //////////////////////////////////////////////////////////////*/

    function property_solvency() external view returns (bool) {
        uint256 sum = vault.convertToAssets(vault.balanceOf(address(this)))
            + vault.convertToAssets(vault.balanceOf(address(actor)))
            + vault.convertToAssets(vault.balanceOf(FEE_RECIPIENT));
        return sum <= vault.totalAssets();
    }

    function property_totalAssetsBacked() external view returns (bool) {
        IAllocatorVault.Accrual memory a = vault.previewAccrual();
        uint256 ownValuation = asset.balanceOf(address(vault));
        for (uint256 i; i < vault.withdrawQueueLength(); ++i) {
            IERC4626 strategy = vault.withdrawQueue(i);
            ownValuation += strategy.convertToAssets(strategy.balanceOf(address(vault)));
        }
        bool impaired = address(a.impairedStrategy) != address(0);
        uint256 booked = impaired ? vault.lastTotalAssets() : a.grossAssets;
        return a.grossAssets <= ownValuation && a.totalAssets <= a.grossAssets && a.lockedProfit <= booked
            && a.totalAssets + a.lockedProfit <= booked;
    }

    function property_sharePriceMonotoneApartFromLosses() external view returns (bool) {
        return !priceDroppedWithoutLoss;
    }

    function property_feeSharesBoundedByHighWaterMarkGain() external view returns (bool) {
        return !feeAboveBound;
    }

    function property_highWaterMarkNeverDecreases() external view returns (bool) {
        return !highWaterMarkDecreased;
    }

    function property_accrualMatchesPreview() external view returns (bool) {
        return !accrualMismatch;
    }

    function property_safePriceNeverAboveSharePrice() external view returns (bool) {
        return vault.safeSharePrice() <= vault.sharePrice();
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNALS
    //////////////////////////////////////////////////////////////*/

    /// @dev `accrue`, checked: it writes exactly what `previewAccrual` predicted, and an impaired accrual books nothing.
    function _accrueChecked() internal {
        IAllocatorVault.Accrual memory predicted = vault.previewAccrual();
        uint256 lastBefore = vault.lastTotalAssets();
        Pre memory p = _pre(false);
        vault.accrue();
        uint256 expectedLast = address(predicted.impairedStrategy) == address(0) ? predicted.grossAssets : lastBefore;
        if (
            vault.lastTotalAssets() != expectedLast || vault.totalAssets() != predicted.totalAssets
                || vault.totalSupply() != predicted.totalSupply || vault.highWaterMark() != predicted.highWaterMark
        ) accrualMismatch = true;
        _post(p, false);
    }

    function _pre(bool touchesStrategies) internal view returns (Pre memory p) {
        IAllocatorVault.Accrual memory a = vault.previewAccrual();
        p.totalAssets = a.totalAssets;
        p.supplyWithFees = a.totalSupply;
        p.supply = vault.totalSupply();
        p.hwm = vault.highWaterMark();
        p.lastAccrual = vault.lastAccrual();
        p.recipientShares = vault.balanceOf(FEE_RECIPIENT);
        if (touchesStrategies) {
            p.tolerance = liquid.convertToAssets(1) + lossy.convertToAssets(1) + illiquid.convertToAssets(1)
                + pausable.convertToAssets(1) + 4;
        }
    }

    /// @dev Checks after an action whose vault call accrues before anything else, at exactly the state `p` previewed
    ///      (every vault entry point the harness calls, except `removeStrategy`; see there).
    function _post(Pre memory p, bool lossPossible) internal {
        _checkPriceAndMark(p, lossPossible);
        _checkFees(p, p.totalAssets);
    }

    function _checkPriceAndMark(Pre memory p, bool lossPossible) internal {
        if (!lossPossible) {
            IAllocatorVault.Accrual memory q = vault.previewAccrual();
            uint256 after_ = Math.mulDiv(q.totalAssets + 1 + p.tolerance, RAY, q.totalSupply + V);
            uint256 before = Math.mulDiv(p.totalAssets + 1, RAY, p.supplyWithFees + V);
            if (after_ + 1 < before) priceDroppedWithoutLoss = true;
        }
        if (vault.highWaterMark() < p.hwm) highWaterMarkDecreased = true;
    }

    /// @dev Fee shares minted since `p`, all by one accrual that priced them at `accrualTotalAssets` with the supply,
    ///      high-water mark and last-accrual time of `p`, against a sound upper bound: performance on the (pre-fee)
    ///      gain above the mark for all shares incl. the fee shares, plus management on the elapsed time.
    function _checkFees(Pre memory p, uint256 accrualTotalAssets) internal {
        uint256 feeShares = vault.balanceOf(FEE_RECIPIENT) - p.recipientShares;
        if (feeShares != 0) {
            uint256 value = Math.mulDiv(feeShares, accrualTotalAssets + 1, p.supply + feeShares + V);
            uint256 price = Math.mulDiv(accrualTotalAssets + 1, RAY, p.supply + V);
            uint256 gain = price > p.hwm ? Math.mulDiv(price - p.hwm, p.supply + feeShares, RAY) : 0;
            uint256 perfBound = Math.mulDiv(gain, vault.performanceFee(), WAD);
            uint256 mgmtBound =
                Math.mulDiv(accrualTotalAssets, vault.managementFee() * (block.timestamp - p.lastAccrual), WAD * YEAR);
            if (value > perfBound + mgmtBound + 2) feeAboveBound = true;
        }
    }

    function _strategy(uint256 seed) internal view returns (IERC4626) {
        uint256 i = seed % 4;
        if (i == 0) return liquid;
        if (i == 1) return lossy;
        return i == 2 ? IERC4626(address(illiquid)) : IERC4626(address(pausable));
    }

    /// @dev The strategies the harness may force-remove and re-list (never `lossy`, the loss source).
    function _removable(uint256 seed) internal view returns (IERC4626) {
        uint256 i = seed % 3;
        if (i == 0) return liquid;
        return i == 1 ? IERC4626(address(illiquid)) : IERC4626(address(pausable));
    }

    function _clamp(uint256 x, uint256 lo, uint256 hi) internal pure returns (uint256) {
        if (hi <= lo) return lo;
        if (hi - lo == type(uint256).max) return x;
        return lo + x % (hi - lo + 1);
    }
}
