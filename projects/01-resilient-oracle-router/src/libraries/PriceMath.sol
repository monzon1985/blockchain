// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IPriceOracle} from "../interfaces/IPriceOracle.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title PriceMath
/// @notice Decimal normalization with intent-directed rounding, and the deviation-breaker metric.
/// @dev Inputs are bounded by the router's configuration rules: raw answers are at most `type(uint192).max` and feed
///      decimals at most 36. Under those bounds no multiplication below can overflow (see each function).
library PriceMath {
    /// @notice Decimals of every normalized price.
    uint8 internal constant WAD_DECIMALS = 18;

    /// @notice Basis points in 100 %.
    uint256 internal constant BPS = 10_000;

    /// @notice Normalizes a raw feed answer to 1e18 precision.
    /// @dev Exact for `decimals <= 18` (a pure scale-up: `answer < 2^192` times at most `1e18 < 2^60` stays below
    ///      2^252). Above 18 decimals the division rounds down for `Collateral` and up for `Debt`, so the result
    ///      never overvalues collateral or undervalues debt; the two differ by at most one wei.
    /// @param answer Raw positive answer.
    /// @param decimals Feed decimals, at most 36.
    /// @param intent Rounding direction.
    /// @return The answer in 1e18 precision.
    function toWad(uint256 answer, uint8 decimals, IPriceOracle.Intent intent) internal pure returns (uint256) {
        if (decimals <= WAD_DECIMALS) return answer * 10 ** (WAD_DECIMALS - decimals);
        uint256 divisor = 10 ** (decimals - WAD_DECIMALS);
        return intent == IPriceOracle.Intent.Debt ? Math.ceilDiv(answer, divisor) : answer / divisor;
    }

    /// @notice Normalizes a time-weighted sum of raw answers into a 1e18 average price with a single rounding step.
    /// @dev `sum / period` and the decimal scaling are folded into one `mulDiv`, so the average is rounded once, in
    ///      the caller's direction. `sum < 2^224` and the result is at most the largest averaged answer scaled to
    ///      1e18, so `mulDiv` (512-bit intermediate) cannot overflow.
    /// @param sum Sum of `answer * seconds` over the window.
    /// @param period Window length in seconds, non-zero.
    /// @param decimals Feed decimals, at most 36.
    /// @param intent Rounding direction.
    /// @return The time-weighted average in 1e18 precision.
    function averageToWad(uint256 sum, uint256 period, uint8 decimals, IPriceOracle.Intent intent)
        internal
        pure
        returns (uint256)
    {
        Math.Rounding rounding = intent == IPriceOracle.Intent.Debt ? Math.Rounding.Ceil : Math.Rounding.Floor;
        if (decimals <= WAD_DECIMALS) return Math.mulDiv(sum, 10 ** (WAD_DECIMALS - decimals), period, rounding);
        return Math.mulDiv(sum, 1, period * 10 ** (decimals - WAD_DECIMALS), rounding);
    }

    /// @notice Gap between two prices in basis points of the lower one, rounded up.
    /// @dev Rounding up makes `deviationBps(a, b) > threshold` exactly equivalent to the real-valued gap exceeding the
    ///      threshold. Saturates at `type(uint256).max` instead of overflowing, so it never reverts for non-zero input.
    /// @param a First price, non-zero.
    /// @param b Second price, non-zero.
    /// @return The deviation in basis points.
    function deviationBps(uint256 a, uint256 b) internal pure returns (uint256) {
        (uint256 lo, uint256 hi) = a < b ? (a, b) : (b, a);
        uint256 gap = hi - lo;
        if (gap > type(uint256).max / BPS) return type(uint256).max;
        return Math.ceilDiv(gap * BPS, lo);
    }
}
