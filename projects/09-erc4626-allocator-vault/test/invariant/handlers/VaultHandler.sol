// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {AllocatorVault} from "../../../src/AllocatorVault.sol";
import {IAllocatorVault} from "../../../src/interfaces/IAllocatorVault.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {
    MockIlliquidStrategy,
    MockLiquidStrategy,
    MockLossyStrategy,
    MockPausableStrategy,
    MockStrategyBase
} from "../../mocks/MockStrategies.sol";

/// @notice Drives the vault through deposits, mints, withdrawals, redemptions, reallocations, strategy yield and
///         losses, donations, illiquidity, a strategy pausing (its views revert), forced removals with their
///         write-offs, revocations, re-listings, and time. Around every action it checks, from observable state only:
///         - the share price (after pending fees) never decreases except on an action that can lose value (a loss, a
///           strategy pausing, a forced removal being announced, lending out cash of a strategy being removed), and
///           over a pure time warp by at most the management fee for that time;
///         - fee shares minted by an accrual are worth no more than the fee rate times the gain above the high-water
///           mark (performance) and the fee rate times assets times time (management);
///         - the high-water mark never decreases;
///         - an accrual writes exactly what `previewAccrual` predicted.
///         Violations are latched in public flags that the invariant functions assert on.
contract VaultHandler is Test {
    uint256 internal constant V = 1e6;
    uint256 internal constant RAY = 1e27;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant YEAR = 365 days;
    uint256 internal constant RELIST_CAP = 1e30;
    bytes32 internal constant ACCRUE_TOPIC = IAllocatorVault.Accrue.selector;

    /// @notice The accounts holding the vault roles.
    struct Roles {
        address curator;
        address allocator;
        address guardian;
        address feeRecipient;
    }

    AllocatorVault public immutable vault;
    MockERC20 public immutable asset;
    MockLiquidStrategy public immutable liquid;
    MockLossyStrategy public immutable lossy;
    MockIlliquidStrategy public immutable illiquid;
    MockPausableStrategy public immutable pausable;
    address public immutable curator;
    address public immutable allocator;
    address public immutable guardian;
    address public immutable feeRecipient;

    address[] public actors;
    /// @notice Every strategy the handler knows about (listed or removed).
    IERC4626[] public strategies;
    /// @notice The strategies the handler may force-remove and re-list (never `lossy`, the loss source).
    IERC4626[] public removable;

    bool public priceDroppedWithoutLoss;
    bool public priceDroppedMoreThanFees;
    bool public feeAboveBound;
    bool public feeSharesMismatch;
    bool public highWaterMarkDecreased;
    bool public accrualMismatch;

    /// @notice Number of non-zero losses applied to a strategy.
    uint256 public lossActions;
    /// @notice Number of accruals that minted fee shares.
    uint256 public feeAccruals;
    mapping(bytes32 action => uint256) public calls;

    struct Pre {
        IAllocatorVault.Accrual a;
        uint256 supply;
        uint256 hwm;
        uint256 lastAccrual;
        uint256 recipientShares;
        uint256 tolerance;
    }

    constructor(
        AllocatorVault vault_,
        MockERC20 asset_,
        MockLiquidStrategy liquid_,
        MockLossyStrategy lossy_,
        MockIlliquidStrategy illiquid_,
        MockPausableStrategy pausable_,
        Roles memory roles
    ) {
        vault = vault_;
        asset = asset_;
        liquid = liquid_;
        lossy = lossy_;
        illiquid = illiquid_;
        pausable = pausable_;
        curator = roles.curator;
        allocator = roles.allocator;
        guardian = roles.guardian;
        feeRecipient = roles.feeRecipient;
        strategies.push(liquid_);
        strategies.push(lossy_);
        strategies.push(illiquid_);
        strategies.push(pausable_);
        removable.push(liquid_);
        removable.push(illiquid_);
        removable.push(pausable_);
        actors.push(makeAddr("actor0"));
        actors.push(makeAddr("actor1"));
        actors.push(makeAddr("actor2"));
    }

    function actorsLength() external view returns (uint256) {
        return actors.length;
    }

    function strategiesLength() external view returns (uint256) {
        return strategies.length;
    }

    /*//////////////////////////////////////////////////////////////
                                ACTIONS
    //////////////////////////////////////////////////////////////*/

    function deposit(uint256 actorSeed, uint256 assets) public {
        address actor = actors[actorSeed % actors.length];
        assets = bound(assets, 0, 1e27);
        if (vault.maxDeposit(actor) == 0) return; // paused while a position is impaired, by design
        if (assets != 0 && vault.previewDeposit(assets) == 0) return; // would revert with ZeroShares by design
        asset.mint(actor, assets);
        vm.prank(actor);
        asset.approve(address(vault), assets);

        Pre memory p = _pre(false);
        vm.prank(actor);
        vault.deposit(assets, actor);
        _post(p, false);
        ++calls["deposit"];
    }

    function mint(uint256 actorSeed, uint256 shares) external {
        address actor = actors[actorSeed % actors.length];
        if (vault.maxMint(actor) == 0) return; // paused while a position is impaired, by design
        shares = bound(shares, 0, vault.convertToShares(1e27)); // at most ~1e27 assets, like `deposit`
        uint256 cost = vault.previewMint(shares);
        asset.mint(actor, cost);
        vm.prank(actor);
        asset.approve(address(vault), cost);

        Pre memory p = _pre(false);
        vm.prank(actor);
        vault.mint(shares, actor);
        _post(p, false);
        ++calls["mint"];
    }

    function withdraw(uint256 actorSeed, uint256 assets) external {
        address actor = actors[actorSeed % actors.length];
        assets = bound(assets, 0, vault.maxWithdraw(actor));

        Pre memory p = _pre(true);
        vm.prank(actor);
        vault.withdraw(assets, actor, actor);
        _post(p, false);
        ++calls["withdraw"];
    }

    function redeem(uint256 actorSeed, uint256 shares) external {
        address actor = actors[actorSeed % actors.length];
        shares = bound(shares, 0, vault.maxRedeem(actor));

        Pre memory p = _pre(true);
        vm.prank(actor);
        vault.redeem(shares, actor, actor);
        _post(p, false);
        ++calls["redeem"];
    }

    function reallocate(uint256 strategySeed, uint256 target) public {
        IERC4626 strategy = strategies[strategySeed % strategies.length];
        if (!vault.config(strategy).enabled) return; // removed
        if (address(strategy) == address(pausable) && pausable.paused()) return; // its views revert: nothing to allocate against
        uint256 shares = strategy.balanceOf(address(vault));
        uint256 current = shares == 0 ? 0 : strategy.previewRedeem(shares);
        uint256 withdrawable = strategy.maxWithdraw(address(vault));
        uint256 lower = current > withdrawable ? current - withdrawable : 0;
        uint256 upper = Math.min(current + asset.balanceOf(address(vault)), vault.config(strategy).cap);
        if (upper < lower) return; // over the cap after yield, and nothing withdrawable: no valid target
        target = bound(target, lower, upper);
        if (target == 0 && shares != 0 && strategy.maxRedeem(address(vault)) < shares) return;

        IAllocatorVault.Allocation[] memory allocations = new IAllocatorVault.Allocation[](1);
        allocations[0] = IAllocatorVault.Allocation({strategy: strategy, assets: target});
        Pre memory p = _pre(true);
        vm.prank(allocator);
        vault.reallocate(allocations);
        _post(p, false);
        ++calls["reallocate"];
    }

    function strategyYield(uint256 strategySeed, uint256 amount) external {
        MockStrategyBase strategy = MockStrategyBase(address(strategies[strategySeed % strategies.length]));
        amount = bound(amount, 0, strategy.totalAssets() / 10 + 1e18);
        Pre memory p = _pre(false);
        strategy.simulateYield(amount);
        _post(p, false);
        ++calls["strategyYield"];
    }

    function strategyLoss(uint256 amount) public {
        amount = bound(amount, 0, asset.balanceOf(address(lossy)));
        Pre memory p = _pre(false);
        lossy.simulateLoss(amount);
        _post(p, true);
        if (amount != 0) ++lossActions;
        ++calls["strategyLoss"];
    }

    function donate(uint256 amount) external {
        amount = bound(amount, 0, 1e24);
        Pre memory p = _pre(false);
        asset.mint(address(vault), amount);
        _post(p, false);
        ++calls["donate"];
    }

    function lend(uint256 amount) external {
        amount = bound(amount, 0, illiquid.cash());
        // Never moves the price: a position counts at the strategy's `previewRedeem` (cash plus loans), or at 0 while
        // its forced removal is pending, never at the strategy's live liquidity.
        Pre memory p = _pre(false);
        illiquid.lend(amount);
        _post(p, false);
        ++calls["lend"];
    }

    function repay(uint256 amount) external {
        amount = bound(amount, 0, illiquid.lentOut());
        Pre memory p = _pre(false);
        illiquid.repay(amount);
        _post(p, false);
        ++calls["repay"];
    }

    /// @notice Pauses (EIP-4626-compliant: `previewRedeem` reverts, `max*` return 0) or resumes `pausable`.
    function setPaused(bool paused) public {
        Pre memory p = _pre(false);
        pausable.setPaused(paused);
        _post(p, paused); // pausing can lower the price (the position counts as 0); resuming cannot
        ++calls[paused ? bytes32("pause") : bytes32("unpause")];
    }

    /// @notice Guardian zeroes the cap, curator announces a forced removal (what can be redeemed now is redeemed, the
    ///         rest of the position then counts as 0).
    function startRemoval(uint256 strategySeed) external {
        IERC4626 strategy = removable[strategySeed % removable.length];
        IAllocatorVault.StrategyConfig memory cfg = vault.config(strategy);
        if (!cfg.enabled || cfg.removableAt != 0) return;
        vm.prank(guardian);
        vault.zeroCap(strategy);
        Pre memory p = _pre(false);
        vm.prank(curator);
        vault.submitStrategyRemoval(strategy);
        _post(p, true); // the expected write-off reaches the price now
        ++calls["startRemoval"];
    }

    /// @notice Guardian revokes a pending forced removal: the position counts in full again.
    function revokeRemoval(uint256 strategySeed) public {
        IERC4626 strategy = removable[strategySeed % removable.length];
        if (vault.config(strategy).removableAt == 0) return;
        Pre memory p = _pre(false);
        vm.prank(guardian);
        vault.revokePendingRemoval(strategy);
        _post(p, false);
        ++calls["revokeRemoval"];
    }

    /// @notice Curator removes a strategy: redeems what it can and writes off the rest (only after a forced removal
    ///         has waited out its timelock, unless nothing would be written off).
    function removeStrategy(uint256 strategySeed) external {
        IERC4626 strategy = removable[strategySeed % removable.length];
        IAllocatorVault.StrategyConfig memory cfg = vault.config(strategy);
        if (!cfg.enabled) return;
        bool forcedRemovalReady = cfg.removableAt != 0 && block.timestamp >= cfg.removableAt;
        if (!forcedRemovalReady) {
            if (address(strategy) == address(pausable) && pausable.paused()) return;
            uint256 shares = strategy.balanceOf(address(vault));
            if (shares != 0 && strategy.maxRedeem(address(vault)) < shares) return; // would leave value behind
        }
        if (cfg.cap != 0) {
            vm.prank(guardian);
            vault.zeroCap(strategy);
        }
        Pre memory p = _pre(true);
        vm.prank(curator);
        vault.removeStrategy(strategy);
        _post(p, false); // a write-off was already priced in when the forced removal was announced
        ++calls["removeStrategy"];
    }

    /// @notice Curator submits a removed strategy for re-listing (3-day timelock).
    function submitRelist(uint256 strategySeed) external {
        IERC4626 strategy = removable[strategySeed % removable.length];
        if (vault.config(strategy).enabled || vault.pendingCap(strategy).validAt != 0) return;
        vm.prank(curator);
        vault.submitCap(strategy, RELIST_CAP);
        ++calls["submitRelist"];
    }

    /// @notice Anyone accepts a re-listing whose timelock has elapsed; shares the vault still holds come back as
    ///         locked profit.
    function acceptRelist(uint256 strategySeed) external {
        IERC4626 strategy = removable[strategySeed % removable.length];
        uint256 validAt = vault.pendingCap(strategy).validAt;
        if (validAt == 0 || block.timestamp < validAt) return;
        Pre memory p = _pre(false);
        vault.acceptCap(strategy);
        _post(p, false);
        ++calls["acceptRelist"];
    }

    function accrue() public {
        uint256 lastBefore = vault.lastTotalAssets();
        Pre memory p = _pre(false);
        vault.accrue();
        // An impaired accrual books nothing: the booked gross assets must stay where they were.
        uint256 expectedLast = address(p.a.impairedStrategy) == address(0) ? p.a.grossAssets : lastBefore;
        if (
            vault.lastTotalAssets() != expectedLast || vault.totalAssets() != p.a.totalAssets
                || vault.totalSupply() != p.a.totalSupply || vault.highWaterMark() != p.a.highWaterMark
        ) accrualMismatch = true;
        _post(p, false);
        ++calls["accrue"];
    }

    function warp(uint256 seconds_) public {
        seconds_ = bound(seconds_, 1, 3 days);
        Pre memory p = _pre(false);
        vm.warp(block.timestamp + seconds_);
        _postWarp(p);
        ++calls["warp"];
    }

    /// @notice Run once at the end of every run (from `afterInvariant`): from the run's final state, ends any
    ///         impairment, deposits, puts assets in the lossy strategy, charges a day of fees and realizes a loss, all
    ///         through the checked actions above. So every run exercises the fee and loss checks at least once,
    ///         whatever the random sequence did.
    function probeFeesAndLoss() external {
        if (pausable.paused()) setPaused(false);
        for (uint256 i; i < removable.length; ++i) {
            revokeRemoval(i);
        }
        deposit(0, 1e24);
        uint256 inLossy =
            lossy.balanceOf(address(vault)) == 0 ? 0 : lossy.previewRedeem(lossy.balanceOf(address(vault)));
        reallocate(1, inLossy + 1e23); // strategies[1] is lossy; the target is bounded by the idle assets
        warp(1 days);
        accrue();
        strategyLoss(asset.balanceOf(address(lossy)) / 2);
        accrue();
    }

    /*//////////////////////////////////////////////////////////////
                                 CHECKS
    //////////////////////////////////////////////////////////////*/

    function _pre(bool touchesStrategies) internal returns (Pre memory p) {
        p.a = vault.previewAccrual();
        p.supply = vault.totalSupply();
        p.hwm = vault.highWaterMark();
        p.lastAccrual = vault.lastAccrual();
        p.recipientShares = vault.balanceOf(feeRecipient);
        if (touchesStrategies) {
            // Moving assets through an OpenZeppelin strategy can lose up to one strategy share per strategy.
            for (uint256 i; i < strategies.length; ++i) {
                p.tolerance += strategies[i].convertToAssets(1) + 1;
            }
        }
        vm.recordLogs();
    }

    function _post(Pre memory p, bool lossPossible) internal {
        _checkFees(p);
        IAllocatorVault.Accrual memory q = vault.previewAccrual();
        if (!lossPossible && _priceDropped(p, q, p.tolerance, WAD * YEAR)) priceDroppedWithoutLoss = true;
        if (vault.highWaterMark() < p.hwm) highWaterMarkDecreased = true;
    }

    function _postWarp(Pre memory p) internal {
        vm.getRecordedLogs();
        IAllocatorVault.Accrual memory q = vault.previewAccrual();
        // Over a pure time step the price can only fall by the management fee accrued over the whole period since
        // the last accrual (the performance fee only ever takes a slice of new gains above the mark).
        uint256 elapsed = block.timestamp - p.lastAccrual;
        uint256 keep = WAD * YEAR - Math.min(WAD * YEAR, vault.managementFee() * elapsed);
        if (_priceDropped(p, q, 1, keep)) priceDroppedMoreThanFees = true;
        if (vault.highWaterMark() < p.hwm) highWaterMarkDecreased = true;
    }

    /// @dev True when price(q) < price(p) * keep / (WAD * YEAR), with `tolerance` wei of slack on q's assets.
    function _priceDropped(Pre memory p, IAllocatorVault.Accrual memory q, uint256 tolerance, uint256 keep)
        internal
        pure
        returns (bool)
    {
        uint256 after_ = Math.mulDiv(q.totalAssets + 1 + tolerance, RAY, q.totalSupply + V);
        uint256 before = Math.mulDiv(p.a.totalAssets + 1, RAY, p.a.totalSupply + V);
        return after_ + 1 < Math.mulDiv(before, keep, WAD * YEAR);
    }

    /// @dev Checks every `Accrue` event of the action against bounds computed from the pre-action state.
    function _checkFees(Pre memory p) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 minted;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(vault) || logs[i].topics[0] != ACCRUE_TOPIC) continue;
            (, uint256 ta,,, uint256 mgmtShares, uint256 perfShares,) =
                abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256, uint256, uint256));
            minted += mgmtShares + perfShares;
            if (mgmtShares + perfShares == 0) continue;
            ++feeAccruals;

            uint256 supplyAfter = p.supply + mgmtShares + perfShares;
            // Management: value <= fee * totalAssets * elapsed / year.
            uint256 mgmtValue = Math.mulDiv(mgmtShares, ta + 1, supplyAfter + V);
            uint256 mgmtBound = Math.mulDiv(ta, vault.managementFee() * (block.timestamp - p.lastAccrual), WAD * YEAR);
            // Performance: value <= fee * (price after management fee - HWM) * supply.
            uint256 s1 = p.supply + mgmtShares;
            uint256 price = Math.mulDiv(ta + 1, RAY, s1 + V);
            uint256 gain = price > p.hwm ? Math.mulDiv(price - p.hwm, s1, RAY) : 0;
            uint256 perfValue = Math.mulDiv(perfShares, ta + 1, supplyAfter + V);
            uint256 perfBound = Math.mulDiv(gain, vault.performanceFee(), WAD);
            if (mgmtValue > mgmtBound + 1 || perfValue > perfBound + 1) feeAboveBound = true;
        }
        if (vault.balanceOf(feeRecipient) != p.recipientShares + minted) feeSharesMismatch = true;
    }
}
