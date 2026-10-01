// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Vm} from "forge-std/Vm.sol";

import {HookFixture} from "../utils/HookFixture.sol";
import {BatchSwapRouter, NestedUnlockSwapRouter} from "../utils/Routers.sol";
import {FeeOnTransferToken, RebasingToken} from "../utils/mocks/NonStandardTokens.sol";
import {VolatilityFeeHook} from "../../src/VolatilityFeeHook.sol";
import {IVolatilityFeeHook} from "../../src/interfaces/IVolatilityFeeHook.sol";

/// @notice Adversarial suite: malicious PoolKeys, fee-on-transfer and rebasing currencies, nested unlock attempts,
/// extreme fee configurations and amounts, and many swaps in one block / one transaction.
contract AdversarialTest is HookFixture {
    using StateLibrary for IPoolManager;

    bytes32 internal constant VOL_UPDATED_TOPIC =
        keccak256("VolatilityUpdated(bytes32,int24,uint256,uint256,uint256,uint24,uint24)");

    function setUp() public {
        setUpEnvironment();
    }

    // ============================================================================ malicious PoolKeys

    /// @notice Re-initializing an existing pool runs beforeInitialize first, but the PoolManager then reverts, so the
    /// hook's state for that pool cannot be reset by an attacker.
    function test_maliciousKey_reinitializationCannotResetState() public {
        swapExactIn(poolKey, true, 30e18);
        nextBlock();
        swapExactIn(poolKey, true, 1e18);
        IVolatilityFeeHook.PoolState memory before = state();
        assertGt(before.ewmaWad, 0);

        vm.expectRevert(Pool.PoolAlreadyInitialized.selector);
        manager.initialize(poolKey, SQRT_PRICE_4_1);

        IVolatilityFeeHook.PoolState memory afterAttempt = state();
        assertEq(afterAttempt.ewmaWad, before.ewmaWad);
        assertEq(afterAttempt.lowSqrtPriceX96, before.lowSqrtPriceX96);
        assertEq(afterAttempt.highSqrtPriceX96, before.highSqrtPriceX96);
    }

    function test_maliciousKey_extremeTickSpacingsWork() public {
        int24[2] memory spacings = [TickMath.MIN_TICK_SPACING, TickMath.MAX_TICK_SPACING];
        for (uint256 i; i < spacings.length; ++i) {
            (PoolKey memory k, PoolId id) = initPool(
                currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, spacings[i], SQRT_PRICE_1_1
            );
            int24 lower = TickMath.minUsableTick(spacings[i]);
            int24 upper = TickMath.maxUsableTick(spacings[i]);
            addLiquidity(k, lower, upper, 100e18, 0);
            swapExactIn(k, true, 1e18);
            nextBlock();
            swapExactIn(k, false, 1e18);
            assertTrue(hook.getPoolState(id).registered);
        }
    }

    /// @notice hookData is ignored: arbitrary bytes cannot change what a swap pays.
    function testFuzz_maliciousKey_hookDataIsIgnored(bytes calldata hookData) public {
        swapExactIn(poolKey, false, 30e18);
        nextBlock();
        SwapParams memory p = SwapParams(true, -5e18, MIN_PRICE_LIMIT);
        PoolSwapTest.TestSettings memory ts = PoolSwapTest.TestSettings(false, false);
        uint256 snapshot = vm.snapshotState();
        BalanceDelta withoutData = swapRouter.swap(poolKey, p, ts, ZERO_BYTES);
        vm.revertToState(snapshot);
        BalanceDelta withData = swapRouter.swap(poolKey, p, ts, hookData);
        assertEq(BalanceDelta.unwrap(withData), BalanceDelta.unwrap(withoutData));
    }

    function test_maliciousKey_uninitializedPoolIsRejectedBeforeTheHook() public {
        PoolKey memory ghost = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 7, IHooks(address(hook)));
        vm.expectRevert(IPoolManager.PoolNotInitialized.selector);
        swapExactIn(ghost, true, 1e18);
    }

    function test_maliciousKey_unsortedOrDuplicateCurrenciesRejected() public {
        PoolKey memory dup = PoolKey(currency0, currency0, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(address(hook)));
        vm.expectRevert(
            abi.encodeWithSelector(
                IPoolManager.CurrenciesOutOfOrderOrEqual.selector,
                Currency.unwrap(currency0),
                Currency.unwrap(currency0)
            )
        );
        manager.initialize(dup, SQRT_PRICE_1_1);
    }

    // ============================================================================ non-standard tokens

    function test_feeOnTransfer_rejectedUnlessAllowlisted() public {
        address token = address(new FeeOnTransferToken());
        (PoolKey memory k,) = _nonStandardPool(token, false);
        vm.expectRevert(_notAllowed(token));
        manager.initialize(k, SQRT_PRICE_1_1);
    }

    /// @notice Why the allowlist exists: if a fee-on-transfer token were allowlisted by mistake, the PoolManager would
    /// receive less than the router paid and deposits could never settle. The hook moves no tokens, so its own
    /// accounting is unaffected.
    function test_feeOnTransfer_allowlistedByMistake_depositsCannotSettle() public {
        FeeOnTransferToken fot = new FeeOnTransferToken();
        fot.mint(address(this), 1_000_000e18);
        fot.approve(address(modifyLiquidityRouter), type(uint256).max);
        (PoolKey memory k,) = _nonStandardPool(address(fot), true);
        manager.initialize(k, SQRT_PRICE_1_1);

        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        modifyLiquidityRouter.modifyLiquidity(
            k, ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 1e18, salt: 0}), ZERO_BYTES
        );
        assertEq(fot.balanceOf(address(hook)), 0);
    }

    function test_rebasing_rejectedUnlessAllowlisted() public {
        address token = address(new RebasingToken());
        (PoolKey memory k,) = _nonStandardPool(token, false);
        vm.expectRevert(_notAllowed(token));
        manager.initialize(k, SQRT_PRICE_1_1);
    }

    /// @notice Why the allowlist exists: with a rebasing token allowlisted by mistake, a negative rebase leaves the
    /// PoolManager holding fewer tokens than it owes, so the LP can no longer withdraw everything. This is a
    /// PoolManager-level insolvency the hook cannot fix; it can only keep such tokens out.
    function test_rebasing_allowlistedByMistake_negativeRebaseBreaksFullExit() public {
        RebasingToken reb = new RebasingToken();
        reb.mint(address(this), 1_000_000e18);
        reb.approve(address(modifyLiquidityRouter), type(uint256).max);
        reb.approve(address(swapRouter), type(uint256).max);
        (PoolKey memory k,) = _nonStandardPool(address(reb), true);
        manager.initialize(k, SQRT_PRICE_1_1);
        addLiquidity(k, -600, 600, 100e18, 0);
        swapExactIn(k, true, 0.1e18);
        nextBlock();
        swapExactIn(k, false, 0.1e18);
        assertEq(reb.balanceOf(address(hook)), 0, "hook never holds the token");

        reb.rebase(0.5e18); // the PoolManager's balance halves
        // The PoolManager's transfer of the rebasing token underflows its share balance (Panic 0x11), which v4-core
        // reports as a wrapped ERC20TransferFailed.
        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("WrappedError(address,bytes4,bytes,bytes)")),
                address(reb),
                IERC20Minimal.transfer.selector,
                abi.encodeWithSignature("Panic(uint256)", uint256(0x11)),
                abi.encodeWithSelector(CurrencyLibrary.ERC20TransferFailed.selector)
            )
        );
        removeLiquidity(k, -600, 600, 100e18, 0);
    }

    // ============================================================================ nested unlock

    /// @notice A router swaps in the hook pool (the block's first swap: oracle update, surcharge, donation), tries
    /// to open a nested unlock from the same callback (rejected with AlreadyUnlocked and caught), then swaps in the
    /// hook pool again. The hook's per-swap hand-off and per-block state are unaffected by the rejected attempt: the
    /// outcome is identical to the same two swaps without it.
    function test_nestedUnlock_betweenTwoHookPoolSwapsChangesNothing() public {
        swapExactIn(poolKey, false, 30e18);
        nextBlock();
        SwapParams memory first = SwapParams(true, -5e18, MIN_PRICE_LIMIT);
        SwapParams memory second = SwapParams(true, -3e18, MIN_PRICE_LIMIT);

        uint256 snapshot = vm.snapshotState();
        BatchSwapRouter plain = new BatchSwapRouter(manager);
        MockToken(Currency.unwrap(currency0)).approve(address(plain), type(uint256).max);
        MockToken(Currency.unwrap(currency1)).approve(address(plain), type(uint256).max);
        BatchSwapRouter.SwapAction[] memory legs = new BatchSwapRouter.SwapAction[](2);
        legs[0] = BatchSwapRouter.SwapAction(poolKey, first);
        legs[1] = BatchSwapRouter.SwapAction(poolKey, second);
        vm.recordLogs();
        plain.swapBatch(address(this), legs);
        SwapObservation memory expected;
        expected = _decodeSwapLogs(vm.getRecordedLogs(), expected);
        IVolatilityFeeHook.PoolState memory expectedState = state();
        vm.revertToState(snapshot);

        NestedUnlockSwapRouter router = new NestedUnlockSwapRouter(manager);
        MockToken(Currency.unwrap(currency0)).approve(address(router), type(uint256).max);
        MockToken(Currency.unwrap(currency1)).approve(address(router), type(uint256).max);
        vm.recordLogs();
        router.swapTwiceWithNestedUnlock(poolKey, first, second);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        SwapObservation memory got;
        got = _decodeSwapLogs(logs, got);

        assertTrue(router.nestedUnlockRejected());
        assertEq(router.nestedUnlockError(), abi.encodeWithSelector(IPoolManager.AlreadyUnlocked.selector));
        assertEq(got.swapEvents, 2);
        assertEq(_count(logs, VOL_UPDATED_TOPIC), 1, "one oracle update for the block");
        assertGt(got.surcharge1, 0);
        assertEq(got.surcharge1, expected.surcharge1, "same surcharges as without the nested attempt");
        assertEq(got.donated1, got.surcharge1);
        assertEq(keccak256(abi.encode(state())), keccak256(abi.encode(expectedState)), "same pool state");
        assertEq(currency0.balanceOf(address(hook)) + currency1.balanceOf(address(hook)), 0);
    }

    /// @notice The hook never opens an unlock of its own: its callbacks run inside the caller's unlock, and it
    /// exposes no unlockCallback an attacker could drive.
    function test_nestedUnlock_hookHasNoUnlockCallback() public {
        (bool ok,) = address(hook).call(abi.encodeWithSignature("unlockCallback(bytes)", ""));
        assertFalse(ok);
    }

    // ============================================================================ extreme fees and amounts

    function test_extremeConfig_maximumSlopesAndCaps() public {
        VolatilityFeeHook extreme = _deployWithConfig(
            IVolatilityFeeHook.FeeConfig({
                alphaWad: 1e18, feeSlopePips: 10_000, surchargeSlopePips: 10_000, maxSurchargePips: 10_000
            })
        );
        (PoolKey memory k, PoolId id) =
            initPool(currency0, currency1, IHooks(address(extreme)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, SQRT_PRICE_1_1);
        addLiquidity(k, -6000, 6000, 1000e18, 0);
        swapExactIn(k, true, 0.1e18); // a couple of ticks is enough to saturate everything
        nextBlock();

        (uint256 b0, uint256 b1) = balancesOf(address(this));
        vm.recordLogs();
        swapExactIn(k, false, 10e18);
        SwapObservation memory o;
        o = _decodeSwapLogsFor(extreme, vm.getRecordedLogs(), o);
        (uint256 a0, uint256 a1) = balancesOf(address(this));
        assertEq(o.fee, 10_000, "fee clamped at 100 bps");
        assertEq(extreme.getPoolState(id).surchargePips, 10_000, "surcharge clamped at 1%");
        assertEq(o.surcharge0, (uint256(int256(o.poolAmount0)) * 10_000 + 1e6 - 1) / 1e6, "1% of the output");
        assertEq(b1 - a1, 10e18, "exact input");
        assertEq(a0 - b0, uint256(int256(o.poolAmount0)) - o.surcharge0, "output net of surcharge, never negative");
        assertEq(currency0.balanceOf(address(extreme)) + currency1.balanceOf(address(extreme)), 0);
    }

    function test_extremeConfig_zeroSlopesMeanStaticFiveBps() public {
        VolatilityFeeHook flat = _deployWithConfig(
            IVolatilityFeeHook.FeeConfig({alphaWad: 1, feeSlopePips: 0, surchargeSlopePips: 0, maxSurchargePips: 0})
        );
        (PoolKey memory k,) =
            initPool(currency0, currency1, IHooks(address(flat)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, SQRT_PRICE_1_1);
        addLiquidity(k, -6000, 6000, 1000e18, 0);
        for (uint256 i; i < 5; ++i) {
            swapExactIn(k, i % 2 == 0, 50e18);
            nextBlock();
            vm.recordLogs();
            swapExactIn(k, i % 2 == 1, 1e18);
            SwapObservation memory o;
            o = _decodeSwapLogsFor(flat, vm.getRecordedLogs(), o);
            assertEq(o.fee, 500);
            assertEq(o.surcharge0 + o.surcharge1, 0);
        }
    }

    /// @notice Any valid configuration, any market: fees stay within [5, 100] bps, surcharges within the cap, and
    /// the hook never keeps a token.
    function testFuzz_extremeConfig_anyValidConfigIsSafe(
        uint64 alpha,
        uint24 feeSlope,
        uint24 surchargeSlope,
        uint24 cap,
        uint256 seed
    ) public {
        IVolatilityFeeHook.FeeConfig memory c = IVolatilityFeeHook.FeeConfig({
            alphaWad: uint64(bound(alpha, 1, 1e18)),
            feeSlopePips: uint24(bound(feeSlope, 0, 10_000)),
            surchargeSlopePips: uint24(bound(surchargeSlope, 0, 10_000)),
            maxSurchargePips: uint24(bound(cap, 0, 10_000))
        });
        VolatilityFeeHook h = _deployWithConfig(c);
        (PoolKey memory k, PoolId id) =
            initPool(currency0, currency1, IHooks(address(h)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, SQRT_PRICE_1_1);
        addLiquidity(k, -6000, 6000, 1000e18, 0);
        for (uint256 i; i < 6; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            if (r % 3 != 0) nextBlock();
            vm.recordLogs();
            swapExactIn(k, r % 2 == 0, bound(r >> 16, 1, 60e18));
            SwapObservation memory o;
            o = _decodeSwapLogsFor(h, vm.getRecordedLogs(), o);
            assertGe(o.fee, 500);
            assertLe(o.fee, 10_000);
            IVolatilityFeeHook.PoolState memory s = h.getPoolState(id);
            assertLe(s.surchargePips, c.maxSurchargePips);
            assertEq(o.donated0 + o.donated1, o.surcharge0 + o.surcharge1);
        }
        assertEq(currency0.balanceOf(address(h)) + currency1.balanceOf(address(h)), 0);
    }

    /// @notice Enormous exact-input and exact-output requests drain the range without reverting; when no liquidity is
    /// left in range the surcharge is skipped rather than blocking the swap.
    function test_extremeAmounts_drainingSwapsDoNotRevert() public {
        swapExactIn(poolKey, false, 30e18);
        nextBlock();
        swapExactIn(poolKey, true, 2 ** 120);
        assertEq(manager.getLiquidity(poolId), 0, "range drained");
        nextBlock();
        swapExactOut(poolKey, false, 2 ** 120);
        assertEq(currency0.balanceOf(address(hook)) + currency1.balanceOf(address(hook)), 0);
    }

    // ============================================================================ many swaps

    /// @notice 200 swaps in one block: the oracle updates exactly once, every swap pays the same LP fee, and every
    /// surcharge is donated.
    function test_manySwapsInOneBlock() public {
        swapExactIn(poolKey, true, 30e18);
        nextBlock();
        vm.recordLogs();
        for (uint256 i; i < 200; ++i) {
            uint256 amount = 1e15 + (uint256(keccak256(abi.encode(i))) % 3e18);
            swapExactIn(poolKey, i % 3 != 0, amount);
        }
        Vm.Log[] memory logs = vm.getRecordedLogs();
        SwapObservation memory o;
        o = _decodeSwapLogs(logs, o);
        assertEq(o.swapEvents, 200);
        assertEq(_count(logs, VOL_UPDATED_TOPIC), 1, "one oracle update per block");
        assertEq(o.donated0, o.surcharge0);
        assertEq(o.donated1, o.surcharge1);
        _assertSameFeeForAllSwaps(logs, state().lpFeePips);
    }

    /// @notice 60 swaps inside ONE unlock (one transaction); the router asserts after every swap that the hook has
    /// no open delta.
    function test_manySwapsInOneTransaction() public {
        BatchSwapRouter router = new BatchSwapRouter(manager);
        MockToken(Currency.unwrap(currency0)).approve(address(router), type(uint256).max);
        MockToken(Currency.unwrap(currency1)).approve(address(router), type(uint256).max);
        swapExactIn(poolKey, false, 30e18);
        nextBlock();

        BatchSwapRouter.SwapAction[] memory legs = new BatchSwapRouter.SwapAction[](60);
        for (uint256 i; i < legs.length; ++i) {
            bool zeroForOne = i % 2 == 0;
            legs[i] = BatchSwapRouter.SwapAction(
                poolKey, SwapParams(zeroForOne, -int256(1e17 * (i + 1)), zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT)
            );
        }
        router.swapBatch(address(this), legs);
        assertEq(currency0.balanceOf(address(hook)) + currency1.balanceOf(address(hook)), 0);
    }

    /// @notice The first swap after a very long idle period stays cheap: the decay loop is O(log k).
    function test_longIdlePeriod_oracleUpdateGasIsBounded() public {
        swapExactIn(poolKey, true, 30e18);
        vm.roll(vm.getBlockNumber() + 2 ** 32);
        uint256 g = gasleft();
        swapExactIn(poolKey, false, 1e18);
        uint256 used = g - gasleft();
        assertLt(used, 250_000);
        assertEq(state().ewmaWad, 0, "a 4-billion-block gap forgets everything");
    }

    // ---------------------------------------------------------------------------------------------- helpers

    function _notAllowed(address token) internal view returns (bytes memory) {
        return wrappedHookError(
            IHooks.beforeInitialize.selector,
            abi.encodeWithSelector(IVolatilityFeeHook.CurrencyNotAllowed.selector, Currency.wrap(token))
        );
    }

    function _nonStandardPool(address token, bool allow) internal returns (PoolKey memory k, PoolId id) {
        Currency weird = Currency.wrap(token);
        if (allow) {
            vm.prank(owner);
            hook.setCurrencyAllowed(weird, true);
        }
        (Currency c0, Currency c1) = weird < currency1 ? (weird, currency1) : (currency1, weird);
        k = PoolKey(c0, c1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(address(hook)));
        id = k.toId();
    }

    uint160 internal deployNonce;

    /// @dev Places the hook at a fresh address carrying HOOK_FLAGS without mining a salt (the constructor still
    /// validates the address bits). Mining per fuzz run would dominate the suite's runtime.
    function _deployWithConfig(IVolatilityFeeHook.FeeConfig memory c) internal returns (VolatilityFeeHook h) {
        address target = address(uint160(0x4444 + ++deployNonce) << 20 | HOOK_FLAGS);
        deployCodeTo("VolatilityFeeHook.sol:VolatilityFeeHook", abi.encode(manager, owner, c), target);
        h = VolatilityFeeHook(target);
        vm.startPrank(owner);
        h.setCurrencyAllowed(currency0, true);
        h.setCurrencyAllowed(currency1, true);
        vm.stopPrank();
    }

    function _decodeSwapLogsFor(VolatilityFeeHook h, Vm.Log[] memory logs, SwapObservation memory o)
        internal
        returns (SwapObservation memory)
    {
        VolatilityFeeHook saved = hook;
        hook = h;
        o = _decodeSwapLogs(logs, o);
        hook = saved;
        return o;
    }

    function _count(Vm.Log[] memory logs, bytes32 topic) internal view returns (uint256 n) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == topic) ++n;
        }
    }

    function _assertSameFeeForAllSwaps(Vm.Log[] memory logs, uint24 expectedFee) internal view {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == SWAP_TOPIC) {
                (,,,,, uint24 fee) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                assertEq(fee, expectedFee);
            }
        }
    }
}

interface MockToken {
    function approve(address spender, uint256 amount) external returns (bool);
}
