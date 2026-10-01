// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @notice Independent Solidity port of OpenZeppelin's JavaScript `StandardMerkleTree` (sorted leaves,
///         array-backed complete binary tree, commutative pair hashing) for `(address, uint256)` leaves.
/// @dev Used to build trees inside tests and as the differential reference for the Node builder's output.
library StandardMerkleTree {
    function leafHash(address account, uint256 amount) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(account, amount))));
    }

    function hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    /// @dev Returns the tree array (root at index 0) and, for each input leaf, its index in the tree.
    function build(address[] memory accounts, uint256[] memory amounts)
        internal
        pure
        returns (bytes32[] memory tree, uint256[] memory treeIndexOf)
    {
        uint256 n = accounts.length;
        require(n > 0 && n == amounts.length, "merkle: bad input");
        bytes32[] memory hashes = new bytes32[](n);
        uint256[] memory order = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            hashes[i] = leafHash(accounts[i], amounts[i]);
            order[i] = i;
        }
        // Insertion sort of leaf indices by hash (test-sized inputs).
        for (uint256 i = 1; i < n; ++i) {
            uint256 key = order[i];
            uint256 j = i;
            while (j > 0 && hashes[order[j - 1]] > hashes[key]) {
                order[j] = order[j - 1];
                --j;
            }
            order[j] = key;
        }
        tree = new bytes32[](2 * n - 1);
        treeIndexOf = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            uint256 position = tree.length - 1 - i;
            tree[position] = hashes[order[i]];
            treeIndexOf[order[i]] = position;
        }
        for (uint256 k = tree.length - n; k > 0; --k) {
            uint256 i = k - 1;
            tree[i] = hashPair(tree[2 * i + 1], tree[2 * i + 2]);
        }
    }

    function proof(bytes32[] memory tree, uint256 index) internal pure returns (bytes32[] memory out) {
        uint256 depth;
        for (uint256 i = index; i > 0; i = (i - 1) / 2) {
            ++depth;
        }
        out = new bytes32[](depth);
        uint256 k;
        for (uint256 i = index; i > 0; i = (i - 1) / 2) {
            out[k++] = tree[i % 2 == 1 ? i + 1 : i - 1];
        }
    }
}
