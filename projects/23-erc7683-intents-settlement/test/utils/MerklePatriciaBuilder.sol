// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {RLP} from "@openzeppelin-contracts/utils/RLP.sol";

/// @title MerklePatriciaBuilder
/// @notice Test-only reference implementation of the Ethereum Merkle-Patricia trie: builds the root of a set of
/// (key, value) pairs and the eth_getProof-style proof of any key, present or absent.
/// @dev Straightforward recursive construction (leaf / extension / branch, hex-prefix paths, nodes shorter than 32
///      bytes embedded in their parent). It is validated against anvil's trie in test/fixtures (the builder must
///      reproduce the storage root anvil reports), which is what lets the invariant suites trust the proofs it
///      produces for storage that only exists inside a single test EVM.
library MerklePatriciaBuilder {
    /// @dev Nodes on the proof path, collected children-first.
    struct Path {
        bytes[] nodes;
        uint256 length;
    }

    /// @notice Root of the trie holding `keys[i] => values[i]` (keys are raw trie keys, e.g. keccak256(slot)).
    /// @param keys Trie keys, all distinct and of equal length.
    /// @param values Leaf values (already RLP-encoded payloads, e.g. rlp(uint256)).
    /// @return The trie root.
    function root(bytes32[] memory keys, bytes[] memory values) internal pure returns (bytes32) {
        (bytes32 trieRoot,) = prove(keys, values, bytes32(0));
        return trieRoot;
    }

    /// @notice Root of the trie and the proof for `target` (inclusion if present, exclusion otherwise).
    /// @param keys Trie keys, all distinct.
    /// @param values Leaf values.
    /// @param target Key to prove.
    /// @return trieRoot The trie root.
    /// @return proof Root-first list of the hash-referenced nodes on the path of `target`.
    function prove(bytes32[] memory keys, bytes[] memory values, bytes32 target)
        internal
        pure
        returns (bytes32 trieRoot, bytes[] memory proof)
    {
        require(keys.length == values.length, "length mismatch");
        if (keys.length == 0) return (keccak256(hex"80"), new bytes[](0));
        bytes[] memory nibbleKeys = new bytes[](keys.length);
        uint256[] memory all = new uint256[](keys.length);
        for (uint256 i = 0; i < keys.length; ++i) {
            nibbleKeys[i] = _nibbles(keys[i]);
            all[i] = i;
        }
        Path memory path = Path({nodes: new bytes[](80), length: 0});
        bytes memory rootNode = _node(nibbleKeys, values, all, 0, _nibbles(target), true, path);
        trieRoot = keccak256(rootNode);

        // Children were collected first; reverse, and drop embedded nodes (they live inside their parent).
        uint256 kept = 0;
        for (uint256 i = 0; i < path.length; ++i) {
            if (path.nodes[i].length >= 32 || i + 1 == path.length) ++kept;
        }
        proof = new bytes[](kept);
        uint256 pos = 0;
        for (uint256 i = path.length; i > 0; --i) {
            bytes memory node = path.nodes[i - 1];
            if (node.length >= 32 || i == path.length) proof[pos++] = node;
        }
    }

    /// @notice RLP of a storage value as stored in a storage trie leaf.
    /// @param value Slot value (non-zero).
    /// @return The leaf payload.
    function storageLeaf(uint256 value) internal pure returns (bytes memory) {
        return RLP.encode(value);
    }

    /// @notice RLP of an account as stored in the state trie.
    /// @param nonce Account nonce.
    /// @param balance Account balance.
    /// @param storageRoot Storage trie root.
    /// @param codeHash keccak256 of the code.
    /// @return The leaf payload.
    function accountLeaf(uint256 nonce, uint256 balance, bytes32 storageRoot, bytes32 codeHash)
        internal
        pure
        returns (bytes memory)
    {
        bytes[] memory fields = new bytes[](4);
        fields[0] = RLP.encode(nonce);
        fields[1] = RLP.encode(balance);
        fields[2] = RLP.encode(storageRoot);
        fields[3] = RLP.encode(codeHash);
        return RLP.encode(fields);
    }

    function _node(
        bytes[] memory keys,
        bytes[] memory values,
        uint256[] memory idx,
        uint256 depth,
        bytes memory target,
        bool onPath,
        Path memory path
    ) private pure returns (bytes memory encoded) {
        if (idx.length == 1) {
            bytes[] memory leaf = new bytes[](2);
            leaf[0] = RLP.encode(_hexPrefix(keys[idx[0]], depth, keys[idx[0]].length, true));
            leaf[1] = RLP.encode(values[idx[0]]);
            encoded = RLP.encode(leaf);
        } else {
            uint256 common = _commonPrefix(keys, idx, depth);
            if (common > 0) {
                bytes memory first = keys[idx[0]];
                bool childOnPath = onPath && _matches(target, first, depth, common);
                bytes memory child = _node(keys, values, idx, depth + common, target, childOnPath, path);
                bytes[] memory ext = new bytes[](2);
                ext[0] = RLP.encode(_hexPrefix(first, depth, depth + common, false));
                ext[1] = _reference(child);
                encoded = RLP.encode(ext);
            } else {
                bytes[] memory items = new bytes[](17);
                for (uint256 n = 0; n < 16; ++n) {
                    uint256[] memory sub = _select(keys, idx, depth, n);
                    if (sub.length == 0) {
                        items[n] = hex"80";
                    } else {
                        bool childOnPath = onPath && uint8(target[depth]) == n;
                        items[n] = _reference(_node(keys, values, sub, depth + 1, target, childOnPath, path));
                    }
                }
                items[16] = hex"80";
                encoded = RLP.encode(items);
            }
        }
        if (onPath) path.nodes[path.length++] = encoded;
    }

    function _reference(bytes memory node) private pure returns (bytes memory) {
        return node.length < 32 ? node : RLP.encode(keccak256(node));
    }

    function _select(bytes[] memory keys, uint256[] memory idx, uint256 depth, uint256 nibble)
        private
        pure
        returns (uint256[] memory sub)
    {
        uint256 count = 0;
        for (uint256 i = 0; i < idx.length; ++i) {
            if (uint8(keys[idx[i]][depth]) == nibble) ++count;
        }
        sub = new uint256[](count);
        uint256 pos = 0;
        for (uint256 i = 0; i < idx.length; ++i) {
            if (uint8(keys[idx[i]][depth]) == nibble) sub[pos++] = idx[i];
        }
    }

    function _commonPrefix(bytes[] memory keys, uint256[] memory idx, uint256 depth) private pure returns (uint256) {
        bytes memory first = keys[idx[0]];
        uint256 length = 0;
        while (depth + length < first.length) {
            bytes1 nibble = first[depth + length];
            for (uint256 i = 1; i < idx.length; ++i) {
                if (keys[idx[i]][depth + length] != nibble) return length;
            }
            ++length;
        }
        return length;
    }

    function _matches(bytes memory a, bytes memory b, uint256 from, uint256 length) private pure returns (bool) {
        for (uint256 i = 0; i < length; ++i) {
            if (a[from + i] != b[from + i]) return false;
        }
        return true;
    }

    function _hexPrefix(bytes memory nibbles, uint256 from, uint256 to, bool leaf)
        private
        pure
        returns (bytes memory out)
    {
        uint256 length = to - from;
        uint8 flag = leaf ? 2 : 0;
        bool odd = length % 2 == 1;
        out = new bytes(length / 2 + 1);
        uint256 cursor = from;
        if (odd) {
            out[0] = bytes1(((flag + 1) << 4) | uint8(nibbles[cursor++]));
        } else {
            out[0] = bytes1(flag << 4);
        }
        for (uint256 i = 1; i < out.length; ++i) {
            out[i] = bytes1((uint8(nibbles[cursor]) << 4) | uint8(nibbles[cursor + 1]));
            cursor += 2;
        }
    }

    function _nibbles(bytes32 key) private pure returns (bytes memory out) {
        out = new bytes(64);
        for (uint256 i = 0; i < 32; ++i) {
            out[2 * i] = bytes1(uint8(key[i]) >> 4);
            out[2 * i + 1] = bytes1(uint8(key[i]) & 0x0f);
        }
    }
}
