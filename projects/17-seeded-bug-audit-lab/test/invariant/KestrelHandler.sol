// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { CommonBase } from "forge-std/Base.sol";
import { StdUtils } from "forge-std/StdUtils.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { MockERC20 } from "../helpers/MockERC20.sol";
import { PrecisionAmplifier, IAmplifiedOperation } from "../helpers/PrecisionAmplifier.sol";
import { PoolBatchOp, VaultWithdrawOp } from "../helpers/AmplifiedOps.sol";
import { KestrelPool } from "kestrel/KestrelPool.sol";
import { KestrelVault } from "kestrel/KestrelVault.sol";
import { KestrelLending } from "kestrel/KestrelLending.sol";
import { KestrelGovernor } from "kestrel/KestrelGovernor.sol";
import { KestrelRelayer } from "kestrel/KestrelRelayer.sol";
import { KestrelProxy } from "kestrel/KestrelProxy.sol";
import { GovToken } from "shared/GovToken.sol";
import { KestrelConfig } from "shared/KestrelConfig.sol";
import { PoolTwapOracle } from "shared/PoolTwapOracle.sol";
import { KestrelSystem } from "./KestrelSystem.sol";
import { NoReceiveActor, PriceObserver, FlashActor } from "./Actors.sol";

/// @title KestrelHandler
/// @notice Black-box stateful driver, written from the protocol specification only. Every action
///         is something a user, integrator or admin may legitimately try: random actors call
///         every external entry point (privileged ones included) with bounded random arguments;
///         batch swaps get random asset lists (duplicates allowed) and random step indices;
///         contract actors without `receive`, integrators that read prices on ETH receipt and
///         a generic flash borrower take part; signed relay requests are submitted and later
///         re-submitted, sometimes on another chain id. Ghost variables record every observed
///         violation of the specification's rules; the invariants assert they stay zero.
/// @dev    Works under Foundry and Medusa (only `prank`, `deal`, `warp`, `roll`, `chainId`,
///         `addr` and `sign` cheatcodes).
contract KestrelHandler is CommonBase, StdUtils {
    /// @notice Amplified operation id: tiny single-step batch swaps on the 6-decimal pool.
    bytes32 public constant OP_POOL6_BATCH = keccak256("pool6.batch");
    /// @notice Amplified operation id: dust vault withdrawals.
    bytes32 public constant OP_VAULT_DUST = keccak256("vault.withdraw");

    KestrelSystem public immutable sys;
    KestrelPool internal immutable pool;
    KestrelPool internal immutable pool6;
    KestrelVault internal immutable vault;
    KestrelLending internal immutable lending;
    PoolTwapOracle internal immutable oracle;
    GovToken internal immutable gov;
    KestrelGovernor internal immutable governor;
    KestrelRelayer internal immutable relayer;
    KestrelProxy internal immutable proxy;
    KestrelConfig internal immutable config;
    MockERC20 internal immutable collateral;
    MockERC20 internal immutable debt;
    MockERC20 internal immutable reward;
    MockERC20 internal immutable stable;

    PrecisionAmplifier public immutable amplifier;
    PoolBatchOp public immutable pool6Op;
    VaultWithdrawOp public immutable vaultOp;
    NoReceiveActor public immutable noReceive;
    PriceObserver public immutable observer;
    FlashActor public immutable flashActor;

    // --- ghost variables: each counts or sums observed violations of one rule ---
    /// @notice Output paid by single-step batch swaps above the single-swap quote.
    uint256 public batchExcessOverQuote;
    /// @notice Exact-share joins that paid less than their pro-rata share of the reserves.
    uint256 public underpricedJoins;
    /// @notice Owner-only pool actions that succeeded for a non-owner.
    uint256 public unauthorizedPrivilegedCalls;
    /// @notice Largest observed decrease of the vault share price.
    uint256 public maxSharePriceDrop;
    /// @notice Share prices observed by an integrator outside the [before, after] range.
    uint256 public inconsistentPriceReads;
    /// @notice Collateral valuation changes caused by a swap in the same block.
    uint256 public valuationMovedBySwap;
    /// @notice Treasury tokens moved by stake that existed only inside a flash loan.
    uint256 public treasuryMovedByFlashStake;
    /// @notice Relay requests that executed more than once.
    uint256 public signatureReuses;
    /// @notice Risk-config changes made by someone other than the owner (or pending owner).
    uint256 public unauthorizedConfigChanges;
    /// @notice Proxy upgrades made by someone other than the admin.
    uint256 public unauthorizedUpgrades;

    /// @notice Number of handler calls per selector (campaign coverage).
    mapping(bytes4 selector => uint256 count) public calls;

    address[3] internal eoas = [address(0x10001), address(0x10002), address(0x10003)];
    uint256[2] internal signerKeys = [uint256(0xA11CE), uint256(0xB0B5)];

    KestrelRelayer.SwapRequest[] internal relayed;
    bytes[] internal relayedSigs;

    constructor(KestrelSystem _sys) {
        sys = _sys;
        pool = _sys.pool();
        pool6 = _sys.pool6();
        vault = _sys.vault();
        lending = _sys.lending();
        oracle = _sys.oracle();
        gov = _sys.gov();
        governor = _sys.governor();
        relayer = _sys.relayer();
        proxy = _sys.proxy();
        config = KestrelConfig(address(_sys.proxy()));
        collateral = _sys.collateral();
        debt = _sys.debt();
        reward = _sys.reward();
        stable = _sys.stable();

        amplifier = new PrecisionAmplifier();
        pool6Op = new PoolBatchOp(pool6, address(stable), address(_sys.usdc()));
        vaultOp = new VaultWithdrawOp(vault);
        vm.deal(address(this), 100 ether);
        vaultOp.fund{ value: 100 ether }();
        noReceive = new NoReceiveActor();
        observer = new PriceObserver(vault);
        flashActor = new FlashActor(gov, governor);
    }

    // =====================================================================
    // Pool
    // =====================================================================

    /// @notice Any actor swaps on the main pool. Also watches the lending valuation of a fixed
    ///         collateral position across the swap (same block).
    function swap(uint256 actorSeed, bool zeroForOne, uint256 amount) external {
        calls[msg.sig]++;
        address a = _eoa(actorSeed);
        MockERC20 tokenIn = zeroForOne ? collateral : debt;
        amount = bound(amount, 1e15, 300_000e18);
        _fund(tokenIn, a, amount, address(pool));
        (bool okBefore, uint256 before) = _probeValuation();
        vm.prank(a);
        try pool.swap(address(tokenIn), amount, 0, a) { } catch { }
        (bool okAfter, uint256 afterValue) = _probeValuation();
        if (okBefore && okAfter && afterValue != before) {
            valuationMovedBySwap += afterValue > before ? afterValue - before : before - afterValue;
        }
    }

    /// @notice Any actor submits a batch with a random asset list (2-4 entries drawn from the
    ///         pool's tokens, so duplicates are allowed) and 1-2 steps with random indices.
    function batchSwap(uint256 actorSeed, uint256 layout, uint256 amountSeed) external {
        calls[msg.sig]++;
        address a = _eoa(actorSeed);
        uint256 n = 2 + layout % 3;
        address[] memory assets = new address[](n);
        for (uint256 i = 0; i < n; ++i) {
            assets[i] = ((layout >> (8 + i)) & 1) == 0 ? address(collateral) : address(debt);
        }
        uint256 stepCount = 1 + (layout >> 16) % 2;
        KestrelPool.BatchStep[] memory steps = new KestrelPool.BatchStep[](stepCount);
        for (uint256 s = 0; s < stepCount; ++s) {
            uint256 amountIn = bound(uint256(keccak256(abi.encode(amountSeed, s))), 1e15, 100_000e18);
            steps[s] = KestrelPool.BatchStep({
                assetInIndex: (layout >> (24 + 16 * s)) % n,
                assetOutIndex: (layout >> (32 + 16 * s)) % n,
                amountIn: amountIn
            });
            _fund(MockERC20(assets[steps[s].assetInIndex]), a, amountIn, address(pool));
        }

        // Specification: a batch step pays exactly what a single swap of the same input pays.
        address tokenIn = assets[steps[0].assetInIndex];
        address tokenOut = assets[steps[0].assetOutIndex];
        bool parity = stepCount == 1 && tokenIn != tokenOut;
        uint256 quote = parity ? pool.getAmountOut(tokenIn, steps[0].amountIn) : 0;
        uint256 outBefore = IERC20(tokenOut).balanceOf(a);
        vm.prank(a);
        try pool.batchSwap(assets, steps, a) {
            if (parity) {
                uint256 got = IERC20(tokenOut).balanceOf(a) - outBefore;
                if (got > quote) batchExcessOverQuote += got - quote;
            }
        } catch { }
    }

    /// @notice Any actor joins proportionally.
    function joinProportional(uint256 actorSeed, uint256 amount0) external {
        calls[msg.sig]++;
        address a = _eoa(actorSeed);
        amount0 = bound(amount0, 1e12, 100_000e18);
        uint256 r0 = pool.reserve0();
        if (r0 == 0) return;
        uint256 amount1 = Math.mulDiv(amount0, pool.reserve1(), r0);
        _fund(collateral, a, amount0, address(pool));
        _fund(debt, a, amount1, address(pool));
        vm.prank(a);
        try pool.addLiquidity(amount0, amount1, a) { } catch { }
    }

    /// @notice Any actor mints an exact number of shares (any uint256). Specification: a join
    ///         pays at least its pro-rata share of each reserve.
    function joinExactShares(uint256 actorSeed, uint256 shares) external {
        calls[msg.sig]++;
        address a = _eoa(actorSeed);
        shares = bound(shares, 1, type(uint256).max);
        uint256 maxPay = 1_000_000e18;
        _fund(collateral, a, maxPay, address(pool));
        _fund(debt, a, maxPay, address(pool));
        uint256 supply = pool.totalShares();
        uint256 r0 = pool.reserve0();
        uint256 r1 = pool.reserve1();
        vm.prank(a);
        try pool.addLiquidityExactShares(shares, maxPay, maxPay, a) returns (uint256 paid0, uint256 paid1) {
            // paid >= shares * reserve / supply  <=>  floor(paid * supply / reserve) >= shares
            if (Math.mulDiv(paid0, supply, r0) < shares || Math.mulDiv(paid1, supply, r1) < shares) {
                underpricedJoins += 1;
            }
        } catch { }
    }

    /// @notice Any actor exits part of its LP position.
    function exit(uint256 actorSeed, uint256 shares) external {
        calls[msg.sig]++;
        address a = _eoa(actorSeed);
        uint256 held = pool.sharesOf(a);
        if (held == 0) return;
        shares = bound(shares, 1, held);
        vm.prank(a);
        try pool.removeLiquidity(shares, a) { } catch { }
    }

    /// @notice A sponsored swap, paid by an EOA or by a contract wallet that cannot take ETH.
    function sponsoredSwap(uint256 actorSeed, uint256 amount, uint256 overpay, bool contractWallet) external {
        calls[msg.sig]++;
        address payer = contractWallet ? address(noReceive) : _eoa(actorSeed);
        amount = bound(amount, 1e15, 10_000e18);
        uint256 value = pool.nativeSwapFee() + bound(overpay, 0, 1 ether);
        debt.mint(payer, amount);
        vm.deal(address(this), value);
        if (contractWallet) {
            noReceive.exec(address(debt), abi.encodeCall(IERC20.approve, (address(pool), amount)));
            noReceive.exec{ value: value }(
                address(pool),
                abi.encodeCall(KestrelPool.swapWithNativeSponsor, (address(debt), amount, 0, payer))
            );
        } else {
            vm.prank(payer);
            debt.approve(address(pool), amount);
            vm.deal(payer, payer.balance + value);
            vm.prank(payer);
            try pool.swapWithNativeSponsor{ value: value }(address(debt), amount, 0, payer) { } catch { }
        }
    }

    /// @notice Any actor (sometimes the owner) tries the owner-only pool actions.
    function privileged(uint256 actorSeed, uint256 action, uint256 value) external {
        calls[msg.sig]++;
        address caller = actorSeed % 4 == 3 ? pool.owner() : _eoa(actorSeed);
        uint256 collected = pool.nativeFeesCollected();
        bool ok;
        vm.prank(caller);
        if (action % 2 == 0) {
            try pool.setRewardRate(bound(value, 0, 1e21)) {
                ok = true;
            } catch { }
        } else {
            try pool.withdrawNativeFees(payable(caller), bound(value, 0, collected)) {
                ok = true;
            } catch { }
        }
        if (ok && caller != pool.owner()) unauthorizedPrivilegedCalls += 1;
    }

    /// @notice Fund the reward reserve and let an actor claim.
    function rewards(uint256 actorSeed, uint256 amount) external {
        calls[msg.sig]++;
        amount = bound(amount, 1e18, 10_000e18);
        reward.mint(address(this), amount);
        reward.approve(address(pool), amount);
        try pool.fundRewards(amount) { } catch { }
        vm.prank(_eoa(actorSeed));
        try pool.claimReward() { } catch { }
    }

    /// @notice Repeat a tiny single-step batch swap on the 6-decimal pool through the
    ///         {PrecisionAmplifier}. Specification: never more than the single-swap quote.
    function amplifyPool6(uint256 n, uint256 amount) external {
        calls[msg.sig]++;
        n = bound(n, 1, 16);
        amount = bound(amount, 1e9, 1e16);
        stable.mint(address(pool6Op), n * amount);
        amplifier.amplify(OP_POOL6_BATCH, IAmplifiedOperation(address(pool6Op)), n, amount);
    }

    /// @notice Any actor trades on the 6-decimal pool (moves its price between amplifications).
    function swapPool6(uint256 actorSeed, uint256 amount) external {
        calls[msg.sig]++;
        address a = _eoa(actorSeed);
        amount = bound(amount, 1e15, 100_000e18);
        _fund(stable, a, amount, address(pool6));
        vm.prank(a);
        try pool6.swap(address(stable), amount, 0, a) { } catch { }
    }

    // =====================================================================
    // Vault
    // =====================================================================

    /// @notice An EOA or the integrator deposits ETH.
    function vaultDeposit(uint256 actorSeed, uint256 amount, bool integrator) external {
        calls[msg.sig]++;
        amount = bound(amount, 1e9, 100 ether);
        uint256 before = _price();
        if (integrator) {
            vm.deal(address(this), amount);
            try observer.deposit{ value: amount }() { } catch { }
        } else {
            address a = _eoa(actorSeed);
            vm.deal(a, a.balance + amount);
            vm.prank(a);
            try vault.deposit{ value: amount }(a, 0) { } catch { }
        }
        _recordPrice(before);
    }

    /// @notice An EOA or the integrator withdraws an exact ETH amount.
    function vaultWithdraw(uint256 actorSeed, uint256 amount, bool integrator) external {
        calls[msg.sig]++;
        address a = integrator ? address(observer) : _eoa(actorSeed);
        uint256 held = vault.balanceOf(a);
        if (held == 0) return;
        uint256 maxAssets = vault.convertToAssets(held);
        if (maxAssets == 0) return;
        amount = bound(amount, 1, maxAssets);
        uint256 before = _price();
        if (integrator) {
            try observer.withdraw(amount) {
                _checkObservation(before);
            } catch { }
        } else {
            vm.prank(a);
            try vault.withdraw(amount, a) { } catch { }
        }
        _recordPrice(before);
    }

    /// @notice An EOA or the integrator redeems shares.
    function vaultRedeem(uint256 actorSeed, uint256 shares, bool integrator) external {
        calls[msg.sig]++;
        address a = integrator ? address(observer) : _eoa(actorSeed);
        uint256 held = vault.balanceOf(a);
        if (held == 0) return;
        shares = bound(shares, 1, held);
        uint256 before = _price();
        if (integrator) {
            try observer.redeem(shares) {
                _checkObservation(before);
            } catch { }
        } else {
            vm.prank(a);
            try vault.redeem(shares, a) { } catch { }
        }
        _recordPrice(before);
    }

    /// @notice Yield is harvested into the vault.
    function vaultAccrue(uint256 amount) external {
        calls[msg.sig]++;
        amount = bound(amount, 1, 50 ether);
        vm.deal(address(this), amount);
        uint256 before = _price();
        try vault.accrue{ value: amount }() { } catch { }
        _recordPrice(before);
    }

    /// @notice Repeat a dust withdrawal through the {PrecisionAmplifier}. Specification: never
    ///         more ETH than the burned shares are worth.
    function amplifyVaultDust(uint256 n, uint256 amount) external {
        calls[msg.sig]++;
        n = bound(n, 1, 16);
        amount = bound(amount, 1, 1e6);
        uint256 before = _price();
        amplifier.amplify(OP_VAULT_DUST, IAmplifiedOperation(address(vaultOp)), n, amount);
        _recordPrice(before);
    }

    // =====================================================================
    // Lending and oracle
    // =====================================================================

    /// @notice Any actor pledges collateral and borrows against it.
    function borrow(uint256 actorSeed, uint256 pledge, uint256 amount) external {
        calls[msg.sig]++;
        address a = _eoa(actorSeed);
        pledge = bound(pledge, 1e18, 100_000e18);
        _fund(collateral, a, pledge, address(lending));
        vm.startPrank(a);
        try lending.depositCollateral(pledge) { } catch { }
        try lending.borrow(bound(amount, 1, pledge)) { } catch { }
        vm.stopPrank();
    }

    /// @notice Any actor repays and withdraws collateral.
    function repayAndWithdraw(uint256 actorSeed, uint256 amount) external {
        calls[msg.sig]++;
        address a = _eoa(actorSeed);
        uint256 owed = lending.debtOf(a);
        if (owed > 0) {
            uint256 pay = bound(amount, 1, owed);
            _fund(debt, a, pay, address(lending));
            vm.prank(a);
            try lending.repay(pay) { } catch { }
        }
        uint256 held = lending.collateralOf(a);
        if (held > 0) {
            vm.prank(a);
            try lending.withdrawCollateral(bound(amount, 1, held)) { } catch { }
        }
    }

    /// @notice A keeper (anyone) pokes the oracle.
    function keeper() external {
        calls[msg.sig]++;
        try oracle.update() { } catch { }
    }

    /// @notice Time passes.
    function warp(uint256 secondsSeed) external {
        calls[msg.sig]++;
        vm.warp(block.timestamp + bound(secondsSeed, 1, 2 hours));
        vm.roll(block.number + 1);
    }

    // =====================================================================
    // Governance
    // =====================================================================

    /// @notice A generic flash borrower takes any loan the token offers and tries a governance
    ///         action inside it. Specification: the treasury only moves on durable stake.
    function flashGovern(uint256 loan, uint256 action) external {
        calls[msg.sig]++;
        uint256 cap = uint256(type(uint208).max) - gov.totalSupply();
        loan = bound(loan, 1, cap);
        uint256 before = gov.balanceOf(address(governor));
        try flashActor.run(loan, action % 3) { } catch { }
        uint256 afterBalance = gov.balanceOf(address(governor));
        if (afterBalance < before) treasuryMovedByFlashStake += before - afterBalance;
    }

    // =====================================================================
    // Relayer
    // =====================================================================

    /// @notice A user signs a fresh request for its current nonce and any relayer submits it.
    function relay(uint256 signerSeed, uint256 amount) external {
        calls[msg.sig]++;
        uint256 key = signerKeys[signerSeed % 2];
        address signer = vm.addr(key);
        amount = bound(amount, 1e15, 1000e18);
        _fund(collateral, signer, amount, address(relayer));
        KestrelRelayer.SwapRequest memory req = KestrelRelayer.SwapRequest({
            user: signer,
            tokenIn: address(collateral),
            amountIn: amount,
            minOut: 0,
            to: signer,
            nonce: relayer.nonces(signer),
            deadline: block.timestamp + 1 days
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, relayer.hashRequest(req));
        bytes memory sig = abi.encodePacked(r, s, v);
        try relayer.relaySwap(req, sig) {
            relayed.push(req);
            relayedSigs.push(sig);
        } catch { }
    }

    /// @notice Anyone re-submits a request that was already relayed, sometimes on another chain.
    ///         Specification: each signed request executes at most once, on its own chain.
    function replay(uint256 index, uint256 chainSeed) external {
        calls[msg.sig]++;
        uint256 count = relayed.length;
        if (count == 0) return;
        index = bound(index, 0, count - 1);
        KestrelRelayer.SwapRequest memory req = relayed[index];
        _fund(collateral, req.user, req.amountIn, address(relayer));
        uint256 chainBefore = block.chainid;
        if (chainSeed % 2 == 1) vm.chainId(bound(chainSeed, 2, 1_000_000));
        try relayer.relaySwap(req, relayedSigs[index]) {
            signatureReuses += 1;
        } catch { }
        vm.chainId(chainBefore);
    }

    // =====================================================================
    // Risk config and proxy
    // =====================================================================

    /// @notice Any actor (sometimes the risk owner) calls a config entry point through the proxy.
    ///         Specification: only the owner changes parameters or starts an ownership transfer,
    ///         only the pending owner accepts, and the config is initialized once.
    function configCall(uint256 actorSeed, uint256 action, uint256 value) external {
        calls[msg.sig]++;
        address caller = actorSeed % 4 == 3 ? config.owner() : _eoa(actorSeed);
        address ownerBefore = config.owner();
        address pendingBefore = config.pendingOwner();
        uint256 ltvBefore = config.ltvBps();
        uint256 priceBefore = config.ethPrice();
        action = action % 5;
        bool ok;
        vm.prank(caller);
        if (action == 0) {
            try config.initialize(caller, bound(value, 1, 9000), bound(value, 1, 1e30)) {
                ok = true;
            } catch { }
        } else if (action == 1) {
            try config.setLtvBps(bound(value, 1, 9000)) {
                ok = true;
            } catch { }
        } else if (action == 2) {
            try config.setEthPrice(bound(value, 1e18, 1e22)) {
                ok = true;
            } catch { }
        } else if (action == 3) {
            try config.transferOwnership(_eoa(value)) {
                ok = true;
            } catch { }
        } else {
            try config.acceptOwnership() {
                ok = true;
            } catch { }
        }
        if (!ok) return;
        bool changed = config.owner() != ownerBefore || config.pendingOwner() != pendingBefore
            || config.ltvBps() != ltvBefore || config.ethPrice() != priceBefore;
        bool authorized =
            (caller == ownerBefore && action >= 1 && action <= 3) || (caller == pendingBefore && action == 4);
        if (changed && !authorized) unauthorizedConfigChanges += 1;
    }

    /// @notice Any actor (sometimes the admin) tries to upgrade the proxy.
    function upgrade(uint256 actorSeed) external {
        calls[msg.sig]++;
        address caller = actorSeed % 4 == 3 ? sys.PROXY_ADMIN() : _eoa(actorSeed);
        address impl = address(new KestrelConfig());
        vm.prank(caller);
        try proxy.upgradeTo(impl) {
            if (caller != sys.PROXY_ADMIN()) unauthorizedUpgrades += 1;
        } catch { }
    }

    // =====================================================================
    // Internal
    // =====================================================================

    function _eoa(uint256 seed) internal view returns (address) {
        return eoas[seed % eoas.length];
    }

    function _fund(MockERC20 token, address who, uint256 amount, address spender) internal {
        token.mint(who, amount);
        vm.prank(who);
        token.approve(spender, type(uint256).max);
    }

    function _probeValuation() internal view returns (bool ok, uint256 value) {
        try lending.collateralValue(address(sys)) returns (uint256 v) {
            return (true, v);
        } catch {
            return (false, 0);
        }
    }

    function _price() internal view returns (uint256) {
        if (vault.totalSupply() == 0) return 0;
        return vault.convertToAssets(1e18);
    }

    function _recordPrice(uint256 before) internal {
        if (before == 0 || vault.totalSupply() == 0) return;
        uint256 afterPrice = vault.convertToAssets(1e18);
        if (afterPrice < before && before - afterPrice > maxSharePriceDrop) {
            maxSharePriceDrop = before - afterPrice;
        }
    }

    function _checkObservation(uint256 before) internal {
        if (!observer.observed()) return;
        uint256 seen = observer.observedPrice();
        uint256 afterPrice = _price();
        uint256 lo = before < afterPrice ? before : afterPrice;
        uint256 hi = before < afterPrice ? afterPrice : before;
        if (seen < lo || seen > hi) inconsistentPriceReads += 1;
    }

    /// @notice Accept ETH (vault operations funded by the handler).
    receive() external payable { }
}
