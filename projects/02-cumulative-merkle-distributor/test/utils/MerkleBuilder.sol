// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @notice In-EVM port of the tree layout, proof and multiproof algorithms of @openzeppelin/merkle-tree (core.ts), so
///         fuzz, invariant and gas tests can build arbitrary trees on the fly. The differential suite checks that it
///         reproduces the roots written by tree-builder (and therefore by StandardMerkleTree).
/// @dev Layout: a complete binary tree stored as an array of 2n-1 nodes, children of i at 2i+1 and 2i+2, leaf k
///      (in the given order) at index 2n-2-k. Pairs are hashed sorted, as `MerkleProof` expects.
library MerkleBuilder {
    struct MultiProof {
        bytes32[] leaves;
        uint256[] treeIndices;
        bytes32[] proof;
        bool[] proofFlags;
    }

    function hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encode(a, b)) : keccak256(abi.encode(b, a));
    }

    /// @notice StandardMerkleTree leaf for the distributor's `(address, address, uint256)` encoding.
    function leaf(address account, address token, uint256 cumulativeAmount) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(account, token, cumulativeAmount))));
    }

    function build(bytes32[] memory leaves) internal pure returns (bytes32[] memory tree) {
        uint256 n = leaves.length;
        require(n != 0, "MerkleBuilder: no leaves");
        tree = new bytes32[](2 * n - 1);
        for (uint256 i; i < n; ++i) {
            tree[tree.length - 1 - i] = leaves[i];
        }
        // Internal nodes are 0 .. n-2, filled bottom-up.
        for (uint256 i = n - 1; i > 0; --i) {
            uint256 j = i - 1;
            tree[j] = hashPair(tree[2 * j + 1], tree[2 * j + 2]);
        }
    }

    function root(bytes32[] memory leaves) internal pure returns (bytes32) {
        return build(leaves)[0];
    }

    /// @notice Tree index of the leaf that was at position `leafIndex` in the array passed to `build`.
    function treeIndexOf(uint256 leafCount, uint256 leafIndex) internal pure returns (uint256) {
        return 2 * leafCount - 2 - leafIndex;
    }

    function proof(bytes32[] memory tree, uint256 treeIndex) internal pure returns (bytes32[] memory p) {
        require(2 * treeIndex + 1 >= tree.length && treeIndex < tree.length, "MerkleBuilder: not a leaf");
        uint256 depth;
        for (uint256 i = treeIndex; i > 0; i = (i - 1) / 2) {
            ++depth;
        }
        p = new bytes32[](depth);
        uint256 k;
        for (uint256 i = treeIndex; i > 0; i = (i - 1) / 2) {
            p[k++] = tree[_sibling(i)];
        }
    }

    /// @notice Same output as `getMultiProof` in @openzeppelin/merkle-tree: leaves sorted by descending tree index.
    function multiProof(bytes32[] memory tree, uint256[] memory treeIndices)
        internal
        pure
        returns (MultiProof memory mp)
    {
        uint256 n = treeIndices.length;
        uint256[] memory sorted = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            uint256 idx = treeIndices[i];
            require(2 * idx + 1 >= tree.length && idx < tree.length, "MerkleBuilder: not a leaf");
            sorted[i] = idx;
        }
        _sortDescending(sorted);
        for (uint256 i = 1; i < n; ++i) {
            require(sorted[i] != sorted[i - 1], "MerkleBuilder: duplicated index");
        }

        // Queue with head/tail pointers; every step pops one or two entries and pushes one parent.
        uint256[] memory queue = new uint256[](n + tree.length);
        uint256 head;
        uint256 tail;
        for (uint256 i; i < n; ++i) {
            queue[tail++] = sorted[i];
        }
        bytes32[] memory proofBuf = new bytes32[](tree.length);
        bool[] memory flagBuf = new bool[](tree.length);
        uint256 proofLen;
        uint256 flagLen;
        while (head < tail && queue[head] > 0) {
            uint256 j = queue[head++];
            uint256 s = _sibling(j);
            uint256 p = (j - 1) / 2;
            if (head < tail && queue[head] == s) {
                flagBuf[flagLen++] = true;
                ++head;
            } else {
                flagBuf[flagLen++] = false;
                proofBuf[proofLen++] = tree[s];
            }
            queue[tail++] = p;
        }
        if (n == 0) proofBuf[proofLen++] = tree[0];

        // Shrink the buffers in place. Memory-safe: only lowers the stored lengths of arrays this function allocated.
        assembly ("memory-safe") {
            mstore(proofBuf, proofLen)
            mstore(flagBuf, flagLen)
        }
        mp.proof = proofBuf;
        mp.proofFlags = flagBuf;
        mp.treeIndices = sorted;
        mp.leaves = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            mp.leaves[i] = tree[sorted[i]];
        }
    }

    function _sibling(uint256 i) private pure returns (uint256) {
        return i % 2 == 1 ? i + 1 : i - 1;
    }

    function _sortDescending(uint256[] memory a) private pure {
        // Insertion sort: batches in tests are at most a few hundred entries.
        for (uint256 i = 1; i < a.length; ++i) {
            uint256 v = a[i];
            uint256 j = i;
            while (j > 0 && a[j - 1] < v) {
                a[j] = a[j - 1];
                --j;
            }
            a[j] = v;
        }
    }
}
