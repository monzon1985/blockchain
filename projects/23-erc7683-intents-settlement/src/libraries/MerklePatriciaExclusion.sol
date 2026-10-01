// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Bytes} from "@openzeppelin-contracts/utils/Bytes.sol";
import {Memory} from "@openzeppelin-contracts/utils/Memory.sol";
import {RLP} from "@openzeppelin-contracts/utils/RLP.sol";

/// @title MerklePatriciaExclusion
/// @notice Verifies that a key is ABSENT from a Merkle-Patricia trie, the complement of OpenZeppelin's TrieProof
/// (inclusion only). Used to prove "this order was not filled" against a destination storage root.
/// @dev Soundness argument: the proof is walked along the unique path of `key` from `root`, and every node is
///      authenticated by the hash reference in its parent (or embedded in an authenticated parent). The key is
///      declared absent only when that authenticated path ends before reaching it, in the last proof element:
///        (a) a branch whose child slot for the next nibble is empty (0x80), or
///        (b) a leaf or extension whose path diverges from the remaining key.
///      In both cases no node committed to by `root` can hold `key`, by collision resistance of keccak256.
///      Anything else (a leaf holding the key, a missing or unlinked node, a malformed node) returns false, so a
///      false positive requires a hash collision. The function may revert on RLP that fails to decode, which
///      callers treat as an invalid proof. Differentially tested against eth_getProof output from anvil
///      (test/fixtures) and against a reference trie builder with OpenZeppelin's inclusion verifier as oracle.
library MerklePatriciaExclusion {
    using Bytes for bytes;
    using Memory for bytes;
    using Memory for Memory.Slice;
    using RLP for Memory.Slice;

    /// @notice Root of the empty trie, keccak256(rlp("")).
    bytes32 internal constant EMPTY_TRIE_ROOT = 0x56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421;

    /// @dev How a node references a child.
    enum Link {
        Empty,
        Hash,
        Inline,
        Invalid
    }

    /// @dev Result of walking one proof element.
    enum Outcome {
        Absent, // the path provably ends here
        NotAbsent, // the key is present, or the proof is malformed
        Descend // continue with the next proof element, whose hash is now `cursor.expected`
    }

    /// @dev Traversal state carried across proof elements.
    struct Cursor {
        uint256 keyIndex;
        bytes32 expected;
    }

    /// @notice True iff `proof` shows that `key` has no value in the trie rooted at `root`.
    /// @param root Trie root.
    /// @param key Trie key (already hashed for secure tries).
    /// @param proof Trie nodes from the root along the path of `key`, as returned by eth_getProof.
    /// @return Whether absence is proven.
    function isAbsent(bytes32 root, bytes memory key, bytes[] memory proof) internal pure returns (bool) {
        if (root == EMPTY_TRIE_ROOT) return true;
        if (key.length == 0) return false;
        bytes memory nibbles = key.toNibbles();
        Cursor memory cursor = Cursor({keyIndex: 0, expected: root});
        uint256 count = proof.length;
        for (uint256 i = 0; i < count; ++i) {
            bytes memory encoded = proof[i];
            if (keccak256(encoded) != cursor.expected) return false;
            Outcome outcome = _walk(encoded.asSlice(), nibbles, cursor);
            if (outcome == Outcome.Absent) return i + 1 == count;
            if (outcome == Outcome.NotAbsent) return false;
        }
        return false;
    }

    /// @dev Walks one authenticated proof element, descending into embedded (< 32 byte) children in place.
    function _walk(Memory.Slice node, bytes memory nibbles, Cursor memory cursor) private pure returns (Outcome) {
        while (true) {
            Memory.Slice[] memory items = node.readList();
            Memory.Slice child;
            if (items.length == 17) {
                // Keys of a secure trie never end on a branch; there, absence means an empty value slot.
                if (cursor.keyIndex == nibbles.length) {
                    return items[16].readBytes().length == 0 ? Outcome.Absent : Outcome.NotAbsent;
                }
                child = items[uint8(nibbles[cursor.keyIndex])];
                ++cursor.keyIndex;
                Link link = _link(child);
                if (link == Link.Empty) return Outcome.Absent; // (a)
                if (link == Link.Invalid) return Outcome.NotAbsent;
            } else if (items.length == 2) {
                Outcome outcome = _shortNode(items[0], nibbles, cursor);
                if (outcome != Outcome.Descend) return outcome;
                child = items[1];
                Link link = _link(child);
                if (link == Link.Empty || link == Link.Invalid) return Outcome.NotAbsent;
            } else {
                return Outcome.NotAbsent;
            }
            if (_link(child) == Link.Hash) {
                cursor.expected = child.readBytes32();
                return Outcome.Descend;
            }
            // Embedded child: authenticated as part of this node, keep walking without a new proof element.
            node = child;
        }
        // Unreachable: the loop only exits through `return`.
        return Outcome.NotAbsent;
    }

    /// @dev Handles the path of a leaf or extension node. Advances `cursor.keyIndex` past an extension path.
    function _shortNode(Memory.Slice encodedPath, bytes memory nibbles, Cursor memory cursor)
        private
        pure
        returns (Outcome)
    {
        bytes memory path = encodedPath.readBytes().toNibbles();
        if (path.length == 0) return Outcome.NotAbsent;
        uint8 prefix = uint8(path[0]);
        if (prefix > 3) return Outcome.NotAbsent;
        // Hex-prefix encoding: even-length paths carry a padding nibble after the flag nibble.
        uint256 offset = prefix % 2 == 0 ? 2 : 1;
        uint256 pathLength = path.length - offset;
        uint256 keyIndex = cursor.keyIndex;
        if (pathLength > nibbles.length - keyIndex) return Outcome.Absent; // (b), path longer than the key rest
        for (uint256 j = 0; j < pathLength; ++j) {
            if (path[offset + j] != nibbles[keyIndex + j]) return Outcome.Absent; // (b)
        }
        // The key continues through this node: a leaf holds the key (present) and an extension with an empty path
        // is malformed. Neither proves absence.
        if (prefix >= 2 || pathLength == 0) return Outcome.NotAbsent;
        cursor.keyIndex = keyIndex + pathLength;
        return Outcome.Descend;
    }

    /// @dev Classifies a child reference: 0x80 (empty), a 32-byte string (hash), or a short list (embedded node).
    function _link(Memory.Slice child) private pure returns (Link) {
        uint256 length = child.length();
        // Keeps the first byte of the loaded word on purpose: it is the RLP prefix of the child.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint8 first = uint8(bytes1(child.load(0)));
        if (length == 1 && first == 0x80) return Link.Empty;
        if (length == 33 && first == 0xa0) return Link.Hash;
        if (length < 32 && first >= 0xc0) return Link.Inline;
        return Link.Invalid;
    }
}
