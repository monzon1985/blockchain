// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title Clz
/// @notice Count-leading-zeros through the EIP-7939 `CLZ` opcode (0x1e), live since the Osaka hard fork
///         (Fusaka, December 2025).
/// @dev This is the only file in the repository that emits opcode 0x1e. It is imported through the
///      `clz/` remapping so the halmos profile can substitute `test/halmos/clz-model/Clz.sol`: halmos
///      0.3.3 does not implement 0x1e, and the model lets the rest of the golfed kernel be proven.
///      `test/math/ClzOpcode.t.sol` checks this opcode against that model on every bit length.
library Clz {
    /// @notice Number of leading zero bits of `x`.
    /// @param x Value to inspect.
    /// @return r 256 for `x == 0`, otherwise `255 - floor(log2(x))`.
    function clz(uint256 x) internal pure returns (uint256 r) {
        // Memory-safe: no memory access.
        assembly ("memory-safe") {
            r := clz(x)
        }
    }
}
