// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {VolatilityMath} from "../../src/libraries/VolatilityMath.sol";

/// @notice Unit and bounded-fuzz tests of the pure fee math. Differential checks against exact reference values live
/// in VolatilityMathDifferential.t.sol.
contract VolatilityMathTest is Test {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant MAX_SAMPLE = 1_774_544; // |MAX_TICK - MIN_TICK|
    uint256 internal constant MAX_EWMA = MAX_SAMPLE * WAD;

    // ------------------------------------------------------------------ absTickDelta

    function test_absTickDelta_symmetricAndExtremes() public pure {
        assertEq(VolatilityMath.absTickDelta(5, -3), 8);
        assertEq(VolatilityMath.absTickDelta(-3, 5), 8);
        assertEq(VolatilityMath.absTickDelta(0, 0), 0);
        assertEq(VolatilityMath.absTickDelta(887_272, -887_272), MAX_SAMPLE);
        assertEq(VolatilityMath.absTickDelta(type(int24).min, type(int24).max), 2 ** 24 - 1);
    }

    function testFuzz_absTickDelta_matchesSignedDifference(int24 a, int24 b) public pure {
        int256 d = int256(a) - int256(b);
        assertEq(VolatilityMath.absTickDelta(a, b), d >= 0 ? uint256(d) : uint256(-d));
        assertEq(VolatilityMath.absTickDelta(a, b), VolatilityMath.absTickDelta(b, a));
    }

    // ------------------------------------------------------------------ decayFactor

    function test_decayFactor_edgeCases() public pure {
        assertEq(VolatilityMath.decayFactor(0.1e18, 0), WAD, "x^0 = 1");
        assertEq(VolatilityMath.decayFactor(0.1e18, 1), 0.9e18, "one step");
        assertEq(VolatilityMath.decayFactor(0.1e18, 2), 0.81e18, "two steps");
        assertEq(VolatilityMath.decayFactor(WAD, 1), 0, "alpha = 1 forgets everything");
        assertEq(VolatilityMath.decayFactor(WAD, 0), WAD, "alpha = 1, k = 0");
        assertEq(VolatilityMath.decayFactor(1, 1), WAD - 1, "smallest alpha");
        assertEq(VolatilityMath.decayFactor(0.5e18, 200), 0, "underflows to exactly zero");
    }

    function test_decayFactor_hugeExponentTerminates() public view {
        uint256 gasBefore = gasleft();
        uint256 result = VolatilityMath.decayFactor(1, type(uint40).max);
        uint256 used = gasBefore - gasleft();
        // (1 - 1e-18)^(2^40) ~ 0.9999989: still close to one, computed in 40 squarings.
        assertApproxEqRel(result, 0.9999989e18, 1e12);
        assertLt(used, 20_000, "bounded loop");
    }

    function testFuzz_decayFactor_boundedAndMonotone(uint256 alphaWad, uint256 k) public pure {
        alphaWad = bound(alphaWad, 1, WAD);
        k = bound(k, 0, type(uint40).max - 1);
        uint256 d0 = VolatilityMath.decayFactor(alphaWad, k);
        uint256 d1 = VolatilityMath.decayFactor(alphaWad, k + 1);
        assertLe(d0, WAD);
        assertLe(d1, d0, "longer idle periods never decay less");
    }

    function testFuzz_decayFactor_monotoneInAlpha(uint256 a, uint256 b, uint256 k) public pure {
        a = bound(a, 1, WAD);
        b = bound(b, a, WAD);
        k = bound(k, 0, 100_000);
        assertLe(VolatilityMath.decayFactor(b, k), VolatilityMath.decayFactor(a, k), "larger alpha forgets faster");
    }

    // ------------------------------------------------------------------ updateEwma

    function test_updateEwma_singleBlockIsExactConvexCombination() public pure {
        // 0.9 * 10 ticks + 0.1 * 30 ticks = 12 ticks
        assertEq(VolatilityMath.updateEwma(10 * WAD, 30, 1, 0.1e18), 12 * WAD);
        // alpha = 1: the EWMA is just the last sample.
        assertEq(VolatilityMath.updateEwma(10 * WAD, 30, 1, WAD), 30 * WAD);
        // Zero stays zero with a zero sample, regardless of the gap.
        assertEq(VolatilityMath.updateEwma(0, 0, 1_000_000, 0.1e18), 0);
    }

    function test_updateEwma_idleBlocksDecay() public pure {
        // Sample of 30 ticks in the anchored block, then 2 idle blocks: (0.9*10 + 0.1*30) * 0.81 = 9.72 ticks.
        assertEq(VolatilityMath.updateEwma(10 * WAD, 30, 3, 0.1e18), 9.72e18);
    }

    function testFuzz_updateEwma_neverExceedsLargestInput(uint256 ewma, uint256 sample, uint256 blocks, uint256 alpha)
        public
        pure
    {
        ewma = bound(ewma, 0, MAX_EWMA);
        sample = bound(sample, 0, MAX_SAMPLE);
        blocks = bound(blocks, 1, type(uint40).max);
        alpha = bound(alpha, 1, WAD);
        uint256 next = VolatilityMath.updateEwma(ewma, sample, blocks, alpha);
        uint256 cap = ewma > sample * WAD ? ewma : sample * WAD;
        assertLe(next, cap, "convex combination bound");
        assertLe(next, type(uint128).max, "fits the packed storage slot");
    }

    function testFuzz_updateEwma_monotoneInInputs(
        uint256 ewma,
        uint256 extraEwma,
        uint256 sample,
        uint256 extraSample,
        uint256 blocks,
        uint256 alpha
    ) public pure {
        ewma = bound(ewma, 0, MAX_EWMA / 2);
        extraEwma = bound(extraEwma, 0, MAX_EWMA / 2);
        sample = bound(sample, 0, MAX_SAMPLE / 2);
        extraSample = bound(extraSample, 0, MAX_SAMPLE / 2);
        blocks = bound(blocks, 1, 10_000);
        alpha = bound(alpha, 1, WAD);
        uint256 base = VolatilityMath.updateEwma(ewma, sample, blocks, alpha);
        assertGe(VolatilityMath.updateEwma(ewma + extraEwma, sample, blocks, alpha), base, "monotone in ewma");
        assertGe(VolatilityMath.updateEwma(ewma, sample + extraSample, blocks, alpha), base, "monotone in sample");
        assertLe(VolatilityMath.updateEwma(ewma, sample, blocks + 1, alpha), base, "monotone in idle blocks");
    }

    function testFuzz_updateEwma_constantSampleConvergesFromBelow(uint256 sample, uint256 alpha) public pure {
        sample = bound(sample, 0, MAX_SAMPLE);
        alpha = bound(alpha, 0.05e18, WAD);
        uint256 ewma;
        for (uint256 i; i < 200; ++i) {
            ewma = VolatilityMath.updateEwma(ewma, sample, 1, alpha);
            assertLe(ewma, sample * WAD, "never overshoots a constant sample");
        }
        // After 200 steps with alpha >= 5% the remaining gap is below 0.95^200 ~ 3.5e-5 of the sample.
        assertApproxEqRel(ewma, sample * WAD, 1e14);
    }

    /// @notice Rounding direction matters across repeated operations: with round-down the EWMA of a quiet pool
    /// reaches exactly zero; a round-up implementation gets stuck as soon as alpha * e < 1 wei (here at 5 wei, since
    /// ceil(0.9 * 5) = 5) and would keep the fee rounded up forever.
    function test_updateEwma_roundDownReachesZero_roundUpWouldStick() public pure {
        uint256 ours = 5;
        uint256 roundUp = 5;
        for (uint256 i; i < 64; ++i) {
            ours = VolatilityMath.updateEwma(ours, 0, 1, 0.1e18);
            roundUp = ((WAD - 0.1e18) * roundUp + WAD - 1) / WAD; // ceil variant
        }
        assertEq(ours, 0, "round-down decays to zero");
        assertEq(roundUp, 5, "round-up never decays");
        assertEq(VolatilityMath.lpFee(ours, 500), 500, "quiet pool returns to the 5 bps floor");
        assertEq(VolatilityMath.lpFee(roundUp, 500), 501, "sticky EWMA would keep the fee above the floor");
    }

    // ------------------------------------------------------------------ lpFee

    function test_lpFee_clampAndCeil() public pure {
        assertEq(VolatilityMath.lpFee(0, 500), 500, "floor at 5 bps");
        assertEq(VolatilityMath.lpFee(1, 500), 501, "one wei of volatility rounds the fee up");
        assertEq(VolatilityMath.lpFee(WAD, 500), 1000, "1 tick * 5 bps");
        assertEq(VolatilityMath.lpFee(19 * WAD, 500), 10_000, "reaches the cap exactly");
        assertEq(VolatilityMath.lpFee(19 * WAD + 1, 500), 10_000, "clamped");
        assertEq(VolatilityMath.lpFee(MAX_EWMA, 10_000), 10_000, "extreme inputs clamp without overflow");
        assertEq(VolatilityMath.lpFee(MAX_EWMA, 0), 500, "zero slope");
    }

    function testFuzz_lpFee_withinBoundsAndMonotone(uint256 ewma, uint256 extra, uint256 slope) public pure {
        ewma = bound(ewma, 0, MAX_EWMA);
        extra = bound(extra, 0, MAX_EWMA);
        slope = bound(slope, 0, 10_000);
        uint24 fee = VolatilityMath.lpFee(ewma, slope);
        assertGe(fee, VolatilityMath.MIN_FEE_PIPS);
        assertLe(fee, VolatilityMath.MAX_FEE_PIPS);
        assertGe(VolatilityMath.lpFee(ewma + extra, slope), fee, "more volatility never lowers the fee");
    }

    // ------------------------------------------------------------------ surcharge

    function testFuzz_surchargeRate_cappedAndMonotone(uint256 ewma, uint256 extra, uint256 slope, uint256 cap)
        public
        pure
    {
        ewma = bound(ewma, 0, MAX_EWMA);
        extra = bound(extra, 0, MAX_EWMA);
        slope = bound(slope, 0, 10_000);
        cap = bound(cap, 0, 10_000);
        uint24 rate = VolatilityMath.surchargeRate(ewma, slope, cap);
        assertLe(rate, cap);
        assertGe(VolatilityMath.surchargeRate(ewma + extra, slope, cap), rate);
    }

    function testFuzz_surchargeAmount_neverExceedsAmount(uint256 amount, uint256 rate) public pure {
        amount = bound(amount, 0, 2 ** 127);
        rate = bound(rate, 0, 1e6);
        uint256 s = VolatilityMath.surchargeAmount(amount, rate);
        assertLe(s, amount);
        // ceil: never below the exact value
        assertGe(s * 1e6, amount * rate);
    }

    /// @notice Splitting a trade never lowers the total surcharge: ceil is subadditive, so the pieces pay at least as
    /// much as the whole.
    function testFuzz_surchargeAmount_splittingNeverPaysLess(uint256 a, uint256 b, uint256 rate) public pure {
        a = bound(a, 0, 2 ** 126);
        b = bound(b, 0, 2 ** 126);
        rate = bound(rate, 0, 10_000);
        assertGe(
            VolatilityMath.surchargeAmount(a, rate) + VolatilityMath.surchargeAmount(b, rate),
            VolatilityMath.surchargeAmount(a + b, rate)
        );
    }

    function test_surchargeAmount_examples() public pure {
        assertEq(VolatilityMath.surchargeAmount(0, 5000), 0);
        assertEq(VolatilityMath.surchargeAmount(1, 1), 1, "dust rounds up to one unit");
        assertEq(VolatilityMath.surchargeAmount(1e18, 2925), 2.925e15);
        assertEq(VolatilityMath.surchargeAmount(2 ** 127, 1e6), 2 ** 127);
    }

    // ------------------------------------------------------------------ proRatedSurcharge

    uint256 internal constant Q96 = 2 ** 96;

    function test_proRatedSurcharge_startingOnTheEdgePaysOnTheWholeAmount() public pure {
        for (uint256 i; i < 2; ++i) {
            bool inCurrency1 = i == 0;
            assertEq(VolatilityMath.proRatedSurcharge(1e18, 2925, 3e28, 1e28, 3e28, inCurrency1), 2.925e15, "down");
            assertEq(VolatilityMath.proRatedSurcharge(1e18, 2925, 1e28, 3e28, 1e28, inCurrency1), 2.925e15, "up");
            assertEq(VolatilityMath.proRatedSurcharge(7, 1, 1e28, 3e28, 1e28, inCurrency1), 1, "rounds up");
        }
    }

    /// @notice Half of the move (in sqrt price) is new ground. currency1 is linear in sqrt(P), so it pays half;
    /// currency0 is linear in 1/sqrt(P), which turns the share into b*pre/(T*edge).
    function test_proRatedSurcharge_examples() public pure {
        // Price down from 3e28 to 1e28, range edge at 2e28.
        assertEq(VolatilityMath.proRatedSurcharge(1e18, 1e4, 3e28, 1e28, 2e28, true), 5e15, "1/2");
        assertEq(VolatilityMath.proRatedSurcharge(1e18, 1e4, 3e28, 1e28, 2e28, false), 7.5e15, "1/2 * 3/2");
        // Price up from 1e28 to 3e28, range edge at 2e28.
        assertEq(VolatilityMath.proRatedSurcharge(1e18, 1e4, 1e28, 3e28, 2e28, true), 5e15, "1/2");
        assertEq(VolatilityMath.proRatedSurcharge(1e18, 1e4, 1e28, 3e28, 2e28, false), 2.5e15, "1/2 * 1/2");
        // One unit of sqrt price out of 1e20 is new ground: the charge rounds up to one unit.
        assertEq(VolatilityMath.proRatedSurcharge(1e18, 250, Q96, Q96 - 1e20, Q96 - 1e20 + 1, true), 1);
        assertEq(VolatilityMath.proRatedSurcharge(0, 250, Q96, Q96 - 1e20, Q96 - 1, true), 0, "nothing to charge");
    }

    /// @notice Rounding the currency0 share up twice can overshoot the surcharge on the whole swap by one unit; the
    /// result is capped at it.
    function test_proRatedSurcharge_cappedAtTheWholeSwapCharge() public pure {
        uint256 pre = Q96 + 2e6;
        uint256 post = Q96;
        uint256 edge = Q96 + 1_999_999;
        uint256 share = Math.mulDiv(100 * 1e4, edge - post, pre - post, Math.Rounding.Ceil);
        share = Math.mulDiv(share, pre, edge, Math.Rounding.Ceil);
        assertEq(Math.ceilDiv(share, 1e6), 2, "uncapped value");
        assertEq(VolatilityMath.surchargeAmount(100, 1e4), 1, "charge on the whole swap");
        assertEq(VolatilityMath.proRatedSurcharge(100, 1e4, pre, post, edge, false), 1, "capped");
    }

    /// @notice Never above the charge on the whole swap, never below the exact real value (checked here against its
    /// floor; the differential vectors check the ceiling exactly).
    function testFuzz_proRatedSurcharge_bounded(
        uint256 amount,
        uint256 rate,
        uint256 a,
        uint256 b,
        uint256 c,
        bool down,
        bool inCurrency1
    ) public pure {
        amount = bound(amount, 0, 2 ** 127);
        rate = bound(rate, 0, 1e6);
        // post < edge < pre (down) or pre < edge < post (up), all within the v4 sqrt-price range.
        uint256 lo = bound(a, 4_295_128_739, 2 ** 159);
        uint256 hi = bound(b, lo + 2, 2 ** 160 - 1);
        uint256 mid = bound(c, lo + 1, hi - 1);
        (uint256 pre, uint256 post) = down ? (hi, lo) : (lo, hi);
        uint256 got = VolatilityMath.proRatedSurcharge(amount, rate, pre, post, mid, inCurrency1);
        assertLe(got, VolatilityMath.surchargeAmount(amount, rate), "never above the whole-swap charge");
        uint256 share = Math.mulDiv(amount * rate, mid > post ? mid - post : post - mid, hi - lo);
        if (!inCurrency1) share = Math.mulDiv(share, pre, mid);
        assertGe(got, share / 1e6, "never below the exact value");
    }

    /// @notice At constant liquidity L, amount1 = L * d sqrt(P). Splitting a swap at any intermediate price then gives
    /// the same total charge as the whole swap, up to one unit of rounding for the extra leg.
    function testFuzz_proRatedSurcharge_splittingIsAdditiveAtConstantLiquidity(
        uint256 liquidity,
        uint256 rate,
        uint256 a,
        uint256 b,
        uint256 c,
        uint256 d
    ) public pure {
        liquidity = bound(liquidity, 1, 2 ** 40);
        rate = bound(rate, 1, 10_000);
        uint256 post = bound(a, Q96 / 2, Q96);
        uint256 pre = bound(b, post + 3, post + 2 ** 80);
        uint256 edge = bound(c, post + 1, pre); // the range edge the swap has to cross (down move)
        uint256 split = bound(d, post + 1, pre - 1);

        uint256 single = VolatilityMath.proRatedSurcharge(liquidity * (pre - post), rate, pre, post, edge, true);
        uint256 legs;
        if (split >= edge) {
            // The first leg stays inside the range (free); the second starts inside and crosses the edge.
            legs = VolatilityMath.proRatedSurcharge(liquidity * (split - post), rate, split, post, edge, true);
        } else {
            // The first leg crosses the edge; the second starts on the extended edge and pays in full.
            legs = VolatilityMath.proRatedSurcharge(liquidity * (pre - split), rate, pre, split, edge, true)
                + VolatilityMath.surchargeAmount(liquidity * (split - post), rate);
        }
        assertGe(legs, single, "splitting never lowers the charge");
        assertLe(legs, single + 1, "and raises it by at most one unit of rounding");
    }
}
