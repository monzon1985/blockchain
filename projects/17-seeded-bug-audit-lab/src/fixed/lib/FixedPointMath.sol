// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";

/// @title FixedPointMath
/// @notice WAD fixed-point helpers for the Kestrel protocol plus a checked left shift used for
///         Q128 fixed-point ratios.
/// @dev    The WAD helpers delegate to Solady.
library FixedPointMath {
    /// @notice 1.0 in WAD fixed point (1e18).
    uint256 internal constant WAD = 1e18;
    /// @notice 1.0 in Q128 fixed point (2**128).
    uint256 internal constant Q128 = 1 << 128;

    /// @notice Multiply two WAD numbers, rounding the result down.
    /// @param x First WAD operand.
    /// @param y Second WAD operand.
    /// @return z `x * y / WAD`, truncated toward zero.
    function mulWadDown(uint256 x, uint256 y) internal pure returns (uint256 z) {
        z = FixedPointMathLib.mulWad(x, y);
    }

    /// @notice Multiply two WAD numbers, rounding the result up.
    /// @param x First WAD operand.
    /// @param y Second WAD operand.
    /// @return z `x * y / WAD`, rounded toward +infinity.
    function mulWadUp(uint256 x, uint256 y) internal pure returns (uint256 z) {
        z = FixedPointMathLib.mulWadUp(x, y);
    }

    /// @notice Divide two WAD numbers, rounding the result down.
    /// @param x WAD numerator.
    /// @param y WAD denominator.
    /// @return z `x * WAD / y`, truncated toward zero.
    function divWadDown(uint256 x, uint256 y) internal pure returns (uint256 z) {
        z = FixedPointMathLib.divWad(x, y);
    }

    /// @notice Divide two WAD numbers, rounding the result up.
    /// @param x WAD numerator.
    /// @param y WAD denominator.
    /// @return z `x * WAD / y`, rounded toward +infinity.
    function divWadUp(uint256 x, uint256 y) internal pure returns (uint256 z) {
        z = FixedPointMathLib.divWadUp(x, y);
    }

    /// @notice Full-precision `x * y / d`, truncated toward zero.
    /// @dev    When both factors fit in 128 bits the product fits in 256 bits, so plain
    ///         arithmetic is exact; this fast path is cheaper and keeps the expression linear
    ///         for symbolic execution. Otherwise Solady's 512-bit routine is used.
    /// @param x First factor.
    /// @param y Second factor.
    /// @param d Divisor (must be non-zero).
    /// @return z The exact product divided by `d`, rounded down.
    function mulDivDown(uint256 x, uint256 y, uint256 d) internal pure returns (uint256 z) {
        if ((x | y) >> 128 == 0) {
            z = x * y / d;
        } else {
            z = FixedPointMathLib.fullMulDiv(x, y, d);
        }
    }

    /// @notice Full-precision `x * y / d`, rounded up.
    /// @dev    Same fast path as {mulDivDown} (also requiring `d` below 2**128), computing the
    ///         ceiling with a single division.
    /// @param x First factor.
    /// @param y Second factor.
    /// @param d Divisor (must be non-zero).
    /// @return z The exact product divided by `d`, rounded up.
    function mulDivUp(uint256 x, uint256 y, uint256 d) internal pure returns (uint256 z) {
        if ((x | y | d) >> 128 == 0) {
            // x * y + d - 1 < 2**256 because every operand is below 2**128.
            z = (x * y + d - 1) / d;
        } else {
            z = FixedPointMathLib.fullMulDivUp(x, y, d);
        }
    }

    /// @notice Raise a WAD base to a WAD exponent (`base ** exp`).
    /// @dev    Thin wrapper over Solady `powWad`; both operands must be positive
    ///         and fit in `int256`. Used by the weighted-pool swap curve.
    /// @param base WAD base (0 < base).
    /// @param exp  WAD exponent.
    /// @return z `base ** exp` in WAD.
    function powWad(uint256 base, uint256 exp) internal pure returns (uint256 z) {
        // Both operands are WAD-scaled pool quantities bounded far below int256 max by
        // the callers (weights <= WAD, normalized balance ratios <= WAD); the casts
        // cannot truncate. We still assert it so the bound is enforced, not assumed.
        require(base >> 255 == 0 && exp >> 255 == 0, PowInputTooLarge());
        // Down-cast is bounded by the require above; it cannot truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 r = FixedPointMathLib.powWad(int256(base), int256(exp));
        // Solady computes powWad as expWad(lnWad(base) * exp), and expWad is never negative, so
        // the up-cast cannot wrap.
        // forge-lint: disable-next-line(unsafe-typecast)
        z = uint256(r);
    }

    /// @notice Thrown when a {powWad} operand does not fit in `int256`.
    error PowInputTooLarge();

    /// @notice Left-shift `n` by `shift` bits, reporting whether any set bit would be lost.
    /// @param n     Value to shift.
    /// @param shift Number of bits to shift left.
    /// @return result The shifted value (0 when overflow is reported).
    /// @return overflow True when the shift would lose set bits.
    function checkedShl(uint256 n, uint256 shift) internal pure returns (uint256 result, bool overflow) {
        // [SC09] A left shift by `shift` drops exactly the bits at positions >= 256 - shift, so
        // the guard must depend on `shift`. A fixed mask (e.g. the top 64 bits) misses the bits
        // just below it whenever `shift` exceeds the mask width.
        if (shift >= 256) {
            overflow = n != 0;
            return (result, overflow);
        }
        if (shift != 0 && n >> (256 - shift) != 0) {
            overflow = true;
            return (result, overflow);
        }
        unchecked {
            // Safe: the guard above proved that no set bit is shifted out. [SC09]
            result = n << shift;
        }
    }
}
