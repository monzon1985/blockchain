// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Hashes} from "@openzeppelin-contracts/utils/cryptography/Hashes.sol";

/// @title SparseMerkle
/// @notice Verification for the rollup's 256-level keccak sparse Merkle tree (SMT).
/// @dev Conventions (mirrored by `crates/vm/src/smt.rs`):
///      - the key is the path: bit `i` of the key selects the side at level `i` (level 0 = leaves);
///      - leaf(k, v) = v == 0 ? 0 : keccak256(abi.encode(k, v));
///      - node(l, r) = (l == 0 && r == 0) ? 0 : keccak256(abi.encode(l, r)).
///      Empty subtrees therefore hash to zero at every height, which makes proofs compressible: only non-zero
///      siblings are shipped and a bitmap says where they go.
library SparseMerkle {
    /// @notice Tree height (one level per key bit).
    uint256 internal constant DEPTH = 256;

    /// @notice The proof did not consume exactly the siblings it supplied.
    /// @param supplied Number of siblings in the proof.
    /// @param consumed Number of siblings the bitmap asked for.
    error SmtProofLengthMismatch(uint256 supplied, uint256 consumed);

    /// @notice Hash of a leaf holding `value` at `key` (zero for an empty leaf).
    /// @param key Leaf key (also its path).
    /// @param value Stored value; zero means absent.
    /// @return The leaf hash.
    function leafHash(bytes32 key, bytes32 value) internal pure returns (bytes32) {
        if (value == bytes32(0)) return bytes32(0);
        return Hashes.efficientKeccak256(key, value);
    }

    /// @notice Hash of an internal node; two empty children give an empty (zero) node.
    /// @param left Left child hash.
    /// @param right Right child hash.
    /// @return The node hash.
    function nodeHash(bytes32 left, bytes32 right) internal pure returns (bytes32) {
        if (left == bytes32(0) && right == bytes32(0)) return bytes32(0);
        return Hashes.efficientKeccak256(left, right);
    }

    /// @notice Recomputes the root implied by `value` stored at `key` and a compressed sibling path.
    /// @param key Leaf key.
    /// @param value Leaf value (zero proves absence).
    /// @param bitmap Bit `i` set = the sibling at level `i` is taken from `siblings`, otherwise it is zero.
    /// @param siblings Non-zero siblings, leaf level first.
    /// @return node The implied root.
    function computeRoot(bytes32 key, bytes32 value, uint256 bitmap, bytes32[] calldata siblings)
        internal
        pure
        returns (bytes32 node)
    {
        node = leafHash(key, value);
        uint256 path = uint256(key);
        uint256 used = 0;
        uint256 supplied = siblings.length;
        for (uint256 level = 0; level < DEPTH; ++level) {
            bytes32 sibling = bytes32(0);
            if ((bitmap >> level) & 1 == 1) {
                // A short proof keeps counting so the single length check below reports the mismatch.
                if (used < supplied) sibling = siblings[used];
                ++used;
            }
            node = (path >> level) & 1 == 1 ? nodeHash(sibling, node) : nodeHash(node, sibling);
        }
        if (used != supplied) revert SmtProofLengthMismatch(supplied, used);
    }
}
