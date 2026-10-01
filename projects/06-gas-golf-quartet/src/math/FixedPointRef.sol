// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title FixedPointRef
/// @author Gas Golf Quartet
/// @notice Reference fixed-point kernel in plain, assembly-free Solidity: 512-bit `mulDiv`, Babylonian
///         `sqrt` and binary-search `log2`. It favours readability over gas and is the specification the
///         golfed kernels (`FixedPointGolf`, `FixedPointLegacy`) are proven or fuzzed against.
/// @dev `mulDiv` follows Remco Bloemen's full-precision algorithm (MIT, https://xn--2-umb.com/21/muldiv),
///      as popularised by Uniswap v3 `FullMath`; `sqrt` is the Babylonian method from Uniswap v2 `Math`.
library FixedPointRef {
    /// @notice `mulDiv` / `mulDivUp` result does not fit in 256 bits, or the denominator is zero.
    /// @dev Same name and selector (0xae47f702) as Solady's FixedPointMathLib and FixedPointGolf.
    error FullMulDivFailed();

    // Slither triage: exact divisions by the power of two `twos` precede the Newton products on purpose (Remco
    // Bloemen's algorithm), and `^` is XOR: `(3 * d) ^ 2` is the 4-bit inverse seed, not exponentiation.
    // slither-disable-start divide-before-multiply,incorrect-exp
    /// @notice floor(x * y / d) with a 512-bit intermediate product.
    /// @param x Multiplicand.
    /// @param y Multiplier.
    /// @param d Denominator. Must be non-zero.
    /// @return result The rounded-down quotient. Reverts with `FullMulDivFailed` if it overflows.
    function mulDiv(uint256 x, uint256 y, uint256 d) internal pure returns (uint256 result) {
        unchecked {
            // Every operation below is modular on purpose: [prod1 prod0] is a 512-bit number assembled from
            // two 256-bit words, and the Newton iteration computes an inverse modulo 2**256.
            uint256 prod0 = x * y; // Low 256 bits of the product.
            uint256 mm = mulmod(x, y, type(uint256).max);
            // High 256 bits via the Chinese Remainder Theorem: mm - prod0 - borrow.
            uint256 prod1 = mm - prod0;
            if (mm < prod0) prod1 -= 1;

            if (prod1 == 0) {
                if (d == 0) revert FullMulDivFailed();
                return prod0 / d;
            }
            // The quotient fits in 256 bits only if d > prod1; this also rules out d == 0.
            if (d <= prod1) revert FullMulDivFailed();

            // Make the division exact by subtracting the remainder from [prod1 prod0].
            uint256 remainder = mulmod(x, y, d);
            if (remainder > prod0) prod1 -= 1;
            prod0 -= remainder;

            // Factor the largest power of two out of d. `twos` is at least 1 because d != 0.
            uint256 twos = d & (0 - d);
            d /= twos;
            prod0 /= twos;
            // 2**256 / twos, computed without 257-bit arithmetic.
            twos = (0 - twos) / twos + 1;
            // Shift the high word's bits into the low word.
            prod0 |= prod1 * twos;

            // d is odd now, so it is invertible modulo 2**256. The seed is correct to 4 bits and every
            // Newton-Raphson step doubles the correct bits (Hensel lifting): 8, 16, 32, 64, 128, 256.
            uint256 inverse = (3 * d) ^ 2;
            inverse *= 2 - d * inverse;
            inverse *= 2 - d * inverse;
            inverse *= 2 - d * inverse;
            inverse *= 2 - d * inverse;
            inverse *= 2 - d * inverse;
            inverse *= 2 - d * inverse;

            // The division is exact and the quotient fits in 256 bits, so one modular product finishes it.
            result = prod0 * inverse;
        }
    }

    // slither-disable-end divide-before-multiply,incorrect-exp

    /// @notice ceil(x * y / d) with a 512-bit intermediate product.
    /// @param x Multiplicand.
    /// @param y Multiplier.
    /// @param d Denominator. Must be non-zero.
    /// @return result The rounded-up quotient. Reverts with `FullMulDivFailed` if it overflows.
    function mulDivUp(uint256 x, uint256 y, uint256 d) internal pure returns (uint256 result) {
        result = mulDiv(x, y, d);
        // d != 0 here: mulDiv reverted otherwise.
        if (mulmod(x, y, d) != 0) {
            if (result == type(uint256).max) revert FullMulDivFailed();
            ++result;
        }
    }

    /// @notice floor(sqrt(x)) by the Babylonian method.
    /// @param x Radicand.
    /// @return z The integer square root.
    function sqrt(uint256 x) internal pure returns (uint256 z) {
        if (x > 3) {
            z = x;
            uint256 y = x / 2 + 1;
            // The iterates decrease monotonically to floor(sqrt(x)), so the loop terminates.
            while (y < z) {
                z = y;
                y = (x / y + y) / 2;
            }
        } else if (x != 0) {
            z = 1;
        }
    }

    /// @notice floor(log2(x)), i.e. the index of the most significant set bit.
    /// @param x Value to inspect.
    /// @return r The bit index; 0 for `x == 0` (the OpenZeppelin and Solady convention).
    function log2(uint256 x) internal pure returns (uint256 r) {
        if (x >> 128 != 0) {
            x >>= 128;
            r += 128;
        }
        if (x >> 64 != 0) {
            x >>= 64;
            r += 64;
        }
        if (x >> 32 != 0) {
            x >>= 32;
            r += 32;
        }
        if (x >> 16 != 0) {
            x >>= 16;
            r += 16;
        }
        if (x >> 8 != 0) {
            x >>= 8;
            r += 8;
        }
        if (x >> 4 != 0) {
            x >>= 4;
            r += 4;
        }
        if (x >> 2 != 0) {
            x >>= 2;
            r += 2;
        }
        if (x >> 1 != 0) r += 1;
    }

    /// @notice ceil(log2(x)).
    /// @param x Value to inspect.
    /// @return r The smallest `r` with `2**r >= x`; 0 for `x <= 1`.
    function log2Up(uint256 x) internal pure returns (uint256 r) {
        r = log2(x);
        if ((1 << r) < x) ++r;
    }

    /// @notice Number of leading zero bits of `x` (EIP-7939 semantics).
    /// @param x Value to inspect.
    /// @return 256 for `x == 0`, otherwise `255 - log2(x)`.
    function clz(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 256;
        return 255 - log2(x);
    }
}
