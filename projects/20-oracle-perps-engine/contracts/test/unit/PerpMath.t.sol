// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";

import {PerpMath} from "../../src/libraries/PerpMath.sol";

/// @dev External wrapper so library reverts can be asserted with `expectRevert`.
contract PerpMathHarness {
    function tokensForSize(uint256 sizeUsd, uint256 price, bool isLong) external pure returns (uint256) {
        return PerpMath.tokensForSize(sizeUsd, price, isLong);
    }

    function pnl(bool isLong, uint256 sizeUsd, uint256 tokens, uint256 price) external pure returns (int256) {
        return PerpMath.pnl(isLong, sizeUsd, tokens, price);
    }

    function impact(uint256 l, uint256 s, bool isLong, bool inc, uint256 size, uint256 pos, uint256 neg)
        external
        pure
        returns (int256)
    {
        return PerpMath.priceImpactUsd(l, s, isLong, inc, size, pos, neg);
    }

    function fundingIntegral(int256 r0, int256 v, uint256 dt, uint256 maxRate) external pure returns (int256, int256) {
        return PerpMath.fundingIntegral(r0, v, dt, maxRate);
    }
}

contract PerpMathTest is Test {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant POS = 2.5e8;
    uint256 internal constant NEG = 5e8;

    PerpMathHarness internal h = new PerpMathHarness();

    // ---------------------------------------------------------------------------------------------------------------
    // PnL and rounding
    // ---------------------------------------------------------------------------------------------------------------

    function test_pnl_longAndShort() public pure {
        // 1 ETH bought for $3000.
        assertEq(PerpMath.pnl(true, 3000e18, 1e18, 3300e18), 300e18);
        assertEq(PerpMath.pnl(true, 3000e18, 1e18, 2700e18), -300e18);
        assertEq(PerpMath.pnl(false, 3000e18, 1e18, 2700e18), 300e18);
        assertEq(PerpMath.pnl(false, 3000e18, 1e18, 3300e18), -300e18);
    }

    function test_tokensForSize_roundsAgainstTrader() public pure {
        // $1000 at $3000 = 0.333.. tokens: longs floor, shorts ceil.
        assertEq(PerpMath.tokensForSize(1000e18, 3000e18, true), 333_333_333_333_333_333);
        assertEq(PerpMath.tokensForSize(1000e18, 3000e18, false), 333_333_333_333_333_334);
    }

    function test_revert_tokensForSize_zeroPrice() public {
        vm.expectRevert();
        h.tokensForSize(1e18, 0, true);
    }

    /// @dev Opening and marking at the same price never shows a profit, for either side.
    function testFuzz_pnl_sameOpenAndMarkPriceIsNeverPositive(uint256 size, uint256 price, bool isLong) public pure {
        size = bound(size, 1, 1e33);
        price = bound(price, 1e6, 1e36);
        uint256 tokens = PerpMath.tokensForSize(size, price, isLong);
        assertLe(PerpMath.pnl(isLong, size, tokens, price), 0);
    }

    function testFuzz_mulDivFloor_roundsTowardNegativeInfinity(int256 x, uint256 y, uint256 d) public pure {
        x = bound(x, -1e36, 1e36);
        y = bound(y, 0, 1e36);
        d = bound(d, 1, 1e36);
        int256 r = PerpMath.mulDivFloor(x, y, d);
        // r <= x*y/d < r + 1, checked in exact integer arithmetic (|x*y| <= 1e72 fits in int256).
        int256 num = x * int256(y);
        assertLe(r * int256(d), num);
        assertGt((r + 1) * int256(d), num);
    }

    function testFuzz_mulWadOwed_roundsAgainstTrader(int256 x, uint256 y) public pure {
        x = bound(x, -1e30, 1e30);
        y = bound(y, 0, 1e33);
        int256 r = PerpMath.mulWadOwed(x, y);
        int256 exactNum = x * int256(y);
        if (x >= 0) {
            // Owed by the trader: rounded up.
            assertGe(r * int256(WAD), exactNum);
            assertLt((r - 1) * int256(WAD), exactNum);
        } else {
            // Owed to the trader: rounded towards zero (smaller credit).
            assertGe(r * int256(WAD), exactNum);
            assertLe(r, 0);
            assertLt((r - 1) * int256(WAD), exactNum);
        }
    }

    function test_bpsUp() public pure {
        assertEq(PerpMath.bpsUp(10_000e18, 5), 5e18);
        assertEq(PerpMath.bpsUp(1, 5), 1);
        assertEq(PerpMath.bpsUp(0, 5), 0);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Price impact
    // ---------------------------------------------------------------------------------------------------------------

    function test_impact_knownValues() public pure {
        // Balanced book, $1M long: imbalance 0 -> 1M, charged 1e24^2/1e18 * 5e8/1e18 = $500.
        assertEq(PerpMath.priceImpactUsd(0, 0, true, true, 1_000_000e18, POS, NEG), -500e18);
        // Short-heavy book by $1M, $1M long: imbalance 1M -> 0, paid at the positive factor = $250.
        assertEq(PerpMath.priceImpactUsd(0, 1_000_000e18, true, true, 1_000_000e18, POS, NEG), 250e18);
        // Crossover: short-heavy by 1M, $3M long: +250 (1M -> 0) - 2000 (0 -> 2M long-heavy).
        assertEq(PerpMath.priceImpactUsd(0, 1_000_000e18, true, true, 3_000_000e18, POS, NEG), -1750e18);
        // Decreasing the heavy side is positive; decreasing the light side is negative.
        assertGt(PerpMath.priceImpactUsd(2_000_000e18, 0, true, false, 1_000_000e18, POS, NEG), 0);
        assertLt(PerpMath.priceImpactUsd(1_000_000e18, 1_000_000e18, false, false, 500_000e18, POS, NEG), 0);
    }

    function test_revert_impact_decreaseBeyondOpenInterest() public {
        vm.expectRevert();
        h.impact(1e18, 0, true, false, 2e18, POS, NEG);
    }

    function testFuzz_impact_signMatchesImbalanceChange(uint256 l, uint256 s, bool isLong, bool inc, uint256 size)
        public
        pure
    {
        l = bound(l, 0, 1e27);
        s = bound(s, 0, 1e27);
        uint256 sideOi = isLong ? l : s;
        size = inc ? bound(size, 1, 1e27) : bound(size, 0, sideOi);
        int256 impact = PerpMath.priceImpactUsd(l, s, isLong, inc, size, POS, NEG);
        uint256 d0 = l > s ? l - s : s - l;
        uint256 nl = isLong ? (inc ? l + size : l - size) : l;
        uint256 ns = isLong ? s : (inc ? s + size : s - size);
        uint256 d1 = nl > ns ? nl - ns : ns - nl;
        if (d1 > d0) assertLe(impact, 0);
        bool sameSide = (l <= s) == (nl <= ns);
        // floor(k*d0^2) - ceil(k*d1^2) >= -1: a rebalancing trade earns >= 0 except for 1 wei of rounding that is
        // deliberately taken against the trader.
        if (sameSide && d1 <= d0) assertGe(impact, -1);
    }

    /// @dev Opening and immediately closing the same size can never earn price impact (positive <= negative factor).
    function testFuzz_impact_roundTripIsNeverPositive(
        uint256 l,
        uint256 s,
        bool isLong,
        uint256 size,
        uint256 posFactor,
        uint256 negFactor
    ) public pure {
        l = bound(l, 0, 1e28);
        s = bound(s, 0, 1e28);
        size = bound(size, 1, 1e28);
        negFactor = bound(negFactor, 0, 1e12);
        posFactor = bound(posFactor, 0, negFactor);
        int256 open = PerpMath.priceImpactUsd(l, s, isLong, true, size, posFactor, negFactor);
        uint256 nl = isLong ? l + size : l;
        uint256 ns = isLong ? s : s + size;
        int256 close = PerpMath.priceImpactUsd(nl, ns, isLong, false, size, posFactor, negFactor);
        assertLe(open + close, 0);
    }

    /// @dev A closed loop of trades on both sides (open long, open short, close long, close short, in a fuzzed order)
    ///      returns open interest to its start and earns no impact in total.
    function testFuzz_impact_closedLoopIsNeverPositive(uint256 l, uint256 s, uint256 a, uint256 b, bool order)
        public
        pure
    {
        l = bound(l, 0, 1e28);
        s = bound(s, 0, 1e28);
        a = bound(a, 1, 1e28);
        b = bound(b, 1, 1e28);
        int256 total;
        if (order) {
            total += PerpMath.priceImpactUsd(l, s, true, true, a, POS, NEG);
            total += PerpMath.priceImpactUsd(l + a, s, false, true, b, POS, NEG);
            total += PerpMath.priceImpactUsd(l + a, s + b, true, false, a, POS, NEG);
            total += PerpMath.priceImpactUsd(l, s + b, false, false, b, POS, NEG);
        } else {
            total += PerpMath.priceImpactUsd(l, s, false, true, b, POS, NEG);
            total += PerpMath.priceImpactUsd(l, s + b, true, true, a, POS, NEG);
            total += PerpMath.priceImpactUsd(l + a, s + b, false, false, b, POS, NEG);
            total += PerpMath.priceImpactUsd(l + a, s, true, false, a, POS, NEG);
        }
        assertLe(total, 0);
    }

    /// @dev Splitting a trade into two never changes the impact by more than rounding when both halves stay on the
    ///      same side of balance (the impact is a potential function of the imbalance).
    function testFuzz_impact_splitMatchesWhole(uint256 l, uint256 size, uint256 cut) public pure {
        l = bound(l, 0, 1e27);
        size = bound(size, 2, 1e27);
        cut = bound(cut, 1, size - 1);
        // Book long-heavy by l; adding longs grows the imbalance monotonically.
        int256 whole = PerpMath.priceImpactUsd(l, 0, true, true, size, POS, NEG);
        int256 split = PerpMath.priceImpactUsd(l, 0, true, true, cut, POS, NEG)
            + PerpMath.priceImpactUsd(l + cut, 0, true, true, size - cut, POS, NEG);
        assertApproxEqAbs(whole, split, 2);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Funding
    // ---------------------------------------------------------------------------------------------------------------

    function test_fundingIntegral_linearAndClamped() public pure {
        // r0 = 0, v = 10, dt = 10, cap large: integral = (0 + 100) / 2 * 10 = 500.
        (int256 i1, int256 r1) = PerpMath.fundingIntegral(0, 10, 10, 1e18);
        assertEq(i1, 500);
        assertEq(r1, 100);
        // Cap 50 hit at t = 5: 0.5*50*5 + 50*5 = 375.
        (int256 i2, int256 r2) = PerpMath.fundingIntegral(0, 10, 10, 50);
        assertEq(i2, 375);
        assertEq(r2, 50);
        // Negative mirror.
        (int256 i3, int256 r3) = PerpMath.fundingIntegral(0, -10, 10, 50);
        assertEq(i3, -375);
        assertEq(r3, -50);
        // No velocity: constant rate.
        (int256 i4, int256 r4) = PerpMath.fundingIntegral(7, 0, 3, 50);
        assertEq(i4, 21);
        assertEq(r4, 7);
        // Zero interval.
        (int256 i5, int256 r5) = PerpMath.fundingIntegral(7, 3, 0, 50);
        assertEq(i5, 0);
        assertEq(r5, 7);
        // A start rate above a (lowered) cap is clamped first.
        (int256 i6, int256 r6) = PerpMath.fundingIntegral(80, 0, 2, 50);
        assertEq(i6, 100);
        assertEq(r6, 50);
    }

    /// @dev Integrating over [0, t1] then [t1, t1 + t2] equals integrating over [0, t1 + t2] up to rounding.
    function testFuzz_fundingIntegral_isAdditive(int256 r0, int256 v, uint256 t1, uint256 t2, uint256 cap) public pure {
        cap = bound(cap, 1e6, 1e15);
        r0 = bound(r0, -int256(cap), int256(cap));
        v = bound(v, -1e12, 1e12);
        t1 = bound(t1, 0, 365 days);
        t2 = bound(t2, 0, 365 days);
        (int256 whole,) = PerpMath.fundingIntegral(r0, v, t1 + t2, cap);
        (int256 first, int256 mid) = PerpMath.fundingIntegral(r0, v, t1, cap);
        (int256 second,) = PerpMath.fundingIntegral(mid, v, t2, cap);
        // Each closed form truncates at most once or twice; the tolerance covers two divisions per piece.
        assertApproxEqAbs(first + second, whole, 3);
    }

    function testFuzz_fundingIntegral_boundedByCap(int256 r0, int256 v, uint256 dt, uint256 cap) public pure {
        cap = bound(cap, 1, 1e15);
        r0 = bound(r0, -int256(cap), int256(cap));
        v = bound(v, -1e12, 1e12);
        dt = bound(dt, 0, 10 * 365 days);
        (int256 integral, int256 r1) = PerpMath.fundingIntegral(r0, v, dt, cap);
        assertLe(integral, int256(cap * dt));
        assertGe(integral, -int256(cap * dt));
        assertLe(r1, int256(cap));
        assertGe(r1, -int256(cap));
    }

    function testFuzz_fundingVelocity_boundedAndSigned(uint256 l, uint256 s, uint256 scale, uint256 maxV) public pure {
        l = bound(l, 0, 1e30);
        s = bound(s, 0, 1e30);
        scale = bound(scale, 1, 1e30);
        maxV = bound(maxV, 0, 1e15);
        int256 v = PerpMath.fundingVelocity(l, s, scale, maxV);
        assertLe(v, int256(maxV));
        assertGe(v, -int256(maxV));
        if (l > s) assertGe(v, 0);
        if (l < s) assertLe(v, 0);
        uint256 skew = l > s ? l - s : s - l;
        if (skew >= scale) assertEq(v < 0 ? -v : v, int256(maxV));
    }

    function testFuzz_borrowRate_monotonicAndCapped(uint256 oi, uint256 extra, uint256 pool, uint256 factor)
        public
        pure
    {
        oi = bound(oi, 0, 1e30);
        extra = bound(extra, 0, 1e30);
        pool = bound(pool, 0, 1e30);
        factor = bound(factor, 0, 1e12);
        uint256 r1 = PerpMath.borrowRate(oi, pool, factor);
        uint256 r2 = PerpMath.borrowRate(oi + extra, pool, factor);
        assertLe(r1, factor);
        assertLe(r1, r2);
        if (oi == 0) assertEq(r1, 0);
    }
}
