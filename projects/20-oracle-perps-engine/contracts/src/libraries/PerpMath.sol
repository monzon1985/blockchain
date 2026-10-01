// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {FixedPointMathLib as FPM} from "solady/utils/FixedPointMathLib.sol";

/// @title PerpMath
/// @notice Pure fixed-point math for the perpetuals market: PnL, quadratic price impact and the velocity funding
///         integral. Every rounding decision is taken against the trader (in favour of the pool); the proofs are in
///         `docs/DESIGN.md` and the properties are fuzzed in `test/unit/PerpMath.t.sol`.
/// @dev Solady's `fullMulDiv{,Up}` is used for 512-bit intermediate products (cheaper than OpenZeppelin's
///      `Math.mulDiv` and reverts on overflow of the final result or division by zero).
library PerpMath {
    using SafeCast for uint256;

    /// @notice 1.0 in 18-decimal fixed point.
    uint256 internal constant WAD = 1e18;

    /// @notice Basis-point denominator.
    uint256 internal constant BPS = 10_000;

    /// @notice Index tokens represented by `sizeUsd` of notional at `price`.
    /// @dev Longs round down and shorts round up, so that a position opened and closed at the same price never shows
    ///      positive PnL: floor(floor(s/p)*p) <= s and ceil(ceil(s/p)*p) >= s.
    /// @param sizeUsd Notional (USD, WAD).
    /// @param price Price (USD per token, WAD); must be non-zero.
    /// @param isLong Side.
    /// @return Index-token amount (WAD).
    function tokensForSize(uint256 sizeUsd, uint256 price, bool isLong) internal pure returns (uint256) {
        return isLong ? FPM.fullMulDiv(sizeUsd, WAD, price) : FPM.fullMulDivUp(sizeUsd, WAD, price);
    }

    /// @notice PnL of `sizeInTokens` bought (long) or sold (short) for `sizeUsd`, marked at `price`.
    /// @dev Long: floor(tokens * price) - sizeUsd. Short: sizeUsd - ceil(tokens * price). Both round against the trader.
    /// @param isLong Side.
    /// @param sizeUsd Notional at entry (USD, WAD).
    /// @param sizeInTokens Index tokens (WAD).
    /// @param price Mark price (WAD).
    /// @return Signed PnL (USD, WAD).
    function pnl(bool isLong, uint256 sizeUsd, uint256 sizeInTokens, uint256 price) internal pure returns (int256) {
        if (isLong) {
            return FPM.fullMulDiv(sizeInTokens, price, WAD).toInt256() - sizeUsd.toInt256();
        }
        return sizeUsd.toInt256() - FPM.fullMulDivUp(sizeInTokens, price, WAD).toInt256();
    }

    /// @notice `x * y / d` for a signed `x`, rounded towards negative infinity.
    /// @param x Signed multiplicand.
    /// @param y Unsigned multiplier.
    /// @param d Unsigned divisor (non-zero).
    /// @return Signed result, floor-rounded.
    function mulDivFloor(int256 x, uint256 y, uint256 d) internal pure returns (int256) {
        if (x >= 0) return FPM.fullMulDiv(uint256(x), y, d).toInt256();
        return -FPM.fullMulDivUp(FPM.abs(x), y, d).toInt256();
    }

    /// @notice `x * y / WAD` for a signed `x`, rounded away from the trader: positive results (amounts owed by the
    ///         trader) round up, negative results (amounts owed to the trader) round towards zero.
    /// @param x Signed per-unit amount (e.g. an index delta).
    /// @param y Unsigned quantity (e.g. position size).
    /// @return Signed product.
    function mulWadOwed(int256 x, uint256 y) internal pure returns (int256) {
        if (x >= 0) return FPM.fullMulDivUp(uint256(x), y, WAD).toInt256();
        return -FPM.fullMulDiv(FPM.abs(x), y, WAD).toInt256();
    }

    /// @notice Quadratic price impact of changing open interest, GMX-v2 style.
    /// @dev With `d0 = |L - S|` before and `d1 = |L' - S'|` after the trade:
    ///      - same side of balance, imbalance shrinks:  +positiveFactor * (d0^2 - d1^2)
    ///      - same side of balance, imbalance grows:    -negativeFactor * (d1^2 - d0^2)
    ///      - the trade flips the imbalance:            +positiveFactor * d0^2 - negativeFactor * d1^2
    ///      Positive terms round down, negative terms round up. Because the impact is a function of the squared
    ///      imbalance with `positiveFactor <= negativeFactor`, any sequence of trades that returns open interest to its
    ///      starting point has a non-positive total impact (no free round trips).
    /// @param longOi Long open interest before the trade (USD).
    /// @param shortOi Short open interest before the trade (USD).
    /// @param isLong Side of the trade.
    /// @param isIncrease Whether the trade adds (true) or removes (false) open interest.
    /// @param sizeDeltaUsd Notional traded (USD); must not exceed the side's open interest for decreases.
    /// @param positiveFactor Factor applied to imbalance reductions (WAD per USD).
    /// @param negativeFactor Factor applied to imbalance increases (WAD per USD).
    /// @return impactUsd Signed impact: positive is paid to the trader, negative is charged.
    function priceImpactUsd(
        uint256 longOi,
        uint256 shortOi,
        bool isLong,
        bool isIncrease,
        uint256 sizeDeltaUsd,
        uint256 positiveFactor,
        uint256 negativeFactor
    ) internal pure returns (int256 impactUsd) {
        uint256 nextLong = longOi;
        uint256 nextShort = shortOi;
        if (isLong) {
            nextLong = isIncrease ? longOi + sizeDeltaUsd : longOi - sizeDeltaUsd;
        } else {
            nextShort = isIncrease ? shortOi + sizeDeltaUsd : shortOi - sizeDeltaUsd;
        }
        uint256 d0 = FPM.dist(longOi, shortOi);
        uint256 d1 = FPM.dist(nextLong, nextShort);
        bool sameSide = (longOi <= shortOi) == (nextLong <= nextShort);

        if (sameSide) {
            if (d1 < d0) {
                return
                    _impactTerm(d0, positiveFactor, false).toInt256() - _impactTerm(d1, positiveFactor, true).toInt256();
            }
            return _impactTerm(d0, negativeFactor, false).toInt256() - _impactTerm(d1, negativeFactor, true).toInt256();
        }
        return _impactTerm(d0, positiveFactor, false).toInt256() - _impactTerm(d1, negativeFactor, true).toInt256();
    }

    /// @notice Integral of a linearly drifting, clamped funding rate over `dt` seconds.
    /// @dev The rate follows r(t) = clamp(r0 + v*t, -maxRate, maxRate). Closed forms:
    ///      - no clamp hit:         (r0 + r1) / 2 * dt
    ///      - hits +maxRate (v>0):  maxRate*dt - (maxRate - r0)^2 / (2v)
    ///      - hits -maxRate (v<0):  -maxRate*dt + (maxRate + r0)^2 / (2|v|)
    ///      The clamp form follows from integrating the ramp up to t* = (maxRate - r0)/v and the plateau after it,
    ///      and avoids computing the fractional crossing time explicitly.
    /// @param r0 Rate at the start of the interval (WAD per second); clamped to [-maxRate, maxRate] first.
    /// @param velocity Rate of change of the rate (WAD per second squared).
    /// @param dt Interval length in seconds.
    /// @param maxRate Absolute cap on the rate (WAD per second).
    /// @return integral Funding per unit of size accrued over the interval (WAD, positive means longs pay).
    /// @return r1 Rate at the end of the interval.
    function fundingIntegral(int256 r0, int256 velocity, uint256 dt, uint256 maxRate)
        internal
        pure
        returns (int256 integral, int256 r1)
    {
        int256 cap = maxRate.toInt256();
        r0 = FPM.clamp(r0, -cap, cap);
        if (dt == 0) return (0, r0);
        int256 t = dt.toInt256();
        if (velocity == 0) return (r0 * t, r0);

        int256 unclamped = r0 + velocity * t;
        if (unclamped > cap) {
            // velocity > 0 here because r0 <= cap.
            int256 gap = cap - r0;
            integral = cap * t - ((gap * gap) / (2 * velocity));
            r1 = cap;
        } else if (unclamped < -cap) {
            // velocity < 0 here because r0 >= -cap.
            int256 gap = cap + r0;
            integral = -cap * t + ((gap * gap) / (-2 * velocity));
            r1 = -cap;
        } else {
            integral = ((r0 + unclamped) * t) / 2;
            r1 = unclamped;
        }
    }

    /// @notice Funding velocity for the current skew: `maxVelocity * clamp(skew / skewScale, -1, 1)`.
    /// @param longOi Long open interest (USD).
    /// @param shortOi Short open interest (USD).
    /// @param skewScale Skew at which the velocity saturates (USD, non-zero).
    /// @param maxVelocity Velocity at full proportional skew (WAD per second squared).
    /// @return Signed velocity (positive pushes the rate towards longs paying).
    function fundingVelocity(uint256 longOi, uint256 shortOi, uint256 skewScale, uint256 maxVelocity)
        internal
        pure
        returns (int256)
    {
        uint256 skewAbs = FPM.dist(longOi, shortOi);
        uint256 proportional = FPM.min(FPM.fullMulDiv(skewAbs, WAD, skewScale), WAD);
        int256 v = FPM.fullMulDiv(proportional, maxVelocity, WAD).toInt256();
        return longOi >= shortOi ? v : -v;
    }

    /// @notice Borrow rate of one side: `borrowFactor * min(openInterest / poolAmount, 1)`.
    /// @param openInterest Side open interest (USD).
    /// @param poolAmount LP liquidity (USD).
    /// @param borrowFactor Rate at full utilisation (WAD per second).
    /// @return Rate per second (WAD).
    function borrowRate(uint256 openInterest, uint256 poolAmount, uint256 borrowFactor)
        internal
        pure
        returns (uint256)
    {
        if (openInterest == 0) return 0;
        if (poolAmount == 0 || openInterest >= poolAmount) return borrowFactor;
        return FPM.fullMulDivUp(borrowFactor, openInterest, poolAmount);
    }

    /// @notice `bps` basis points of `amount`, rounded up (fees are rounded against the payer).
    /// @param amount Base amount.
    /// @param bps Basis points.
    /// @return The fee.
    function bpsUp(uint256 amount, uint256 bps) internal pure returns (uint256) {
        return FPM.fullMulDivUp(amount, bps, BPS);
    }

    /// @dev factor * d^2 / WAD^2, with the requested rounding direction.
    function _impactTerm(uint256 d, uint256 factor, bool roundUp) private pure returns (uint256) {
        if (d == 0 || factor == 0) return 0;
        if (roundUp) return FPM.fullMulDivUp(FPM.fullMulDivUp(d, d, WAD), factor, WAD);
        return FPM.fullMulDiv(FPM.fullMulDiv(d, d, WAD), factor, WAD);
    }
}
