// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Lock} from "@uniswap/v4-core/src/libraries/Lock.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {ImmutableState} from "@uniswap/v4-periphery/src/base/ImmutableState.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {HookFixture} from "../utils/HookFixture.sol";
import {UnlockedDeliveryRouter} from "../utils/Routers.sol";
import {RevertingModule, CountingModule} from "../utils/mocks/HostileModules.sol";
import {VolatilityFeeHook} from "../../src/VolatilityFeeHook.sol";
import {IVolatilityFeeHook} from "../../src/interfaces/IVolatilityFeeHook.sol";
import {ILiquidityModule} from "../../src/interfaces/ILiquidityModule.sol";
import {LiquidityTelemetry} from "../../src/modules/LiquidityTelemetry.sol";
import {VolatilityMath} from "../../src/libraries/VolatilityMath.sol";

/// @notice Unit tests: every happy path and every revert path of VolatilityFeeHook and LiquidityTelemetry.
contract VolatilityFeeHookTest is HookFixture {
    using StateLibrary for IPoolManager;

    function setUp() public {
        setUpEnvironment();
    }

    // =========================================================================================== construction

    function test_constructor_setsConfigAndOwner() public view {
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(hook.owner(), owner);
        assertEq(hook.alphaWad(), 0.1e18);
        assertEq(hook.feeSlopePips(), 500);
        assertEq(hook.surchargeSlopePips(), 250);
        assertEq(hook.maxSurchargePips(), 5000);
        assertEq(hook.MIN_FEE_PIPS(), 500);
        assertEq(hook.MAX_FEE_PIPS(), 10_000);
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, HOOK_FLAGS);
        assertEq(address(hook.liquidityModule()), address(0));
        assertEq(hook.notificationCount(), 0);
    }

    function test_constructor_revertsOnZeroAlpha() public {
        IVolatilityFeeHook.FeeConfig memory c = defaultConfig();
        c.alphaWad = 0;
        _expectConstructorRevert(c, abi.encodeWithSelector(IVolatilityFeeHook.InvalidAlpha.selector, 0));
    }

    function test_constructor_revertsOnAlphaAboveOne() public {
        IVolatilityFeeHook.FeeConfig memory c = defaultConfig();
        c.alphaWad = 1e18 + 1;
        _expectConstructorRevert(c, abi.encodeWithSelector(IVolatilityFeeHook.InvalidAlpha.selector, 1e18 + 1));
    }

    function test_constructor_revertsOnFeeSlopeTooLarge() public {
        IVolatilityFeeHook.FeeConfig memory c = defaultConfig();
        c.feeSlopePips = 10_001;
        _expectConstructorRevert(
            c, abi.encodeWithSelector(IVolatilityFeeHook.ParameterTooLarge.selector, 10_001, 10_000)
        );
    }

    function test_constructor_revertsOnSurchargeSlopeTooLarge() public {
        IVolatilityFeeHook.FeeConfig memory c = defaultConfig();
        c.surchargeSlopePips = 10_001;
        _expectConstructorRevert(
            c, abi.encodeWithSelector(IVolatilityFeeHook.ParameterTooLarge.selector, 10_001, 10_000)
        );
    }

    function test_constructor_revertsOnSurchargeCapTooLarge() public {
        IVolatilityFeeHook.FeeConfig memory c = defaultConfig();
        c.maxSurchargePips = 10_001;
        _expectConstructorRevert(
            c, abi.encodeWithSelector(IVolatilityFeeHook.ParameterTooLarge.selector, 10_001, 10_000)
        );
    }

    function test_constructor_revertsOnZeroOwner() public {
        bytes memory args = abi.encode(manager, address(0), defaultConfig());
        (, bytes32 salt) = HookMiner.find(address(this), HOOK_FLAGS, type(VolatilityFeeHook).creationCode, args);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new VolatilityFeeHook{salt: salt}(manager, address(0), defaultConfig());
    }

    function test_constructor_revertsAtAddressWithoutFlagBits() public {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        assertTrue(uint160(predicted) & Hooks.ALL_HOOK_MASK != HOOK_FLAGS, "precondition: unmined address");
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, predicted));
        new VolatilityFeeHook(manager, owner, defaultConfig());
    }

    function test_transientSlotConstantsMatchV4Core() public pure {
        // The hook copies the PoolManager's lock slot (BUSL-1.1 Lock library) instead of importing it.
        assertEq(Lock.IS_UNLOCKED_SLOT, 0xc090fc4683624cfc3884e9d8de5eca132f2d0ec062aff75d43c0465d5ceeab23);
        // ERC-7201-style namespace of the pre-swap price slot.
        bytes32 expected = keccak256(abi.encode(uint256(keccak256("volatility-fee-hook.transient.pre-swap-price")) - 1))
            & ~bytes32(uint256(0xff));
        assertEq(expected, 0x878f53a242355742de3ed8de9af479fd10062a388ce88ba52470cea775977600);
    }

    /// @notice The test helpers decode the hook's events by hashed signature; the hashes must match the interface.
    function test_eventTopicsUsedByTheTestsMatchTheInterface() public pure {
        assertEq(QUEUED_TOPIC, IVolatilityFeeHook.LiquidityNotificationQueued.selector);
        assertEq(DELIVERED_TOPIC, IVolatilityFeeHook.LiquidityNotificationDelivered.selector);
        assertEq(
            keccak256("VolatilityUpdated(bytes32,int24,uint256,uint256,uint256,uint24,uint24)"),
            IVolatilityFeeHook.VolatilityUpdated.selector
        );
    }

    // =========================================================================================== admin

    function test_setCurrencyAllowed_ownerOnlyAndEmits() public {
        Currency c = Currency.wrap(makeAddr("token"));
        vm.expectEmit(true, false, false, true, address(hook));
        emit IVolatilityFeeHook.CurrencyAllowlistUpdated(c, true);
        vm.prank(owner);
        hook.setCurrencyAllowed(c, true);
        assertTrue(hook.isCurrencyAllowed(c));

        vm.prank(owner);
        hook.setCurrencyAllowed(c, false);
        assertFalse(hook.isCurrencyAllowed(c));
    }

    function test_setCurrencyAllowed_revertsForNonOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, trader));
        vm.prank(trader);
        hook.setCurrencyAllowed(currency0, false);
    }

    function test_setLiquidityModule_ownerOnlyAndEmits() public {
        ILiquidityModule m1 = ILiquidityModule(address(new CountingModule()));
        ILiquidityModule m2 = ILiquidityModule(address(new CountingModule()));
        vm.expectEmit(true, true, false, false, address(hook));
        emit IVolatilityFeeHook.LiquidityModuleUpdated(ILiquidityModule(address(0)), m1);
        vm.prank(owner);
        hook.setLiquidityModule(m1);

        vm.expectEmit(true, true, false, false, address(hook));
        emit IVolatilityFeeHook.LiquidityModuleUpdated(m1, m2);
        vm.prank(owner);
        hook.setLiquidityModule(m2);
        assertEq(address(hook.liquidityModule()), address(m2));
    }

    function test_setLiquidityModule_revertsForNonOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, trader));
        vm.prank(trader);
        hook.setLiquidityModule(ILiquidityModule(address(1)));
    }

    function test_ownership_isTwoStep() public {
        address newOwner = makeAddr("newOwner");
        vm.prank(owner);
        hook.transferOwnership(newOwner);
        assertEq(hook.owner(), owner, "unchanged until accepted");
        assertEq(hook.pendingOwner(), newOwner);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, trader));
        vm.prank(trader);
        hook.acceptOwnership();

        vm.prank(newOwner);
        hook.acceptOwnership();
        assertEq(hook.owner(), newOwner);
    }

    // =========================================================================================== initialization

    function test_initialize_registersPoolState() public view {
        IVolatilityFeeHook.PoolState memory s = state();
        assertTrue(s.registered);
        assertEq(s.lowSqrtPriceX96, SQRT_PRICE_1_1);
        assertEq(s.highSqrtPriceX96, SQRT_PRICE_1_1);
        assertEq(s.anchorTick, 0);
        assertEq(s.anchorBlock, vm.getBlockNumber());
        assertEq(s.ewmaWad, 0);
        assertEq(s.lpFeePips, 500);
        assertEq(s.surchargePips, 0);
    }

    function test_initialize_emitsPoolRegistered() public {
        (Currency c0, Currency c1) = _allowedPair();
        PoolKey memory k = PoolKey(c0, c1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 10, IHooks(address(hook)));
        vm.expectEmit(true, false, false, true, address(hook));
        emit IVolatilityFeeHook.PoolRegistered(k.toId(), 6931, 500);
        manager.initialize(k, SQRT_PRICE_2_1);
    }

    function test_initialize_revertsForStaticFee() public {
        PoolKey memory k = PoolKey(currency0, currency1, 3000, 60, IHooks(address(hook)));
        vm.expectRevert(
            wrappedHookError(
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(IVolatilityFeeHook.DynamicFeeRequired.selector, uint24(3000))
            )
        );
        manager.initialize(k, SQRT_PRICE_1_1);
    }

    function test_initialize_revertsForNonAllowlistedCurrency0() public {
        (Currency c0, Currency c1) = _freshPair();
        vm.prank(owner);
        hook.setCurrencyAllowed(c1, true);
        PoolKey memory k = PoolKey(c0, c1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(address(hook)));
        vm.expectRevert(
            wrappedHookError(
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(IVolatilityFeeHook.CurrencyNotAllowed.selector, c0)
            )
        );
        manager.initialize(k, SQRT_PRICE_1_1);
    }

    function test_initialize_revertsForNonAllowlistedCurrency1() public {
        (Currency c0, Currency c1) = _freshPair();
        vm.prank(owner);
        hook.setCurrencyAllowed(c0, true);
        PoolKey memory k = PoolKey(c0, c1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(address(hook)));
        vm.expectRevert(
            wrappedHookError(
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(IVolatilityFeeHook.CurrencyNotAllowed.selector, c1)
            )
        );
        manager.initialize(k, SQRT_PRICE_1_1);
    }

    function test_initialize_delistingDoesNotAffectExistingPools() public {
        vm.startPrank(owner);
        hook.setCurrencyAllowed(currency0, false);
        hook.setCurrencyAllowed(currency1, false);
        vm.stopPrank();
        nextBlock();
        swapExactIn(poolKey, true, 1e18);
        addLiquidity(poolKey, -600, 600, 1e18, bytes32(uint256(7)));
        removeLiquidity(poolKey, -600, 600, 1e18, bytes32(uint256(7)));
    }

    function test_views_revertForUnknownPool() public {
        PoolKey memory unknown = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 1, IHooks(address(hook)));
        vm.expectRevert(abi.encodeWithSelector(IVolatilityFeeHook.PoolNotRegistered.selector, unknown.toId()));
        hook.quoteFees(unknown);
        vm.expectRevert(abi.encodeWithSelector(IVolatilityFeeHook.PoolNotRegistered.selector, unknown.toId()));
        hook.getPoolState(unknown.toId());
    }

    // =========================================================================================== dynamic fee

    function test_fee_initialBlockPaysFloor() public {
        SwapObservation memory o = observeSwap(poolKey, true, -1e18);
        assertEq(o.fee, 500, "5 bps floor before any volatility is observed");
        assertEq(o.surcharge0 + o.surcharge1, 0, "no surcharge at zero volatility");
    }

    function test_fee_firstSwapOfBlockFoldsPreviousBlockMove() public {
        swapExactIn(poolKey, true, 20e18); // moves the price down in the initialization block
        int24 closeTick = currentTick(poolId);
        uint160 closePrice = currentSqrtPrice(poolId);
        uint256 sample = uint256(int256(-closeTick));
        assertGt(sample, 0);

        nextBlock();
        uint256 expectedEwma = VolatilityMath.updateEwma(0, sample, 1, 0.1e18);
        uint24 expectedFee = VolatilityMath.lpFee(expectedEwma, 500);
        uint24 expectedSurcharge = VolatilityMath.surchargeRate(expectedEwma, 250, 5000);

        vm.expectEmit(true, false, false, true, address(hook));
        emit IVolatilityFeeHook.VolatilityUpdated(
            poolId, closeTick, sample, 1, expectedEwma, expectedFee, expectedSurcharge
        );
        SwapObservation memory o = observeSwap(poolKey, false, -1e18);
        assertEq(o.fee, expectedFee, "fee applied by the PoolManager");

        IVolatilityFeeHook.PoolState memory s = state();
        assertEq(s.ewmaWad, expectedEwma);
        assertEq(s.anchorTick, closeTick, "re-anchored at the block's opening tick");
        assertEq(s.anchorBlock, vm.getBlockNumber());
        assertEq(s.lpFeePips, expectedFee);
        assertEq(s.surchargePips, expectedSurcharge);
        assertEq(s.lowSqrtPriceX96, closePrice, "the block's range starts at its opening price");
        assertEq(s.highSqrtPriceX96, currentSqrtPrice(poolId), "and grows with the first swap");
    }

    function test_fee_constantWithinBlock() public {
        swapExactIn(poolKey, true, 20e18);
        nextBlock();
        uint24 first = observeSwap(poolKey, true, -5e18).fee;
        for (uint256 i; i < 5; ++i) {
            // Large swaps in both directions inside the block cannot move this block's fee.
            assertEq(observeSwap(poolKey, i % 2 == 0, -30e18).fee, first);
        }
    }

    function test_fee_idleBlocksDecayVolatility() public {
        swapExactIn(poolKey, true, 20e18);
        nextBlock();
        swapExactIn(poolKey, false, 1e18);
        uint256 ewmaAfterOne = state().ewmaWad;
        int24 anchor = state().anchorTick;
        int24 closeTick = currentTick(poolId);

        vm.roll(vm.getBlockNumber() + 50); // 49 idle blocks after the sampled one
        swapExactIn(poolKey, true, 1e18);
        uint256 expected =
            VolatilityMath.updateEwma(ewmaAfterOne, VolatilityMath.absTickDelta(closeTick, anchor), 50, 0.1e18);
        assertEq(state().ewmaWad, expected);
        assertLt(state().ewmaWad, ewmaAfterOne, "quiet period lowers volatility");
    }

    function test_fee_saturatesAtCap() public {
        // A 2000+ tick move in one block drives the EWMA far past the 100 bps clamp.
        swapExactIn(poolKey, true, 150e18);
        nextBlock();
        SwapObservation memory o = observeSwap(poolKey, false, -1e18);
        assertEq(o.fee, 10_000, "clamped at 100 bps");
        assertEq(state().surchargePips, 5000, "surcharge clamped at its cap");
    }

    function test_quoteFees_matchesNextSwap() public {
        (uint24 f0, uint24 s0, uint160 low0, uint160 high0) = hook.quoteFees(poolKey);
        assertEq(f0, 500);
        assertEq(s0, 0);
        assertEq(low0, SQRT_PRICE_1_1);
        assertEq(high0, SQRT_PRICE_1_1);

        swapExactIn(poolKey, true, 20e18);
        nextBlock();
        uint160 open = currentSqrtPrice(poolId);
        (uint24 fee, uint24 surcharge, uint160 low, uint160 high) = hook.quoteFees(poolKey); // pending update simulated
        assertEq(low, open, "a new block's range collapses to the current price");
        assertEq(high, open);
        SwapObservation memory o = observeSwap(poolKey, true, -1e18);
        assertEq(o.fee, fee);
        assertEq(state().surchargePips, surcharge);

        (uint24 fee2, uint24 surcharge2, uint160 low2, uint160 high2) = hook.quoteFees(poolKey); // same block: stored
        assertEq(fee2, fee);
        assertEq(surcharge2, surcharge);
        assertEq(low2, currentSqrtPrice(poolId), "the swap extended the range down");
        assertEq(high2, open);
    }

    // =========================================================================================== surcharge

    function test_surcharge_exactInput_reducesOutputAndIsDonated() public {
        _createVolatility();
        uint256 rate = _pendingSurchargeRate();
        assertGt(rate, 0);

        uint256 feeGrowthBefore = _feeGrowth1();
        SwapObservation memory o = observeSwap(poolKey, true, -10e18);
        // zeroForOne exact-in: unspecified = currency1 output
        uint256 expected = VolatilityMath.surchargeAmount(uint256(int256(o.poolAmount1)), rate);
        assertEq(o.surcharge1, expected, "surcharge = ceil(output * rate)");
        assertEq(o.surcharge0, 0);
        assertEq(o.donated1, expected, "donated in full to LPs");
        assertEq(o.traderDelta1, int256(o.poolAmount1) - int256(expected), "trader receives output minus surcharge");
        assertEq(o.traderDelta0, int256(o.poolAmount0), "input unchanged");
        assertGt(_feeGrowth1() - feeGrowthBefore, 0, "LP fee growth includes the donation");
        _assertHookHoldsNothing();
    }

    function test_surcharge_exactOutput_increasesInput() public {
        _createVolatility();
        uint256 rate = _pendingSurchargeRate();
        SwapObservation memory o = observeSwap(poolKey, true, 5e18); // exact output of currency1
        // zeroForOne exact-out: unspecified = currency0 input
        uint256 expected = VolatilityMath.surchargeAmount(uint256(-int256(o.poolAmount0)), rate);
        assertEq(o.surcharge0, expected);
        assertEq(o.donated0, expected);
        assertEq(o.traderDelta0, int256(o.poolAmount0) - int256(expected), "trader pays input plus surcharge");
        assertEq(o.traderDelta1, int256(o.poolAmount1), "exact output delivered");
        _assertHookHoldsNothing();
    }

    /// @notice ERC-6909 settlement: an exact-input swap paid by burning claims and taken as claims reconciles exactly
    /// like an ERC-20 swap (claim deltas = PoolManager swap delta minus the surcharge), and no ERC-20 moves.
    function test_surcharge_settledWithClaimsReconciles() public {
        _createVolatility();
        claimsRouter.deposit(currency0, address(this), 50e18);
        manager.setOperator(address(swapRouter), true);
        uint256 rate = _pendingSurchargeRate();

        SwapObservation memory o = observeSwapWithSettings(poolKey, true, -10e18, MIN_PRICE_LIMIT, true);
        uint256 expected = VolatilityMath.surchargeAmount(uint256(int256(o.poolAmount1)), rate);
        assertGt(expected, 0);
        assertEq(o.surcharge1, expected, "same surcharge as an ERC-20 swap");
        assertEq(o.donated1, expected);
        assertEq(o.claimDelta0, int256(o.poolAmount0), "input paid by burning claims");
        assertEq(o.claimDelta1, int256(o.poolAmount1) - int256(expected), "output minted as claims, net of surcharge");
        assertEq(o.traderDelta0, 0, "no ERC-20 moved");
        assertEq(o.traderDelta1, 0, "no ERC-20 moved");
        _assertHookHoldsNothing();
    }

    function test_surcharge_onlyForNewGround() public {
        _createVolatility();
        uint256 rate = _pendingSurchargeRate();
        uint160 open = currentSqrtPrice(poolId);
        SwapObservation memory first = observeSwap(poolKey, true, -10e18);
        assertEq(
            first.surcharge1,
            VolatilityMath.surchargeAmount(uint256(int256(first.poolAmount1)), rate),
            "the first swap of a block pays on its whole output"
        );
        uint160 low = currentSqrtPrice(poolId);
        assertEq(state().lowSqrtPriceX96, low);
        assertEq(state().highSqrtPriceX96, open);

        SwapObservation memory back = observeSwap(poolKey, false, -3e18);
        assertEq(back.surcharge0 + back.surcharge1, 0, "moving back inside the block's range is free");

        uint160 pre = currentSqrtPrice(poolId);
        SwapObservation memory further = observeSwap(poolKey, true, -8e18);
        uint160 post = currentSqrtPrice(poolId);
        uint256 output = uint256(int256(further.poolAmount1));
        assertGt(further.surcharge1, 0, "pushing below the block's low pays again");
        assertEq(
            further.surcharge1,
            VolatilityMath.proRatedSurcharge(output, rate, pre, post, low, true),
            "only the part below the previous low, pro rata"
        );
        assertLt(further.surcharge1, VolatilityMath.surchargeAmount(output, rate), "not the whole output");
        assertEq(state().lowSqrtPriceX96, post, "the range grows to the new low");
    }

    function test_surcharge_reenteringThePaidRangeIsFree() public {
        _createVolatility();
        observeSwap(poolKey, true, -10e18);
        uint160 low = currentSqrtPrice(poolId);
        observeSwap(poolKey, false, -6e18);
        SwapObservation memory again = observeSwap(poolKey, true, -1e30, low);
        assertEq(currentSqrtPrice(poolId), low, "back at the block's low");
        assertEq(again.surcharge0 + again.surcharge1, 0, "ground the block already paid for is not charged twice");
    }

    function test_surcharge_dustFirstSwapDoesNotShieldTheArbitrage() public {
        _createVolatility();
        SwapObservation memory dust = observeSwap(poolKey, true, -1e6);
        SwapObservation memory arb = observeSwap(poolKey, true, -25e18);
        assertGt(dust.surcharge1, 0);
        uint256 rate = state().surchargePips;
        assertEq(
            arb.surcharge1,
            VolatilityMath.surchargeAmount(uint256(int256(arb.poolAmount1)), rate),
            "the large follow-up swap starts on the range edge and pays the full surcharge"
        );
    }

    /// @notice Regression for the external review's crossing cliff. The block's first swap pushes the price up; a
    /// second swap then crosses back over the opening price. Before the fix the second swap paid all or nothing on its
    /// whole amount depending on whether it ended past the first swap's distance from the open (0 when ending 30 ticks
    /// below the open, 0.5% of the entire trade one tick further). Now it pays for the part below the open, the same
    /// as the trade split at the open, and the charge is continuous in the end price.
    function test_surcharge_crossingSwapPaysTheSameAsTheSplitTrade() public {
        _createVolatility();
        uint160 open = currentSqrtPrice(poolId);
        int24 openTick = TickMath.getTickAtSqrtPrice(open);
        swapExactIn(poolKey, false, 10e18); // first swap of the block: price up, range [open, high]
        int24 upTicks = currentTick(poolId) - openTick;
        assertGt(upTicks, 150);

        int24[3] memory below = [int24(30), upTicks + 1, upTicks - 1];
        uint256[3] memory single;
        for (uint256 i; i < 3; ++i) {
            uint160 target = TickMath.getSqrtPriceAtTick(openTick - below[i]);
            uint256 snapshot = vm.snapshotState();
            single[i] = observeSwap(poolKey, true, -1e30, target).surcharge1;
            vm.revertToState(snapshot);
            uint256 split = observeSwap(poolKey, true, -1e30, open).surcharge1;
            assertEq(split, 0, "the leg back to the open stays inside the range");
            split += observeSwap(poolKey, true, -1e30, target).surcharge1;
            vm.revertToState(snapshot);
            assertGt(single[i], 0, "the crossing swap pays for the ground below the open");
            assertApproxEqAbs(single[i], split, 1, "single swap == swap split at the open (1 wei rounding)");
        }
        // Ending 1 tick short of or 1 tick past the first swap's distance changes the charge by ~1%, not from 0 to all.
        assertGt(single[1], single[2]);
        assertLt(single[1] - single[2], single[1] / 50, "continuous in the end price");
    }

    /// @notice The unspecified amount is pro-rated in the coordinate in which its currency is linear: 1/sqrt(P) for
    /// currency0. Pro-rating a currency0 amount by sqrt-price distance would be off by the ratio of the prices.
    function test_surcharge_currency0IsProRatedInInverseSqrtPrice() public {
        _createVolatility();
        uint256 rate = _pendingSurchargeRate();
        uint160 open = currentSqrtPrice(poolId);
        swapExactIn(poolKey, true, 10e18); // first swap of the block: price down, range [low, open]
        uint160 pre = currentSqrtPrice(poolId);
        uint160 target = TickMath.getSqrtPriceAtTick(TickMath.getTickAtSqrtPrice(open) + 150);

        uint256 snapshot = vm.snapshotState();
        // oneForZero exact-in: the unspecified amount is the currency0 output.
        SwapObservation memory single = observeSwap(poolKey, false, -1e30, target);
        vm.revertToState(snapshot);
        uint256 split = observeSwap(poolKey, false, -1e30, open).surcharge0;
        split += observeSwap(poolKey, false, -1e30, target).surcharge0;

        uint256 output = uint256(int256(single.poolAmount0));
        assertEq(single.surcharge0, VolatilityMath.proRatedSurcharge(output, rate, pre, target, open, false));
        assertApproxEqAbs(single.surcharge0, split, 1, "matches the split trade");
        uint256 naive = VolatilityMath.proRatedSurcharge(output, rate, pre, target, open, true);
        assertGt(naive > split ? naive - split : split - naive, 1e9, "sqrt-price pro rata would be visibly off");
    }

    /// @notice Known limitation, measured: the pro rata assumes constant liquidity over the swap. When liquidity
    /// changes inside the swapped range, a single swap and the same swap split at the range edge are charged
    /// differently, by at most the ratio of the largest to the smallest in-range liquidity along the swap.
    function test_surcharge_steppedLiquidityDeviationIsBoundedByTheLiquidityRatio() public {
        (PoolKey memory k, PoolId id) =
            initPool(currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 30, SQRT_PRICE_1_1);
        addLiquidity(k, -6000, 6000, 100e18, 0);
        addLiquidity(k, -6000, -120, 200e18, 0); // liquidity triples below tick -120
        swapExactIn(k, false, 3e18);
        nextBlock();
        uint160 open = currentSqrtPrice(id);
        swapExactIn(k, false, 0.5e18); // first swap of the block: up
        uint160 target = TickMath.getSqrtPriceAtTick(-400);

        uint256 snapshot = vm.snapshotState();
        uint256 single = observeSwap(k, true, -1e30, target).surcharge1;
        vm.revertToState(snapshot);
        uint256 split = observeSwap(k, true, -1e30, open).surcharge1;
        split += observeSwap(k, true, -1e30, target).surcharge1;
        assertTrue(single != split, "the deviation is real");
        assertLe(single, split * 3, "within the liquidity ratio");
        assertLe(split, single * 3, "within the liquidity ratio");
    }

    /// @notice Known limitation, measured: the pro rata can be undercut on purpose where liquidity is thin on one side
    /// of the block's opening price and thick on the other. A detour through the thin side is cheap and turns it into
    /// range the block has already covered, so the arbitrage swap that follows pays for only a small share of its thick
    /// new ground. The trader keeps most of the surcharge, net of the detour's LP fees (threat model, limitation 5).
    function test_surcharge_knownLimitation_thinSideDetourUndercutsTheArbitrage() public {
        (PoolKey memory k, PoolId id) =
            initPool(currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 30, SQRT_PRICE_1_1);
        addLiquidity(k, -6000, 6000, 1e18, 0); // thin everywhere
        addLiquidity(k, 60, 6000, 1000e18, bytes32("thick")); // 1,000x thicker above tick 60
        swapWithLimit(k, false, -100e18, sqrtAt(60)); // the previous block closes on tick 60
        nextBlock();
        assertGt(_pendingSurchargeRateFor(k), 0);
        uint160 target = sqrtAt(260);

        uint256 snapshot = vm.snapshotState();
        (uint256 b0, uint256 b1) = balancesOf(address(this));
        uint256 direct = observeSwap(k, false, -1e30, target).surcharge0; // straight up from the opening price
        int256 directValue = _gainAt(target, b0, b1);
        vm.revertToState(snapshot);

        (b0, b1) = balancesOf(address(this));
        uint256 detour = observeSwap(k, true, -1e30, sqrtAt(-3000)).surcharge1; // down through the thin side
        detour += observeSwap(k, false, -1e30, target).surcharge0; // then the same arbitrage
        int256 detourValue = _gainAt(target, b0, b1);
        assertEq(currentSqrtPrice(id), target, "both paths end at the target");

        console2.log("surcharge, direct arbitrage / with the detour:", direct, detour);
        console2.log("trader's extra gain from the detour (token1 at the target price):");
        console2.logInt(detourValue - directValue);
        assertLt(detour * 10, direct, "the detour cuts the surcharge by more than 90%");
        assertGt(detourValue, directValue, "and pays off after the detour's LP fees");
        assertLt(uint256(detourValue - directValue), direct, "but saves at most the surcharge itself");
    }

    /// @dev This contract's balance change since (b0, b1), valued in token1 at the given sqrt price.
    function _gainAt(uint160 sqrtPriceX96, uint256 b0, uint256 b1) internal view returns (int256) {
        (uint256 a0, uint256 a1) = balancesOf(address(this));
        uint256 priceWad = FullMath.mulDiv(uint256(sqrtPriceX96) * sqrtPriceX96, 1e18, 1 << 192);
        return (int256(a1) - int256(b1)) + ((int256(a0) - int256(b0)) * int256(priceWad)) / 1e18;
    }

    function test_surcharge_skippedWhenSwapLeavesNoLiquidityInRange() public {
        // A narrow pool: a big swap exits the only position's range.
        (PoolKey memory k, PoolId id) =
            initPool(currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 10, SQRT_PRICE_1_1);
        addLiquidity(k, -100, 100, 100e18, 0);
        swapExactIn(k, true, 0.1e18); // ~20 ticks, still inside the position
        nextBlock();
        assertGt(_pendingSurchargeRateFor(k), 0);

        SwapObservation memory o = observeSwap(k, true, -1000e18, sqrtAt(-500));
        assertEq(manager.getLiquidity(id), 0, "no liquidity left in range");
        assertEq(o.surcharge0 + o.surcharge1, 0, "surcharge skipped instead of reverting the swap");
        assertEq(o.donated0 + o.donated1, 0);
        assertEq(hook.getPoolState(id).lowSqrtPriceX96, sqrtAt(-500), "the range still tracks the price");
    }

    function test_surcharge_zeroAmountSwapPaysNothing() public {
        _createVolatility();
        // Price limit one unit below the current price: the swap moves the price but outputs nothing.
        SwapObservation memory o = observeSwap(poolKey, true, -1e18, currentSqrtPrice(poolId) - 1);
        assertEq(o.poolAmount1, 0, "no output");
        assertEq(o.surcharge0 + o.surcharge1, 0);
    }

    function test_surcharge_nativeCurrencyPool() public {
        vm.prank(owner);
        hook.setCurrencyAllowed(CurrencyLibrary.ADDRESS_ZERO, true);
        (PoolKey memory k,) = initPool(
            CurrencyLibrary.ADDRESS_ZERO,
            currency1,
            IHooks(address(hook)),
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            60,
            SQRT_PRICE_1_1
        );
        vm.deal(address(this), 1000 ether);
        modifyLiquidityRouter.modifyLiquidity{value: 300 ether}(
            k, ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: 1000e18, salt: 0}), ZERO_BYTES
        );
        swapNativeInput(k, true, -20 ether, ZERO_BYTES, 20 ether);
        nextBlock();

        vm.recordLogs();
        // oneForZero exact-in: the surcharge is taken from the native-ETH output.
        swapNativeInput(k, false, -1e18, ZERO_BYTES, 0);
        SwapObservation memory o;
        o = _decodeSwapLogs(vm.getRecordedLogs(), o);
        assertGt(o.surcharge0, 0, "surcharge paid in ETH");
        assertEq(o.donated0, o.surcharge0);
        assertEq(address(hook).balance, 0, "hook holds no ETH");
    }

    // =========================================================================================== liquidity module

    /// @notice Liquidity operations only commit notifications to the queue; the module is never called from them.
    function test_module_liquidityChangesAreQueuedNotCalled() public {
        CountingModule counter = new CountingModule();
        vm.prank(owner);
        hook.setLiquidityModule(counter);

        vm.recordLogs();
        BalanceDelta addDelta = modifyLiquidityRouter.modifyLiquidity(
            poolKey, ModifyLiquidityParams(-600, 600, 5e18, bytes32(uint256(1))), ZERO_BYTES
        );
        removeLiquidity(poolKey, -600, 600, 2e18, bytes32(uint256(1)));
        Queued[] memory q = queuedIn(vm.getRecordedLogs(), address(hook));

        assertEq(counter.completedCalls(), 0, "the module did not run during the liquidity operations");
        assertEq(hook.notificationCount(), 2);
        assertEq(q.length, 2);
        assertEq(q[0].id, 0);
        assertEq(q[1].id, 1);
        assertEq(address(q[0].module), address(counter));
        assertEq(q[0].notification.sender, address(modifyLiquidityRouter));
        assertEq(PoolId.unwrap(q[0].notification.key.toId()), PoolId.unwrap(poolId));
        assertEq(q[0].notification.params.liquidityDelta, 5e18);
        assertEq(BalanceDelta.unwrap(q[0].notification.delta), BalanceDelta.unwrap(addDelta), "caller's delta");
        assertEq(q[1].notification.params.liquidityDelta, -2e18);
        assertEq(hook.pendingNotification(0), keccak256(abi.encode(counter, q[0].notification)), "commitment stored");
    }

    function test_module_deliveryRunsTheModuleExactlyOnce() public {
        CountingModule counter = new CountingModule();
        Queued[] memory q = _queueAddAndRemove(counter);

        vm.expectEmit(true, true, false, true, address(hook));
        emit IVolatilityFeeHook.LiquidityNotificationDelivered(0, counter, true);
        hook.deliverNotification(q[0].id, q[0].module, q[0].notification);
        assertTrue(deliver(q[1]));

        assertEq(counter.completedCalls(), 2);
        assertEq(counter.netLiquidity(), 3e18, "+5e18 then -2e18");
        assertEq(hook.pendingNotification(0), bytes32(0), "consumed");
        assertEq(hook.pendingNotification(1), bytes32(0), "consumed");

        vm.expectRevert(abi.encodeWithSelector(IVolatilityFeeHook.UnknownNotification.selector, 0));
        hook.deliverNotification(q[0].id, q[0].module, q[0].notification);
    }

    function test_module_telemetryRecordsDeliveredNotifications() public {
        LiquidityTelemetry telemetry = new LiquidityTelemetry(address(hook));
        Queued[] memory q = _queueAddAndRemove(telemetry);

        vm.expectEmit(true, true, false, true, address(telemetry));
        emit LiquidityTelemetry.LiquidityRecorded(poolId, address(modifyLiquidityRouter), 5e18, 5e18);
        assertTrue(deliver(q[0]));
        assertTrue(deliver(q[1]));

        (uint64 additions, uint64 removals, int128 net) = telemetry.telemetry(poolId);
        assertEq(additions, 1);
        assertEq(removals, 1);
        assertEq(net, 3e18);
    }

    function test_module_telemetryRejectsZeroHook() public {
        vm.expectRevert(LiquidityTelemetry.ZeroHook.selector);
        new LiquidityTelemetry(address(0));
    }

    function test_module_telemetryRejectsOtherCallers() public {
        LiquidityTelemetry telemetry = new LiquidityTelemetry(address(hook));
        vm.expectRevert(abi.encodeWithSelector(LiquidityTelemetry.NotHook.selector, address(this)));
        telemetry.onLiquidityModified(
            address(this), poolKey, LIQUIDITY_PARAMS, toBalanceDelta(0, 0), toBalanceDelta(0, 0)
        );
    }

    function test_deliver_failureIsReportedAndConsumed() public {
        RevertingModule bad = new RevertingModule();
        Queued[] memory q = _queueAddAndRemove(bad);

        vm.expectEmit(true, true, false, true, address(hook));
        emit IVolatilityFeeHook.LiquidityNotificationDelivered(1, bad, false);
        hook.deliverNotification(q[1].id, q[1].module, q[1].notification);
        assertEq(hook.pendingNotification(1), bytes32(0), "a failed delivery still consumes the notification");
        assertFalse(deliver(q[0]));
    }

    function test_deliver_revertsForTamperedOrUnknownNotifications() public {
        CountingModule counter = new CountingModule();
        Queued[] memory q = _queueAddAndRemove(counter);
        IVolatilityFeeHook.LiquidityNotification memory n = q[0].notification;
        bytes memory unknown0 = abi.encodeWithSelector(IVolatilityFeeHook.UnknownNotification.selector, 0);

        IVolatilityFeeHook.LiquidityNotification memory t = _copy(n);
        t.sender = trader;
        vm.expectRevert(unknown0);
        hook.deliverNotification(0, counter, t);

        t = _copy(n);
        t.params.liquidityDelta = 5e18 + 1;
        vm.expectRevert(unknown0);
        hook.deliverNotification(0, counter, t);

        t = _copy(n);
        t.delta = toBalanceDelta(1, 1);
        vm.expectRevert(unknown0);
        hook.deliverNotification(0, counter, t);

        t = _copy(n);
        t.feesAccrued = toBalanceDelta(0, 1);
        vm.expectRevert(unknown0);
        hook.deliverNotification(0, counter, t);

        t = _copy(n);
        t.key.tickSpacing = 1;
        vm.expectRevert(unknown0);
        hook.deliverNotification(0, counter, t);

        ILiquidityModule otherModule = new CountingModule();
        vm.expectRevert(unknown0);
        hook.deliverNotification(0, otherModule, n);

        vm.expectRevert(abi.encodeWithSelector(IVolatilityFeeHook.UnknownNotification.selector, 1));
        hook.deliverNotification(1, counter, n); // another id's commitment

        vm.expectRevert(abi.encodeWithSelector(IVolatilityFeeHook.UnknownNotification.selector, 99));
        hook.deliverNotification(99, counter, n); // never queued
        assertEq(counter.completedCalls(), 0);
    }

    /// @notice A module never runs while the PoolManager is unlocked: a router that tries to deliver from inside its
    /// own unlock callback is refused by the hook.
    function test_deliver_revertsWhileThePoolManagerIsUnlocked() public {
        CountingModule counter = new CountingModule();
        Queued[] memory q = _queueAddAndRemove(counter);
        UnlockedDeliveryRouter router = new UnlockedDeliveryRouter(manager, hook);
        vm.expectRevert(IVolatilityFeeHook.PoolManagerUnlocked.selector);
        router.deliverInsideUnlock(q[0].id, q[0].module, q[0].notification);
        assertTrue(deliver(q[0]), "the same notification is delivered normally outside the unlock");
    }

    /// @notice Notifications are addressed to the module that was active when the liquidity changed.
    function test_deliver_goesToTheModuleThatWasActiveWhenQueued() public {
        CountingModule first = new CountingModule();
        Queued[] memory q = _queueAddAndRemove(first);
        CountingModule second = new CountingModule();
        vm.prank(owner);
        hook.setLiquidityModule(second);

        vm.expectRevert(abi.encodeWithSelector(IVolatilityFeeHook.UnknownNotification.selector, 0));
        hook.deliverNotification(0, second, q[0].notification);
        assertTrue(deliver(q[0]));
        assertEq(first.completedCalls(), 1);
        assertEq(second.completedCalls(), 0);
    }

    function test_module_disabledByZeroAddress() public {
        CountingModule counter = new CountingModule();
        vm.prank(owner);
        hook.setLiquidityModule(counter);
        addLiquidity(poolKey, -600, 600, 1e18, 0);
        vm.prank(owner);
        hook.setLiquidityModule(ILiquidityModule(address(0)));

        vm.recordLogs();
        removeLiquidity(poolKey, -600, 600, 1e18, 0);
        assertEq(queuedIn(vm.getRecordedLogs(), address(hook)).length, 0, "nothing queued without a module");
        assertEq(hook.notificationCount(), 1);
    }

    /// @notice Whenever a delivery succeeds, the module was given its full gas budget; with too little gas the
    /// delivery reverts with InsufficientGasForModule (the notification stays pending) instead of starving the module.
    function test_deliver_neverStarvesTheModule() public {
        GasProbeModule probe = new GasProbeModule();
        Queued[] memory q = _queueAddAndRemove(probe);

        bool sawInsufficientGas;
        uint256 successes;
        for (uint256 g = 90_000; g <= 400_000; g += 5000) {
            uint256 snapshot = vm.snapshotState();
            try hook.deliverNotification{gas: g}(q[0].id, q[0].module, q[0].notification) {
                ++successes;
                assertGe(probe.lastEntryGas(), 99_000, "module received its full budget");
            } catch (bytes memory reason) {
                assertEq(bytes4(reason), IVolatilityFeeHook.InsufficientGasForModule.selector, "only the gas check");
                assertTrue(hook.pendingNotification(0) != bytes32(0), "still pending after a gas revert");
                sawInsufficientGas = true;
            }
            vm.revertToState(snapshot);
        }
        assertTrue(sawInsufficientGas, "low gas is rejected explicitly");
        assertGt(successes, 10, "enough gas always succeeds");
    }

    // =========================================================================================== access control

    function test_callbacks_revertWhenNotCalledByPoolManager() public {
        bytes4 notPM = ImmutableState.NotPoolManager.selector;
        BalanceDelta zero = toBalanceDelta(0, 0);
        SwapParams memory sp = SwapParams(true, -1, MIN_PRICE_LIMIT);

        vm.expectRevert(notPM);
        hook.beforeInitialize(address(this), poolKey, SQRT_PRICE_1_1);
        vm.expectRevert(notPM);
        hook.afterInitialize(address(this), poolKey, SQRT_PRICE_1_1, 0);
        vm.expectRevert(notPM);
        hook.beforeAddLiquidity(address(this), poolKey, LIQUIDITY_PARAMS, "");
        vm.expectRevert(notPM);
        hook.afterAddLiquidity(address(this), poolKey, LIQUIDITY_PARAMS, zero, zero, "");
        vm.expectRevert(notPM);
        hook.beforeRemoveLiquidity(address(this), poolKey, REMOVE_LIQUIDITY_PARAMS, "");
        vm.expectRevert(notPM);
        hook.afterRemoveLiquidity(address(this), poolKey, REMOVE_LIQUIDITY_PARAMS, zero, zero, "");
        vm.expectRevert(notPM);
        hook.beforeSwap(address(this), poolKey, sp, "");
        vm.expectRevert(notPM);
        hook.afterSwap(address(this), poolKey, sp, zero, "");
        vm.expectRevert(notPM);
        hook.beforeDonate(address(this), poolKey, 1, 1, "");
        vm.expectRevert(notPM);
        hook.afterDonate(address(this), poolKey, 1, 1, "");
    }

    function test_unimplementedCallbacks_revertEvenFromPoolManager() public {
        bytes4 notImpl = BaseHook.HookNotImplemented.selector;
        vm.startPrank(address(manager));
        vm.expectRevert(notImpl);
        hook.afterInitialize(address(this), poolKey, SQRT_PRICE_1_1, 0);
        vm.expectRevert(notImpl);
        hook.beforeAddLiquidity(address(this), poolKey, LIQUIDITY_PARAMS, "");
        vm.expectRevert(notImpl);
        hook.beforeRemoveLiquidity(address(this), poolKey, REMOVE_LIQUIDITY_PARAMS, "");
        vm.expectRevert(notImpl);
        hook.beforeDonate(address(this), poolKey, 1, 1, "");
        vm.expectRevert(notImpl);
        hook.afterDonate(address(this), poolKey, 1, 1, "");
        vm.stopPrank();
    }

    // =========================================================================================== helpers

    function _expectConstructorRevert(IVolatilityFeeHook.FeeConfig memory c, bytes memory err) internal {
        bytes memory args = abi.encode(manager, owner, c);
        (, bytes32 salt) = HookMiner.find(address(this), HOOK_FLAGS, type(VolatilityFeeHook).creationCode, args);
        vm.expectRevert(err);
        new VolatilityFeeHook{salt: salt}(manager, owner, c);
    }

    /// @dev Moves the price ~100+ ticks in the current block and rolls to the next one, so the next swap opens a block
    /// with a non-zero surcharge rate.
    function _createVolatility() internal {
        swapExactIn(poolKey, false, 30e18);
        nextBlock();
    }

    /// @dev Installs `module`, then adds 5e18 and removes 2e18 in (-600, 600); returns the two queued notifications.
    function _queueAddAndRemove(ILiquidityModule module) internal returns (Queued[] memory q) {
        vm.prank(owner);
        hook.setLiquidityModule(module);
        vm.recordLogs();
        addLiquidity(poolKey, -600, 600, 5e18, bytes32(uint256(1)));
        removeLiquidity(poolKey, -600, 600, 2e18, bytes32(uint256(1)));
        q = queuedIn(vm.getRecordedLogs(), address(hook));
        assertEq(q.length, 2);
    }

    function _copy(IVolatilityFeeHook.LiquidityNotification memory n)
        internal
        pure
        returns (IVolatilityFeeHook.LiquidityNotification memory)
    {
        return abi.decode(abi.encode(n), (IVolatilityFeeHook.LiquidityNotification));
    }

    function _pendingSurchargeRate() internal view returns (uint256 rate) {
        return _pendingSurchargeRateFor(poolKey);
    }

    function _pendingSurchargeRateFor(PoolKey memory k) internal view returns (uint256 rate) {
        (, uint24 s,,) = hook.quoteFees(k);
        rate = s;
    }

    function _feeGrowth1() internal view returns (uint256 g1) {
        (, g1) = manager.getFeeGrowthGlobals(poolId);
    }

    function _assertHookHoldsNothing() internal view {
        assertEq(currency0.balanceOf(address(hook)), 0);
        assertEq(currency1.balanceOf(address(hook)), 0);
        assertEq(manager.balanceOf(address(hook), currency0.toId()), 0);
        assertEq(manager.balanceOf(address(hook), currency1.toId()), 0);
    }

    function _freshPair() internal returns (Currency, Currency) {
        return deployAndMint2Currencies();
    }

    function _allowedPair() internal returns (Currency c0, Currency c1) {
        (c0, c1) = deployAndMint2Currencies();
        vm.startPrank(owner);
        hook.setCurrencyAllowed(c0, true);
        hook.setCurrencyAllowed(c1, true);
        vm.stopPrank();
    }
}

/// @dev Records how much gas it received on entry.
contract GasProbeModule is ILiquidityModule {
    uint256 public lastEntryGas;

    function onLiquidityModified(address, PoolKey calldata, ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta)
        external
    {
        lastEntryGas = gasleft();
    }
}
