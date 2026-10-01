// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {ImmutableState} from "@uniswap/v4-periphery/src/base/ImmutableState.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {HookFixture} from "../utils/HookFixture.sol";
import {BatchSwapRouter} from "../utils/Routers.sol";
import {GasGuzzlerModule, NestedSwapModule} from "../utils/mocks/HostileModules.sol";
import {IVolatilityFeeHook} from "../../src/interfaces/IVolatilityFeeHook.sol";
import {ILiquidityModule} from "../../src/interfaces/ILiquidityModule.sol";

/// @notice One adversarial test (or more) per failure pattern from Trail of Bits, "Building secure Uniswap v4 hooks"
/// (July 2026). Deeper suites: HookPermissions.t.sol (pattern 5), ExitAlwaysWorks.t.sol (pattern 6),
/// Adversarial.t.sol and the invariant suites (patterns 2, 3 and 7).
contract TrailOfBitsPatternsTest is HookFixture {
    using StateLibrary for IPoolManager;

    BatchSwapRouter internal batchRouter;

    function setUp() public {
        setUpEnvironment();
        batchRouter = new BatchSwapRouter(manager);
        MockERC20Like(Currency.unwrap(currency0)).approve(address(batchRouter), type(uint256).max);
        MockERC20Like(Currency.unwrap(currency1)).approve(address(batchRouter), type(uint256).max);
    }

    // ================================================================ 1. Anyone can call your hook

    function testFuzz_ToB1_callbacksRejectEveryoneButThePoolManager(address attacker) public {
        vm.assume(attacker != address(manager));
        BalanceDelta big = toBalanceDelta(type(int128).max, type(int128).max);
        vm.startPrank(attacker);
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.beforeSwap(attacker, poolKey, SwapParams(true, -1e30, MIN_PRICE_LIMIT), "");
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.afterSwap(attacker, poolKey, SwapParams(true, -1e30, MIN_PRICE_LIMIT), big, "");
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.afterRemoveLiquidity(attacker, poolKey, REMOVE_LIQUIDITY_PARAMS, big, big, "");
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.afterAddLiquidity(attacker, poolKey, LIQUIDITY_PARAMS, big, big, "");
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.beforeInitialize(attacker, poolKey, SQRT_PRICE_1_1);
        vm.stopPrank();
    }

    /// @notice Admin functions are owner-only; the only other external entry point, notification delivery, is
    /// permissionless by design but accepts nothing that was not committed by a liquidity change.
    function testFuzz_ToB1_adminAndDeliveryRejectOutsiders(address attacker, uint256 id) public {
        vm.assume(attacker != owner);
        IVolatilityFeeHook.LiquidityNotification memory forged;
        forged.sender = attacker;
        forged.key = poolKey;
        forged.params = LIQUIDITY_PARAMS;
        vm.startPrank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IVolatilityFeeHook.UnknownNotification.selector, id));
        hook.deliverNotification(id, ILiquidityModule(attacker), forged);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        hook.setLiquidityModule(ILiquidityModule(attacker));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        hook.setCurrencyAllowed(Currency.wrap(attacker), true);
        vm.stopPrank();
    }

    // ================================================================ 2. Treating any pool as legitimate

    /// @notice An attacker may create their own pool with this hook (same allowlisted tokens, other tick spacing and
    /// price) and hammer it across many blocks; the legitimate pool's oracle and fees must not move.
    function test_ToB2_attackerPoolCannotTouchLegitimatePoolState() public {
        IVolatilityFeeHook.PoolState memory before = state();
        (PoolKey memory evil, PoolId evilId) =
            initPool(currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 1, SQRT_PRICE_4_1);
        addLiquidity(evil, -60_000, 60_000, 10e18, 0);
        for (uint256 i; i < 10; ++i) {
            nextBlock();
            swapExactIn(evil, i % 2 == 0, 5e18);
        }
        assertGt(hook.getPoolState(evilId).ewmaWad, 0, "attacker pool has its own volatility");
        IVolatilityFeeHook.PoolState memory afterAttack = state();
        assertEq(afterAttack.ewmaWad, before.ewmaWad);
        assertEq(afterAttack.anchorBlock, before.anchorBlock);
        assertEq(afterAttack.lowSqrtPriceX96, before.lowSqrtPriceX96);
        assertEq(afterAttack.highSqrtPriceX96, before.highSqrtPriceX96);
        assertEq(afterAttack.lpFeePips, before.lpFeePips);
    }

    function test_ToB2_unvettedPoolKeysAreRejected() public {
        (Currency evil0, Currency evil1) = deployAndMint2Currencies();
        PoolKey memory unvetted = PoolKey(evil0, evil1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(address(hook)));
        vm.expectRevert(
            wrappedHookError(
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(IVolatilityFeeHook.CurrencyNotAllowed.selector, evil0)
            )
        );
        manager.initialize(unvetted, SQRT_PRICE_1_1);

        PoolKey memory staticFee = PoolKey(currency0, currency1, 100, 1, IHooks(address(hook)));
        vm.expectRevert(
            wrappedHookError(
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(IVolatilityFeeHook.DynamicFeeRequired.selector, uint24(100))
            )
        );
        manager.initialize(staticFee, SQRT_PRICE_1_1);
    }

    // ================================================================ 3. Custom accounting leaks value

    /// @notice For any swap: the trader's balance change equals the PoolManager's swap delta minus exactly the
    /// surcharge, the surcharge is donated in full, and the hook ends holding nothing.
    function testFuzz_ToB3_everyChargeMatchesItsDonation(
        bool zeroForOne,
        bool exactIn,
        uint256 amount,
        uint256 moveSeed
    ) public {
        amount = bound(amount, 1, 30e18);
        swapExactIn(poolKey, moveSeed % 2 == 0, bound(moveSeed, 0, 40e18) + 1);
        nextBlock();
        SwapObservation memory o = observeSwap(poolKey, zeroForOne, exactIn ? -int256(amount) : int256(amount));
        assertEq(o.traderDelta0, int256(o.poolAmount0) - int256(o.surcharge0), "currency0 reconciles");
        assertEq(o.traderDelta1, int256(o.poolAmount1) - int256(o.surcharge1), "currency1 reconciles");
        assertEq(o.donated0, o.surcharge0, "currency0 surcharge donated");
        assertEq(o.donated1, o.surcharge1, "currency1 surcharge donated");
        assertEq(currency0.balanceOf(address(hook)) + currency1.balanceOf(address(hook)), 0);
        assertEq(
            manager.balanceOf(address(hook), currency0.toId()) + manager.balanceOf(address(hook), currency1.toId()), 0
        );
    }

    /// @notice A same-transaction round trip (sell X, buy back with everything received) can never create value.
    function testFuzz_ToB3_roundTripInOneTransactionCannotCreateValue(uint256 amount, bool zeroForOne, uint256 moveSeed)
        public
    {
        amount = bound(amount, 1e6, 50e18);
        swapExactIn(poolKey, moveSeed % 2 == 0, bound(moveSeed, 0, 40e18) + 1);
        nextBlock();
        (uint256 b0, uint256 b1) = balancesOf(address(this));

        BatchSwapRouter.SwapAction[] memory legs = new BatchSwapRouter.SwapAction[](1);
        legs[0] = BatchSwapRouter.SwapAction(poolKey, SwapParams(zeroForOne, -int256(amount), _limit(zeroForOne)));
        batchRouter.swapBatch(address(this), legs);
        (uint256 m0, uint256 m1) = balancesOf(address(this));
        uint256 received = zeroForOne ? m1 - b1 : m0 - b0;
        if (received > 0) {
            legs[0] =
                BatchSwapRouter.SwapAction(poolKey, SwapParams(!zeroForOne, -int256(received), _limit(!zeroForOne)));
            batchRouter.swapBatch(address(this), legs);
        }
        (uint256 a0, uint256 a1) = balancesOf(address(this));
        assertLe(a0, b0, "no profit in currency0");
        assertLe(a1, b1, "no profit in currency1");
    }

    /// @notice The Bunni lesson at the pool level: 50 tiny surcharged swaps pay at least as much surcharge as one
    /// swap of the same total size (each leg starts on the range edge the previous one set, and ceil rounding means
    /// splitting can only cost more), and never pay out more.
    function test_ToB3_fiftyTinySwapsCannotUndercutOneSwap() public {
        _createVolatility();
        uint256 snapshot = vm.snapshotState();
        uint256 splitSurcharge;
        uint256 splitOutput;
        for (uint256 i; i < 50; ++i) {
            SwapObservation memory o = observeSwap(poolKey, true, -0.2e18);
            splitSurcharge += o.surcharge1;
            splitOutput += uint256(o.traderDelta1);
        }
        vm.revertToState(snapshot);
        SwapObservation memory whole = observeSwap(poolKey, true, -10e18);
        assertGe(splitSurcharge, whole.surcharge1, "splitting never lowers the surcharge");
        assertLe(splitOutput, uint256(whole.traderDelta1), "splitting never pays out more");
    }

    /// @notice Split invariance at the pool level, with constant in-range liquidity: after the block's first swap set
    /// one edge of the range, a swap to ANY target price (either direction, across the block's opening price or not,
    /// exact input or exact output) is charged the same total surcharge whether it runs in one piece or is split at
    /// ANY intermediate price, up to one wei of rounding for the extra leg. The external review's cliff (a crossing
    /// swap paying 0 or 0.5% of its whole amount depending on 2 ticks of end price) cannot pass this.
    function testFuzz_ToB3_splittingASwapCannotUndercutTheSurcharge(
        bool firstUp,
        uint256 firstAmount,
        int256 targetTicks,
        uint256 splitSeed,
        bool exactOut
    ) public {
        _createVolatility();
        swapExactIn(poolKey, !firstUp, bound(firstAmount, 1e15, 20e18)); // the block's first swap sets one range edge
        uint160 start = currentSqrtPrice(poolId);
        int24 t = currentTick(poolId) + int24(bound(targetTicks, -1500, 1500));
        uint160 target = TickMath.getSqrtPriceAtTick(t);
        if (target == start) target = TickMath.getSqrtPriceAtTick(t + 1);
        bool zeroForOne = target < start;
        (uint160 lo, uint160 hi) = zeroForOne ? (target, start) : (start, target);
        vm.assume(hi - lo >= 2);
        uint160 mid = uint160(bound(splitSeed, uint256(lo) + 1, uint256(hi) - 1));
        int256 amount = exactOut ? int256(1e30) : -1e30; // the price limit decides where each leg stops

        uint256 snapshot = vm.snapshotState();
        SwapObservation memory one = observeSwap(poolKey, zeroForOne, amount, target);
        uint256 single = one.surcharge0 + one.surcharge1;
        IVolatilityFeeHook.PoolState memory rangeAfterSingle = state();
        vm.revertToState(snapshot);
        SwapObservation memory a = observeSwap(poolKey, zeroForOne, amount, mid);
        SwapObservation memory b = observeSwap(poolKey, zeroForOne, amount, target);
        uint256 split = a.surcharge0 + a.surcharge1 + b.surcharge0 + b.surcharge1;

        assertEq(currentSqrtPrice(poolId), target, "both paths end at the target");
        assertEq(state().lowSqrtPriceX96, rangeAfterSingle.lowSqrtPriceX96, "same range");
        assertEq(state().highSqrtPriceX96, rangeAfterSingle.highSqrtPriceX96, "same range");
        assertGe(split + 1, single, "splitting never lowers the surcharge (1 wei rounding)");
        assertLe(split, single + 1, "and never raises it by more than 1 wei");
    }

    /// @notice 50 add/remove cycles in a volatile pool never return more than was deposited.
    function test_ToB3_fiftyLiquidityCyclesCannotExtractValue() public {
        _createVolatility();
        (uint256 b0, uint256 b1) = balancesOf(address(this));
        for (uint256 i; i < 50; ++i) {
            addLiquidity(poolKey, -180, 180, uint128(3e18 + i), bytes32(i));
            removeLiquidity(poolKey, -180, 180, uint128(3e18 + i), bytes32(i));
        }
        (uint256 a0, uint256 a1) = balancesOf(address(this));
        assertLe(a0, b0);
        assertLe(a1, b1);
    }

    // ================================================================ 4. Right logic, wrong hook

    /// @notice The fee is priced in beforeSwap from the block's opening price, so the first swap of a block cannot
    /// influence its own fee: a tiny and a huge first swap pay the same rate.
    function test_ToB4_firstSwapCannotPriceItsOwnFee() public {
        swapExactIn(poolKey, true, 10e18);
        nextBlock();
        uint256 snapshot = vm.snapshotState();
        uint24 tinyFee = observeSwap(poolKey, false, -1e6).fee;
        vm.revertToState(snapshot);
        uint24 hugeFee = observeSwap(poolKey, false, -80e18).fee;
        assertEq(tinyFee, hugeFee);
    }

    /// @notice The surcharge is donated in afterSwap, so it reaches the LPs in range AFTER the swap. LP fees are only
    /// charged on the input currency (currency0 here), so the currency1 fee growth of each range isolates the donation.
    function test_ToB4_donationReachesPostSwapLiquidityOnly() public {
        (PoolKey memory k, PoolId id) =
            initPool(currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 30, SQRT_PRICE_1_1);
        addLiquidity(k, -120, 120, 100e18, 0); // range A: in range before the swap only
        addLiquidity(k, -2400, -120, 100e18, 0); // range B: in range after the swap only
        swapExactIn(k, false, 0.5e18); // create some volatility inside A (its LP fee accrues in currency1)
        nextBlock();
        (, uint256 a1Before) = manager.getFeeGrowthInside(id, -120, 120);
        (, uint256 b1Before) = manager.getFeeGrowthInside(id, -2400, -120);

        // zeroForOne: LP fees accrue in currency0, the surcharge is taken from the currency1 output.
        SwapObservation memory o = observeSwap(k, true, -1000e18, TickMath.getSqrtPriceAtTick(-600));
        assertGt(o.surcharge1, 0, "surcharged");

        (, uint256 a1After) = manager.getFeeGrowthInside(id, -120, 120);
        (, uint256 b1After) = manager.getFeeGrowthInside(id, -2400, -120);
        assertEq(a1After, a1Before, "range A (in range before the swap) received none of the donation");
        assertGt(b1After, b1Before, "range B (in range after the swap) received the donation");
    }

    // ================================================================ 5. Address bits are part of the API

    function test_ToB5_addressBitsDeclaredPermissionsAndCallbacksAgree() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        uint160 declared = (p.beforeInitialize ? Hooks.BEFORE_INITIALIZE_FLAG : 0)
            | (p.afterAddLiquidity ? Hooks.AFTER_ADD_LIQUIDITY_FLAG : 0)
            | (p.afterRemoveLiquidity ? Hooks.AFTER_REMOVE_LIQUIDITY_FLAG : 0)
            | (p.beforeSwap ? Hooks.BEFORE_SWAP_FLAG : 0) | (p.afterSwap ? Hooks.AFTER_SWAP_FLAG : 0)
            | (p.afterSwapReturnDelta ? Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG : 0);
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, declared, "see HookPermissions.t.sol for the full check");
        assertFalse(p.afterInitialize || p.beforeAddLiquidity || p.beforeRemoveLiquidity || p.beforeDonate);
        assertFalse(p.afterDonate || p.beforeSwapReturnDelta || p.afterAddLiquidityReturnDelta);
        assertFalse(p.afterRemoveLiquidityReturnDelta, "exits can never be taxed");
    }

    // ================================================================ 6. Hook failures can block pool actions

    /// @notice The module is never called from a liquidity operation: a gas-burning module cannot block an exit, and
    /// its later delivery fails on its own without affecting anything else.
    function test_ToB6_hostileModuleCannotBlockExit() public {
        GasGuzzlerModule guzzler = new GasGuzzlerModule();
        vm.prank(owner);
        hook.setLiquidityModule(guzzler);
        vm.recordLogs();
        addLiquidity(poolKey, -600, 600, 10e18, bytes32("x"));
        removeLiquidity(poolKey, -600, 600, 10e18, bytes32("x"));
        Queued[] memory q = queuedIn(vm.getRecordedLogs(), address(hook));
        (uint128 liquidity,,) = manager.getPositionInfo(poolId, address(modifyLiquidityRouter), -600, 600, bytes32("x"));
        assertEq(liquidity, 0, "see ExitAlwaysWorks.t.sol for the full hostile-module suite");
        assertFalse(deliver(q[1]), "the module fails later, in the keeper's transaction");
    }

    /// @notice The oracle cannot revert on extreme prices: a jump from the minimum to the maximum tick is folded in
    /// and the fee clamps at 100 bps.
    function test_ToB6_extremePriceJumpsNeverBreakSwaps() public {
        (PoolKey memory k, PoolId id) =
            initPool(currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 20, SQRT_PRICE_1_1);
        swapWithLimit(k, true, -1e18, MIN_PRICE_LIMIT); // no liquidity: price runs to the minimum
        nextBlock();
        swapWithLimit(k, false, -1e18, MAX_PRICE_LIMIT); // and to the maximum
        nextBlock();
        swapWithLimit(k, true, -1e18, MIN_PRICE_LIMIT);
        IVolatilityFeeHook.PoolState memory s = hook.getPoolState(id);
        assertEq(s.lpFeePips, 10_000);
        assertLe(s.ewmaWad, uint256(uint24(TickMath.MAX_TICK - TickMath.MIN_TICK)) * 1e18);
    }

    // ================================================================ 7. State can change during a callback sequence

    /// @notice Swaps in two pools interleaved inside ONE unlock: per-pool state (keyed by PoolId) never mixes, and the
    /// hook's PoolManager delta is zero right after every single swap (asserted inside the router).
    function test_ToB7_interleavedPoolsInOneUnlock() public {
        (PoolKey memory other, PoolId otherId) =
            initPool(currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 10, SQRT_PRICE_1_1);
        addLiquidity(other, -6000, 6000, 1000e18, 0);
        swapExactIn(poolKey, true, 30e18); // volatility in the main pool only
        nextBlock();

        BatchSwapRouter.SwapAction[] memory legs = new BatchSwapRouter.SwapAction[](4);
        legs[0] = BatchSwapRouter.SwapAction(poolKey, SwapParams(true, -5e18, MIN_PRICE_LIMIT));
        legs[1] = BatchSwapRouter.SwapAction(other, SwapParams(false, -5e18, MAX_PRICE_LIMIT));
        legs[2] = BatchSwapRouter.SwapAction(poolKey, SwapParams(false, -2e18, MAX_PRICE_LIMIT));
        legs[3] = BatchSwapRouter.SwapAction(other, SwapParams(true, -9e18, MIN_PRICE_LIMIT));
        vm.recordLogs();
        batchRouter.swapBatch(address(this), legs);
        SwapObservation memory o;
        o = _decodeSwapLogs(vm.getRecordedLogs(), o);

        assertEq(o.swapEvents, 4);
        assertGt(state().surchargePips, 0, "main pool is volatile");
        assertEq(hook.getPoolState(otherId).surchargePips, 0, "other pool's state untouched by main pool swaps");
        assertEq(o.donated0 + o.donated1, o.surcharge0 + o.surcharge1, "every surcharge donated");
    }

    /// @notice A module that tries to trade in the pool when notified can neither do it mid-exit (it is not called
    /// there) nor at delivery (the PoolManager is locked): the pool's price and oracle state are untouched.
    function test_ToB7_moduleCannotMutatePoolStateMidExit() public {
        _createVolatility();
        swapExactIn(poolKey, true, 1e18);
        NestedSwapModule nested = new NestedSwapModule(manager);
        vm.prank(owner);
        hook.setLiquidityModule(nested);
        addLiquidity(poolKey, -600, 600, 10e18, bytes32("y"));
        IVolatilityFeeHook.PoolState memory before = state();
        uint160 priceBefore = currentSqrtPrice(poolId);

        nextBlock(); // a nested swap would now also update the oracle
        vm.recordLogs();
        removeLiquidity(poolKey, -600, 600, 10e18, bytes32("y"));
        Queued[] memory q = queuedIn(vm.getRecordedLogs(), address(hook));
        assertFalse(deliver(q[0]), "the nested swap reverts with ManagerLocked");
        assertEq(nested.completedCalls(), 0);

        IVolatilityFeeHook.PoolState memory afterExit = state();
        assertEq(currentSqrtPrice(poolId), priceBefore, "no trade happened");
        assertEq(afterExit.anchorBlock, before.anchorBlock, "oracle not advanced");
        assertEq(afterExit.ewmaWad, before.ewmaWad);
    }

    // ---------------------------------------------------------------------------------------------------- helpers

    function _createVolatility() internal {
        swapExactIn(poolKey, false, 30e18);
        nextBlock();
    }

    function _limit(bool zeroForOne) internal pure returns (uint160) {
        return zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT;
    }
}

interface MockERC20Like {
    function approve(address spender, uint256 amount) external returns (bool);
}
