// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title Clz (model)
/// @notice Plain-EVM model of the EIP-7939 CLZ opcode, substituted for src/math/clz/Clz.sol by the `clz/`
///         remapping of the halmos profile only (halmos 0.3.3 does not implement opcode 0x1e).
/// @dev Branchless normalisation: shift x left until its top bit is set, counting the shift. This is a
///      different algorithm from FixedPointRef.log2 (right-shift binary search), so the halmos proofs that
///      use it are not circular. test/math/ClzOpcode.t.sol checks this model against the real opcode on
///      every bit length and under fuzzing.
library Clz {
    /// @notice Number of leading zero bits of `x`; 256 for zero.
    function clz(uint256 x) internal pure returns (uint256 r) {
        // Memory-safe: no memory access.
        assembly ("memory-safe") {
            let isZero := iszero(x)
            let t := shl(7, iszero(shr(128, x)))
            r := t
            x := shl(t, x)
            t := shl(6, iszero(shr(192, x)))
            r := or(r, t)
            x := shl(t, x)
            t := shl(5, iszero(shr(224, x)))
            r := or(r, t)
            x := shl(t, x)
            t := shl(4, iszero(shr(240, x)))
            r := or(r, t)
            x := shl(t, x)
            t := shl(3, iszero(shr(248, x)))
            r := or(r, t)
            x := shl(t, x)
            t := shl(2, iszero(shr(252, x)))
            r := or(r, t)
            x := shl(t, x)
            t := shl(1, iszero(shr(254, x)))
            r := or(r, t)
            x := shl(t, x)
            // After seven rounds r <= 254 and the top two bits hold the leading one (or x is zero).
            r := add(r, iszero(shr(255, x)))
            // For x == 0 every round fired (r == 255): one more zero makes 256.
            r := add(r, isZero)
        }
    }
}
