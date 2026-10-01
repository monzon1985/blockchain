// SPDX-License-Identifier: GPL-2.0-or-later
// Adapted from Morpho Blue by Morpho Labs, https://github.com/morpho-org/morpho-blue (GPL-2.0-or-later),
// src/libraries/MathLib.sol: mulDivDown, wMulDown, wDivDown, wDivUp and wTaylorCompounded follow the original; mulDivUp
// is rewritten so it cannot overflow where the floor does not, and the NatSpec is new. Modified for this project in
// 2026; see the README's License section.
pragma solidity 0.8.37;

/// @dev Fixed-point unit (1.0).
uint256 constant WAD = 1e18;

/// @title MathLib
/// @notice Rounding-explicit fixed-point helpers used by the engine's share accounting and interest accrual.
/// @dev Every function names its rounding direction. Products are computed in 256 bits with checked arithmetic:
///      an overflow reverts instead of returning a wrong value, which is the safe failure for accounting.
library MathLib {
    /// @notice `floor(x * y / d)`.
    /// @param x First factor.
    /// @param y Second factor.
    /// @param d Divisor (reverts on zero).
    /// @return The quotient rounded down.
    function mulDivDown(uint256 x, uint256 y, uint256 d) internal pure returns (uint256) {
        return (x * y) / d;
    }

    /// @notice `ceil(x * y / d)`.
    /// @dev Written as `p / d + (p % d != 0)` so it cannot overflow where `floor` does not.
    /// @param x First factor.
    /// @param y Second factor.
    /// @param d Divisor (reverts on zero).
    /// @return The quotient rounded up.
    function mulDivUp(uint256 x, uint256 y, uint256 d) internal pure returns (uint256) {
        uint256 p = x * y;
        return p / d + (p % d == 0 ? 0 : 1);
    }

    /// @notice `floor(x * y / WAD)`.
    /// @param x WAD-scaled or raw amount.
    /// @param y WAD-scaled factor.
    /// @return The product rounded down.
    function wMulDown(uint256 x, uint256 y) internal pure returns (uint256) {
        return mulDivDown(x, y, WAD);
    }

    /// @notice `floor(x * WAD / y)`.
    /// @param x Numerator.
    /// @param y WAD-scaled denominator.
    /// @return The quotient rounded down.
    function wDivDown(uint256 x, uint256 y) internal pure returns (uint256) {
        return mulDivDown(x, WAD, y);
    }

    /// @notice `ceil(x * WAD / y)`.
    /// @param x Numerator.
    /// @param y WAD-scaled denominator.
    /// @return The quotient rounded up.
    function wDivUp(uint256 x, uint256 y) internal pure returns (uint256) {
        return mulDivUp(x, WAD, y);
    }

    /// @notice Third-order Taylor expansion of `e^(x * n) - 1`, WAD-scaled.
    /// @dev Underestimates continuous compounding (every omitted term is positive), never reverts for realistic
    ///      inputs, and grows polynomially, so a long-idle market cannot overflow into a bricked state the way an
    ///      exact exponential would. At 100 % APR over one year the underestimate is 3 %.
    /// @param x Rate per second (WAD).
    /// @param n Elapsed seconds.
    /// @return The compounded growth factor minus one (WAD).
    function wTaylorCompounded(uint256 x, uint256 n) internal pure returns (uint256) {
        uint256 firstTerm = x * n;
        uint256 secondTerm = mulDivDown(firstTerm, firstTerm, 2 * WAD);
        uint256 thirdTerm = mulDivDown(secondTerm, firstTerm, 3 * WAD);
        return firstTerm + secondTerm + thirdTerm;
    }

    /// @notice `max(0, x - y)`.
    /// @param x Minuend.
    /// @param y Subtrahend.
    /// @return The saturating difference.
    function zeroFloorSub(uint256 x, uint256 y) internal pure returns (uint256) {
        return x > y ? x - y : 0;
    }

    /// @notice Smaller of two values.
    /// @param x First value.
    /// @param y Second value.
    /// @return The minimum.
    function min(uint256 x, uint256 y) internal pure returns (uint256) {
        return x < y ? x : y;
    }
}
