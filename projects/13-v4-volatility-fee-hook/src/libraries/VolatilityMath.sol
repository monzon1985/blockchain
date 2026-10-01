// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title VolatilityMath
/// @notice Fixed-point math behind the volatility-aware fee: an exponentially weighted moving average (EWMA) of the
/// absolute tick change per block, the LP fee derived from it, and the top-of-block surcharge.
/// @dev Units:
///  - `ewmaWad` is measured in ticks, scaled by 1e18 (1 tick ~ 1 basis point of price).
///  - `alphaWad` is the EWMA weight of the newest sample, scaled by 1e18, in (0, 1e18].
///  - fees are in pips (hundredths of a basis point, 1e6 = 100%), the unit Uniswap v4 uses for LP fees.
///
/// Rounding directions (see README, "Rounding-direction table"):
///  - `decayFactor` and `updateEwma` round DOWN: the EWMA is a contraction, never exceeds the largest sample it
///    has seen, and reaches exactly zero after enough idle blocks instead of sticking at 1 wei.
///  - `lpFee`, `surchargeRate`, `surchargeAmount` and `proRatedSurcharge` round UP: they are charged to the swapper
///    and paid to LPs.
library VolatilityMath {
    /// @notice 1.0 in 18-decimal fixed point.
    uint256 internal constant WAD = 1e18;

    /// @notice 100% expressed in pips.
    uint256 internal constant PIPS_DENOMINATOR = 1e6;

    /// @notice Lower clamp of the dynamic LP fee: 5 bps.
    uint24 internal constant MIN_FEE_PIPS = 500;

    /// @notice Upper clamp of the dynamic LP fee: 100 bps.
    uint24 internal constant MAX_FEE_PIPS = 10_000;

    /// @notice Absolute distance between two ticks, as an unsigned tick count.
    /// @param a First tick.
    /// @param b Second tick.
    /// @return The value |a - b|, at most 1,774,544 for valid v4 ticks.
    function absTickDelta(int24 a, int24 b) internal pure returns (uint256) {
        int256 d = int256(a) - int256(b);
        // Casting to uint256 is safe: each branch casts a non-negative value, and |d| < 2^25.
        // forge-lint: disable-next-line(unsafe-typecast)
        return d >= 0 ? uint256(d) : uint256(-d);
    }

    /// @notice Computes (1 - alpha)^k in WAD by square-and-multiply, rounding every product down.
    /// @dev Every intermediate value is at most WAD, so each product is at most 1e36 and cannot overflow.
    /// The loop runs at most bitlength(k) times and exits early once the result underflows to zero.
    /// @param alphaWad EWMA weight of the newest sample, in (0, WAD].
    /// @param k Exponent (number of blocks).
    /// @return result The decay factor, never greater than the exact real value.
    // Dividing by WAD after every product is the fixed-point representation, not a precision bug: the error bound is
    // derived in the README and checked against exact values in VolatilityMathDifferential.t.sol.
    // slither-disable-next-line divide-before-multiply
    function decayFactor(uint256 alphaWad, uint256 k) internal pure returns (uint256 result) {
        uint256 base = WAD - alphaWad;
        result = WAD;
        // Safe: result <= WAD and base <= WAD, so every product is < 2^256; k only shifts right.
        unchecked {
            while (true) {
                if ((k & 1) == 1) result = (result * base) / WAD;
                k >>= 1;
                if (k == 0 || result == 0) return result;
                base = (base * base) / WAD;
            }
        }
    }

    /// @notice Folds the tick movement of the block that just closed into the EWMA and decays it across the idle
    /// blocks that followed.
    /// @dev The hook samples the pool once per block, at the first swap. If the previous sample was taken
    /// `blocksElapsed` blocks ago, the tick moved by `sampleTicks` during that sampled block and by zero in each of
    /// the `blocksElapsed - 1` blocks after it (no swap happened, so the price could not move). The exact update is
    /// therefore e' = ((1 - a) * e + a * d) * (1 - a)^(k - 1), computed here with round-down at every step.
    /// Overflow: e <= 1,774,544e18 (a convex combination never exceeds its largest sample) and a <= 1e18, so every
    /// product is below 2e42.
    /// @param ewmaWad Current EWMA, ticks scaled by 1e18.
    /// @param sampleTicks Absolute tick change over the sampled block.
    /// @param blocksElapsed Blocks since the previous sample; must be at least 1.
    /// @param alphaWad EWMA weight of the newest sample, in (0, WAD].
    /// @return next The updated EWMA, never greater than the exact real value.
    function updateEwma(uint256 ewmaWad, uint256 sampleTicks, uint256 blocksElapsed, uint256 alphaWad)
        internal
        pure
        returns (uint256 next)
    {
        // alphaWad * sampleTicks is an exact integer, so only the first term is rounded.
        next = ((WAD - alphaWad) * ewmaWad) / WAD + alphaWad * sampleTicks;
        if (blocksElapsed > 1 && next != 0) {
            next = (next * decayFactor(alphaWad, blocksElapsed - 1)) / WAD;
        }
    }

    /// @notice Dynamic LP fee: 5 bps plus `slopePips` for every tick of EWMA volatility, rounded up and clamped to
    /// [5 bps, 100 bps].
    /// @param ewmaWad EWMA volatility, ticks scaled by 1e18.
    /// @param slopePips Fee increment per tick of volatility, in pips.
    /// @return fee LP fee in pips, within [MIN_FEE_PIPS, MAX_FEE_PIPS].
    function lpFee(uint256 ewmaWad, uint256 slopePips) internal pure returns (uint24 fee) {
        uint256 raw = MIN_FEE_PIPS + Math.ceilDiv(ewmaWad * slopePips, WAD);
        // Casting to uint24 is safe: the cast only runs when raw <= MAX_FEE_PIPS (10,000).
        // forge-lint: disable-next-line(unsafe-typecast)
        fee = raw > MAX_FEE_PIPS ? MAX_FEE_PIPS : uint24(raw);
    }

    /// @notice Top-of-block surcharge rate: `slopePips` per tick of EWMA volatility, rounded up and capped.
    /// @param ewmaWad EWMA volatility, ticks scaled by 1e18.
    /// @param slopePips Surcharge increment per tick of volatility, in pips.
    /// @param capPips Maximum surcharge rate, in pips.
    /// @return rate Surcharge rate in pips, within [0, capPips].
    function surchargeRate(uint256 ewmaWad, uint256 slopePips, uint256 capPips) internal pure returns (uint24 rate) {
        uint256 raw = Math.ceilDiv(ewmaWad * slopePips, WAD);
        // The hook validates capPips <= 10,000; SafeCast keeps the library safe for any other caller.
        rate = SafeCast.toUint24(raw > capPips ? capPips : raw);
    }

    /// @notice Surcharge owed on a swap's unspecified amount, rounded up.
    /// @dev For `ratePips <= 1e6` the result never exceeds `amount`, because ceil(x * r) <= x for integer x and r <= 1.
    /// @param amount Absolute unspecified amount of the swap (at most 2^127).
    /// @param ratePips Surcharge rate in pips.
    /// @return The surcharge, in units of the unspecified currency.
    function surchargeAmount(uint256 amount, uint256 ratePips) internal pure returns (uint256) {
        return Math.ceilDiv(amount * ratePips, PIPS_DENOMINATOR);
    }

    /// @notice Surcharge owed on the part of a swap that pushed the price beyond the block's previous price range.
    /// @dev The swap moved the price from `pre` to `post`, and `edge` is the block's range boundary on that side
    /// (`edge == pre` when the swap started on the boundary, as the first swap of every block does). Only the segment
    /// from `edge` to `post` is new ground, so the swap's unspecified `amount` is pro-rated to that segment in the
    /// coordinate in which its currency is linear at constant liquidity: sqrt(P) for currency1 (amount1 = L * d sqrt(P))
    /// and 1/sqrt(P) for currency0 (amount0 = L * d(1/sqrt(P))), which turns the sqrt-price share b/T into b*pre/(T*edge).
    /// While the in-range liquidity is constant over the swap, the result equals the surcharge on the new segment alone,
    /// so splitting a swap at any intermediate price leaves the total unchanged up to rounding, and the charge is a
    /// continuous function of the end price. Every step rounds up; the result is capped at the surcharge on the whole
    /// swap, because rounding the currency0 share twice can overshoot it by one unit.
    /// Overflow: amount < 2^128 and ratePips <= 1e6, so amount * ratePips < 2^148; mulDiv keeps 512-bit intermediates.
    /// @param amount Absolute unspecified amount of the whole swap.
    /// @param ratePips Surcharge rate in pips (at most 1e6).
    /// @param pre Pool sqrt price before the swap (Q64.96).
    /// @param post Pool sqrt price after the swap (Q64.96); strictly beyond `edge`.
    /// @param edge The block's range boundary on the side the swap moved toward, between `pre` and `post` inclusive.
    /// @param inCurrency1 True if `amount` is denominated in currency1, false for currency0.
    /// @return The surcharge, in units of the unspecified currency, never above `surchargeAmount(amount, ratePips)`.
    function proRatedSurcharge(
        uint256 amount,
        uint256 ratePips,
        uint256 pre,
        uint256 post,
        uint256 edge,
        bool inCurrency1
    ) internal pure returns (uint256) {
        uint256 full = surchargeAmount(amount, ratePips);
        if (edge == pre) return full;
        uint256 total = pre > post ? pre - post : post - pre;
        uint256 beyond = edge > post ? edge - post : post - edge;
        uint256 share = Math.mulDiv(amount * ratePips, beyond, total, Math.Rounding.Ceil);
        if (!inCurrency1) share = Math.mulDiv(share, pre, edge, Math.Rounding.Ceil);
        uint256 surcharge = Math.ceilDiv(share, PIPS_DENOMINATOR);
        return surcharge > full ? full : surcharge;
    }
}
