// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {HookFixture} from "../utils/HookFixture.sol";
import {MultiActionRouter} from "../utils/Routers.sol";
import {PositionClaims} from "../utils/PositionClaims.sol";
import {VolatilityFeeHandler} from "./VolatilityFeeHandler.sol";
import {IVolatilityFeeHook} from "../../src/interfaces/IVolatilityFeeHook.sol";

/// @notice Stateful invariants over random sequences of swaps (ERC-20 and ERC-6909 settled), round trips, liquidity
/// changes (plain and multi-action unlocks), donations, claim redemptions, block production, (hostile) module swaps
/// and notification deliveries. Numbered as in the README's "Invariants" section.
contract VolatilityFeeInvariantsTest is HookFixture {
    using StateLibrary for IPoolManager;

    VolatilityFeeHandler internal handler;

    function setUp() public {
        setUpEnvironment();
        MultiActionRouter multiRouter = new MultiActionRouter(manager);
        handler = new VolatilityFeeHandler(
            VolatilityFeeHandler.Deps({
                manager: manager,
                hook: hook,
                key: poolKey,
                staticKey: staticKey,
                swapRouter: swapRouter,
                lpRouter: modifyLiquidityRouter,
                donateRouter: donateRouter,
                claimsRouter: claimsRouter,
                multiRouter: multiRouter,
                owner: owner
            })
        );
        handler.registerPosition(
            VolatilityFeeHandler.Position(
                address(this), address(modifyLiquidityRouter), RANGE_LOWER, RANGE_UPPER, bytes32(0), POOL_LIQUIDITY
            )
        );

        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = VolatilityFeeHandler.swap.selector;
        selectors[1] = VolatilityFeeHandler.swapWithClaims.selector;
        selectors[2] = VolatilityFeeHandler.roundTrip.selector;
        selectors[3] = VolatilityFeeHandler.addLiquidity.selector;
        selectors[4] = VolatilityFeeHandler.removeLiquidity.selector;
        selectors[5] = VolatilityFeeHandler.donate.selector;
        selectors[6] = VolatilityFeeHandler.redeemClaims.selector;
        selectors[7] = VolatilityFeeHandler.rollBlocks.selector;
        selectors[8] = VolatilityFeeHandler.setModule.selector;
        selectors[9] = VolatilityFeeHandler.deliverNotification.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @notice I-1: the hook never holds value: no ERC-20, no ETH, no ERC-6909 claims.
    function invariant_I1_hookHoldsNoValue() public view {
        assertEq(currency0.balanceOf(address(hook)), 0);
        assertEq(currency1.balanceOf(address(hook)), 0);
        assertEq(address(hook).balance, 0);
        assertEq(manager.balanceOf(address(hook), currency0.toId()), 0);
        assertEq(manager.balanceOf(address(hook), currency1.toId()), 0);
    }

    /// @notice I-2: every surcharge the hook took (HookFee) was donated to LPs (PoolManager Donate from the hook).
    function invariant_I2_surchargesFullyDonated() public view {
        assertEq(handler.ghostSurcharge0(), handler.ghostDonated0());
        assertEq(handler.ghostSurcharge1(), handler.ghostDonated1());
    }

    /// @notice I-3: no output without a matching charge: whether a swap settles in ERC-20 or in ERC-6909 claims, the
    /// trader's balance change equals the PoolManager's swap delta minus the surcharge (and the other settlement kind
    /// does not move), and a surcharge never exceeds the amount it is charged on.
    function invariant_I3_swapAccountingReconciles() public view {
        assertFalse(handler.ghostReconciliationFailed(), "balance change != pool delta - surcharge");
        assertFalse(handler.ghostSurchargeExceededOutput(), "surcharge larger than the unspecified amount");
    }

    /// @notice I-4: a same-transaction round trip never ends with more of either token.
    function invariant_I4_roundTripsNeverProfit() public view {
        assertFalse(handler.ghostRoundTripProfit());
    }

    /// @notice I-5: every applied LP fee lies in [5, 100] bps; stored fee and surcharge rate respect their bounds.
    function invariant_I5_feesWithinBounds() public view {
        assertFalse(handler.ghostFeeOutOfBounds());
        IVolatilityFeeHook.PoolState memory s = hook.getPoolState(poolId);
        assertGe(s.lpFeePips, hook.MIN_FEE_PIPS());
        assertLe(s.lpFeePips, hook.MAX_FEE_PIPS());
        assertLe(s.surchargePips, hook.maxSurchargePips());
    }

    /// @notice I-6: the oracle updates at most once per block, so every swap in a block pays the same LP fee (as
    /// applied by the PoolManager: the fee in its Swap event).
    function invariant_I6_feeConstantWithinBlock() public view {
        assertFalse(handler.ghostFeeChangedWithinBlock());
        assertFalse(handler.ghostOracleUpdatedTwiceInBlock());
        assertLe(hook.getPoolState(poolId).anchorBlock, block.number);
    }

    /// @notice I-7: the EWMA never exceeds the largest per-block tick move it has observed.
    function invariant_I7_ewmaBoundedByLargestSample() public view {
        assertLe(hook.getPoolState(poolId).ewmaWad, handler.ghostMaxSample() * 1e18);
    }

    /// @notice I-8 (solvency, after every call): the PoolManager's ERC-20 balance of each currency covers everything it
    /// owes, computed from its state without withdrawing anything: every open position's principal at the current
    /// price plus its uncollected fees, and every ERC-6909 claim. Claim redemptions always pay one for one.
    function invariant_I8_poolManagerSolvent() public view {
        (uint256 owed0, uint256 owed1) = handler.outstandingClaims(address(modifyLiquidityRouter));
        assertGe(currency0.balanceOf(address(manager)), owed0, "solvent in currency0");
        assertGe(currency1.balanceOf(address(manager)), owed1, "solvent in currency1");
        assertFalse(handler.ghostRedemptionShort(), "a claim redemption paid less than it burned");
    }

    /// @notice I-9: in a surcharged block the pool price never leaves the block's range [low, high]; no swap pays more
    /// than the full rate on its unspecified amount; and the swap that opens such a block (it starts on the range
    /// edge) is always charged when it moves an amount and leaves liquidity in range.
    function invariant_I9_blockPriceRange() public view {
        assertFalse(handler.ghostPriceOutsideBlockRange(), "price outside [low, high]");
        assertFalse(handler.ghostSurchargeAboveRate(), "surcharge above the full rate");
        assertFalse(handler.ghostBlockOpeningNotCharged(), "a surcharged block's opening swap paid nothing");
    }

    /// @notice I-10: every liquidity change made while a module is set is queued exactly once, and a notification can
    /// never be delivered twice. (Deliveries themselves never revert: fail_on_revert.)
    function invariant_I10_notificationsQueuedAndDeliveredOnce() public view {
        assertEq(hook.notificationCount(), handler.ghostQueued(), "every queued notification was observed");
        assertFalse(handler.ghostRedeliveryAccepted(), "a notification was delivered twice");
    }

    /// @notice I-8 (exit, at the end of every run): every LP exits completely and receives exactly the claim computed
    /// from PoolManager state beforehand; every ERC-6909 holder redeems in full; the static pool's LP, whose pool the
    /// multi-action exits traded in, is paid its computed claim too; and every notification still pending can be
    /// delivered. The hook ends holding nothing.
    function afterInvariant() external {
        assertGt(handler.ghostSwaps(), 0, "the run made swaps (I-2 to I-6 and I-9 are about swaps)");

        uint256 n = handler.positionCount();
        for (uint256 i; i < n; ++i) {
            VolatilityFeeHandler.Position memory p = handler.positionAt(i);
            (uint256 c0, uint256 c1) = PositionClaims.claimOf(manager, poolId, p.router, p.lower, p.upper, p.salt);
            (uint256 b0, uint256 b1) = balancesOf(p.lp);
            handler.exitPosition(p);
            (uint256 a0, uint256 a1) = balancesOf(p.lp);
            assertEq(a0 - b0, c0, "exit paid the computed currency0 claim");
            assertEq(a1 - b1, c1, "exit paid the computed currency1 claim");
        }
        assertEq(manager.getLiquidity(poolId), 0, "all liquidity withdrawn");

        for (uint256 i; i < handler.actorCount(); ++i) {
            _redeemAll(handler.actorAt(i), currency0);
            _redeemAll(handler.actorAt(i), currency1);
        }

        (uint256 s0, uint256 s1) = PositionClaims.claimOf(
            manager, staticId, address(modifyLiquidityRouter), RANGE_LOWER, RANGE_UPPER, bytes32(0)
        );
        (uint256 sb0, uint256 sb1) = balancesOf(address(this));
        removeLiquidity(staticKey, RANGE_LOWER, RANGE_UPPER, POOL_LIQUIDITY, 0);
        (uint256 sa0, uint256 sa1) = balancesOf(address(this));
        assertEq(sa0 - sb0, s0, "static LP paid its computed currency0 claim");
        assertEq(sa1 - sb1, s1, "static LP paid its computed currency1 claim");

        handler.deliverAll();
        invariant_I1_hookHoldsNoValue();
    }

    /// @notice Non-vacuity of the campaign's building blocks: a scripted sequence of handler actions reaches every
    /// path the invariants talk about (ERC-20 and claim-settled swaps, surcharged swaps and charged block openings,
    /// round trips, plain and multi-action exits, donations, redemptions, successful and failed deliveries) without
    /// tripping any invariant.
    function test_handlerReachesEveryPath() public {
        handler.setModule(1); // telemetry
        handler.swap(0, false, true, 30e18);
        handler.rollBlocks(1);
        handler.swap(1, true, true, 5e18); // opens a surcharged block
        handler.swapWithClaims(2, true, true, 3e18); // extends the block's low, settled in claims
        handler.swapWithClaims(3, false, false, 1e18); // exact output, back inside the range
        handler.roundTrip(3, false, 2e18);
        handler.addLiquidity(0, 0, 10, 5e18, false);
        handler.addLiquidity(1, -5, 10, 5e18, true);
        handler.setModule(2); // reverting
        handler.removeLiquidity(2, 100, true); // the multi-action position, with a static-pool swap in the unlock
        handler.removeLiquidity(1, 50, false);
        handler.donate(0, 1e17, 1e17);
        handler.redeemClaims(2, false, 50);
        for (uint256 i; i < 4; ++i) {
            handler.deliverNotification(i);
        }

        assertGe(handler.ghostSwaps(), 5);
        assertGt(handler.ghostClaimSwaps(), 0, "claim-settled swaps");
        assertGt(handler.ghostSurchargedSwaps(), 0, "surcharged swaps");
        assertGt(handler.ghostChargedBlockOpenings(), 0, "charged block openings");
        assertGt(handler.ghostRoundTrips(), 0, "round trips");
        assertGe(handler.ghostExits(), 2, "exits");
        assertGt(handler.ghostMultiActionExits(), 0, "multi-action exits");
        assertGt(handler.ghostDonations(), 0, "donations");
        assertGt(handler.ghostRedemptions(), 0, "redemptions");
        assertGt(handler.ghostDeliveries(), 0, "successful deliveries");
        assertGt(handler.ghostFailedDeliveries(), 0, "failed deliveries");
        assertGt(handler.ghostSurcharge1(), 0, "I-2 compared non-zero amounts");

        invariant_I1_hookHoldsNoValue();
        invariant_I2_surchargesFullyDonated();
        invariant_I3_swapAccountingReconciles();
        invariant_I4_roundTripsNeverProfit();
        invariant_I5_feesWithinBounds();
        invariant_I6_feeConstantWithinBlock();
        invariant_I7_ewmaBoundedByLargestSample();
        invariant_I8_poolManagerSolvent();
        invariant_I9_blockPriceRange();
        invariant_I10_notificationsQueuedAndDeliveredOnce();
    }

    function _redeemAll(address actor, Currency c) internal {
        uint256 amount = manager.balanceOf(actor, c.toId());
        if (amount == 0) return;
        uint256 before = c.balanceOf(actor);
        vm.prank(actor);
        claimsRouter.withdraw(c, actor, amount);
        assertEq(c.balanceOf(actor) - before, amount, "claims redeem one for one");
        assertEq(manager.balanceOf(actor, c.toId()), 0);
    }
}
