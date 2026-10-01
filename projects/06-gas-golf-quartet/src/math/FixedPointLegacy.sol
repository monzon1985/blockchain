// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title FixedPointLegacy
/// @author Gas Golf Quartet
/// @notice Pre-Osaka fallback for the CLZ-based parts of `FixedPointGolf`: `log2`, `log2Up`, `clz` and `sqrt`
///         without opcode 0x1e, for chains that have not activated EIP-7939. `mulDiv` needs no CLZ, so
///         `FixedPointGolf.mulDiv` is used unchanged on those chains.
/// @dev The branchless `log2` and `clz` are Solady's (MIT, FixedPointMathLib.log2 and LibBit.clz): five
///      compare-and-shift rounds and a De Bruijn-style byte lookup for the last five bits. `sqrt` is the same
///      seed-and-six-steps algorithm as FixedPointGolf.sqrt with this `clz`, so the gas difference between
///      the two isolates the CLZ saving. On `sqrt` Solady's own FixedPointMathLib.sqrt (a different
///      algorithm) is cheaper than this library before Osaka; the README's kernel table shows both.
///      `test/math/ClzOpcode.t.sol` walks this library's bytecode and asserts that opcode 0x1e never occurs.
library FixedPointLegacy {
    // Slither triage: the magic constant is shifted *by* the top bits of x on purpose (De Bruijn-style lookup).
    // slither-disable-start incorrect-shift
    /// @notice floor(log2(x)) without CLZ.
    /// @param x Value to inspect.
    /// @return r The bit index; 0 for `x == 0`.
    function log2(uint256 x) internal pure returns (uint256 r) {
        // Memory-safe: no memory access.
        assembly ("memory-safe") {
            r := shl(7, lt(0xffffffffffffffffffffffffffffffff, x))
            r := or(r, shl(6, lt(0xffffffffffffffff, shr(r, x))))
            r := or(r, shl(5, lt(0xffffffff, shr(r, x))))
            r := or(r, shl(4, lt(0xffff, shr(r, x))))
            r := or(r, shl(3, lt(0xff, shr(r, x))))
            // The shift order is deliberate: the 128-bit magic constant is shifted *by* the top bits of x,
            // a De Bruijn-style lookup that yields the index of the last five bits.
            // forgefmt: disable-next-item
            // forge-lint: disable-next-line(incorrect-shift)
            r := or(r, byte(and(0x1f, shr(shr(r, x), 0x8421084210842108cc6318c6db6d54be)),
                0x0706060506020504060203020504030106050205030304010505030400000000))
        }
    }

    // slither-disable-end incorrect-shift

    // Slither triage: Yul shifts take the shift amount first (`shl(s, 1)` is 1 << s), which Slither's incorrect-
    // shift detector reads the other way round.
    // slither-disable-start incorrect-shift
    /// @notice ceil(log2(x)) without CLZ.
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

    // Slither triage: `xor(r, ...)` is XOR, not exponentiation, and the magic constant is shifted *by* the top
    // bits of x on purpose (the same De Bruijn-style lookup as `log2`).
    // slither-disable-start incorrect-exp,incorrect-shift
    /// @notice Number of leading zero bits of `x`, emulated.
    /// @dev Solady's fused `LibBit.clz` (MIT): the five compare-and-shift rounds of `log2`, then a lookup
    ///      table whose entries are pre-XORed with 0xf8, so that `xor(r, entry)` is `255 - log2(x)` in one
    ///      step (r only has bits 3..7, all set in 0xf8). `iszero(x)` adds the missing 1 for x == 0. One
    ///      assembly block instead of a call to `log2` plus a subtraction: the cheapest pre-Osaka `clz` we
    ///      measured (README, fixed-point kernel table).
    /// @param x Value to inspect.
    /// @return r 256 for `x == 0`, otherwise `255 - log2(x)`.
    function clz(uint256 x) internal pure returns (uint256 r) {
        // Memory-safe: no memory access.
        assembly ("memory-safe") {
            r := shl(7, lt(0xffffffffffffffffffffffffffffffff, x))
            r := or(r, shl(6, lt(0xffffffffffffffff, shr(r, x))))
            r := or(r, shl(5, lt(0xffffffff, shr(r, x))))
            r := or(r, shl(4, lt(0xffff, shr(r, x))))
            r := or(r, shl(3, lt(0xff, shr(r, x))))
            // forgefmt: disable-next-item
            // forge-lint: disable-next-line(incorrect-shift)
            r := add(xor(r, byte(and(0x1f, shr(shr(r, x), 0x8421084210842108cc6318c6db6d54be)),
                0xf8f9f9faf9fdfafbf9fdfcfdfafbfcfef9fafdfafcfcfbfefafafcfbffffffff)), iszero(x))
        }
    }

    // slither-disable-end incorrect-exp,incorrect-shift

    // Slither triage: Yul shifts take the shift amount first (`shl(s, 1)` is 1 << s), which Slither's incorrect-
    // shift detector reads the other way round.
    // slither-disable-start incorrect-shift
    /// @notice floor(sqrt(x)) with the emulated leading-zero count (see FixedPointGolf.sqrt for the proof).
    /// @param x Radicand.
    /// @return z The integer square root.
    function sqrt(uint256 x) internal pure returns (uint256 z) {
        uint256 lz = clz(x);
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
}
