// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Clz} from "clz/Clz.sol";

/// @title FixedPointGolf
/// @author Gas Golf Quartet
/// @notice Golfed fixed-point kernel for Osaka+ chains: assembly `mulDiv` and CLZ-based `log2`, `log2Up`,
///         `clz` and `sqrt`. Every function is equivalent to `FixedPointRef` (same results, same reverts):
///         `mulDiv` and `mulDivUp` are proven for all inputs with halmos (test/halmos/MathEquivalence.t.sol).
///         `log2`, `log2Up` and `clz` are proven for all 256-bit inputs through a plain-EVM model of CLZ
///         (halmos 0.3.3 lacks opcode 0x1e, so its profile remaps `clz/` to test/halmos/clz-model), and that
///         model is tested against the real opcode on every bit length and under fuzzing
///         (test/math/ClzOpcode.t.sol). `sqrt` is fuzzed against the reference, OpenZeppelin and Solady and
///         checked exhaustively on small inputs and on every bit length.
/// @dev Memory-safety convention: the only memory these blocks touch is the scratch word at 0x00, written
///      right before a revert. On pre-Osaka chains opcode 0x1e is invalid: use `FixedPointLegacy` (no CLZ)
///      for `log2`, `log2Up` and `clz`; for `sqrt`, Solady's FixedPointMathLib.sqrt is cheaper there.
library FixedPointGolf {
    /// @notice `mulDiv` / `mulDivUp` result does not fit in 256 bits, or the denominator is zero.
    /// @dev Same selector (0xae47f702) as FixedPointRef and Solady's FixedPointMathLib.
    error FullMulDivFailed();

    // Slither triage: exact divisions by the power of two `twos` precede the Newton products on purpose (Remco
    // Bloemen's algorithm), and `^` is XOR: `(3 * d) ^ 2` is the 4-bit inverse seed, not exponentiation.
    // slither-disable-start divide-before-multiply,incorrect-exp
    /// @notice floor(x * y / d) with a 512-bit intermediate product.
    /// @dev Same arithmetic as FixedPointRef.mulDiv, minus Solidity's implicit division-by-zero checks,
    ///      branches and stack shuffling. Keeping the identical sequence of mul/mulmod/div terms is what
    ///      lets the SMT solver prove equivalence for all inputs.
    /// @param x Multiplicand.
    /// @param y Multiplier.
    /// @param d Denominator. Must be non-zero.
    /// @return z The rounded-down quotient. Reverts with `FullMulDivFailed` if it overflows.
    function mulDiv(uint256 x, uint256 y, uint256 d) internal pure returns (uint256 z) {
        // Memory-safe: only the scratch word 0x00 is written, immediately before reverting.
        assembly ("memory-safe") {
            z := mul(x, y) // Low 256 bits of the product (reused as the running low word).
            let mm := mulmod(x, y, not(0))
            let p1 := sub(sub(mm, z), lt(mm, z)) // High 256 bits.
            switch iszero(p1)
            case 1 {
                if iszero(d) {
                    mstore(0x00, 0xae47f702) // FullMulDivFailed()
                    revert(0x1c, 0x04)
                }
                z := div(z, d)
            }
            default {
                // The quotient fits in 256 bits only if d > p1; this also rules out d == 0.
                if iszero(gt(d, p1)) {
                    mstore(0x00, 0xae47f702) // FullMulDivFailed()
                    revert(0x1c, 0x04)
                }
                let r := mulmod(x, y, d)
                p1 := sub(p1, gt(r, z)) // Borrow from the high word.
                z := sub(z, r)
                let t := and(d, sub(0, d)) // Largest power of two dividing d; >= 1 since d != 0.
                d := div(d, t)
                // Inverse of the odd d modulo 2**256: 4-bit seed, then six Newton-Raphson doublings.
                let inv := xor(mul(3, d), 2)
                inv := mul(inv, sub(2, mul(d, inv)))
                inv := mul(inv, sub(2, mul(d, inv)))
                inv := mul(inv, sub(2, mul(d, inv)))
                inv := mul(inv, sub(2, mul(d, inv)))
                inv := mul(inv, sub(2, mul(d, inv)))
                inv := mul(inv, sub(2, mul(d, inv)))
                // [p1 z] / t, folded into one word, times the inverse: the exact quotient.
                z := mul(or(div(z, t), mul(p1, add(div(sub(0, t), t), 1))), inv)
            }
        }
    }

    // slither-disable-end divide-before-multiply,incorrect-exp

    /// @notice ceil(x * y / d) with a 512-bit intermediate product.
    /// @param x Multiplicand.
    /// @param y Multiplier.
    /// @param d Denominator. Must be non-zero.
    /// @return z The rounded-up quotient. Reverts with `FullMulDivFailed` if it overflows.
    function mulDivUp(uint256 x, uint256 y, uint256 d) internal pure returns (uint256 z) {
        z = mulDiv(x, y, d);
        // Memory-safe: only the scratch word 0x00 is written, immediately before reverting.
        assembly ("memory-safe") {
            // d != 0 here (mulDiv reverted otherwise). Rounding up can only overflow from 2**256 - 1.
            if mulmod(x, y, d) {
                z := add(z, 1)
                if iszero(z) {
                    mstore(0x00, 0xae47f702) // FullMulDivFailed()
                    revert(0x1c, 0x04)
                }
            }
        }
    }

    // Slither triage: Yul shifts take the shift amount first (`shl(s, 1)` is 1 << s), which Slither's incorrect-
    // shift detector reads the other way round.
    // slither-disable-start incorrect-shift
    /// @notice floor(sqrt(x)): a CLZ-derived seed plus six Newton steps.
    /// @dev With e = floor(log2 x) and s = e >> 1, the seed (x / 2**s + 2**s) / 2 is the tangent of sqrt at
    ///      4**s, an over-estimate within a factor 1.25. Newton's relative error obeys
    ///      e' = e**2 / (2 (1 + e)), so after six steps it is below 2**-200, far under one unit for any
    ///      result below 2**128; the last line removes the final +1 overshoot. x = 0 yields 0 because every
    ///      shift in the seed is >= 256 and div(0, 0) = 0 on the EVM. Five steps are not enough (odd e).
    /// @param x Radicand.
    /// @return z The integer square root.
    function sqrt(uint256 x) internal pure returns (uint256 z) {
        uint256 lz = Clz.clz(x);
        // Memory-safe: no memory access.
        assembly ("memory-safe") {
            let s := shr(1, sub(255, lz))
            z := shr(1, add(shr(s, x), shl(s, 1)))
            z := shr(1, add(z, div(x, z)))
            z := shr(1, add(z, div(x, z)))
            z := shr(1, add(z, div(x, z)))
            z := shr(1, add(z, div(x, z)))
            z := shr(1, add(z, div(x, z)))
            z := shr(1, add(z, div(x, z)))
            z := sub(z, lt(div(x, z), z))
        }
    }

    // slither-disable-end incorrect-shift

    /// @notice floor(log2(x)), i.e. the index of the most significant set bit.
    /// @dev `x | 1` has the same top bit as x for x >= 1 and maps 0 to 1, so the result is 0 for x == 0
    ///      (OpenZeppelin and Solady convention) without a branch. clz(x | 1) <= 255, so no underflow.
    /// @param x Value to inspect.
    /// @return r The bit index.
    function log2(uint256 x) internal pure returns (uint256 r) {
        unchecked {
            r = 255 - Clz.clz(x | 1);
        }
    }

    // Slither triage: Yul shifts take the shift amount first (`shl(s, 1)` is 1 << s), which Slither's incorrect-
    // shift detector reads the other way round.
    // slither-disable-start incorrect-shift
    /// @notice ceil(log2(x)).
    /// @param x Value to inspect.
    /// @return r The smallest `r` with `2**r >= x`; 0 for `x <= 1`.
    function log2Up(uint256 x) internal pure returns (uint256 r) {
        r = log2(x);
        // Memory-safe: no memory access.
        assembly ("memory-safe") {
            r := add(r, lt(shl(r, 1), x))
        }
    }

    // slither-disable-end incorrect-shift

    /// @notice Number of leading zero bits of `x`, straight from the CLZ opcode.
    /// @param x Value to inspect.
    /// @return r 256 for `x == 0`, otherwise `255 - log2(x)`.
    function clz(uint256 x) internal pure returns (uint256 r) {
        r = Clz.clz(x);
    }
}
