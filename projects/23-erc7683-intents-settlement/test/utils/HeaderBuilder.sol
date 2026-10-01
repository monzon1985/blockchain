// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {RLP} from "@openzeppelin-contracts/utils/RLP.sol";

/// @title HeaderBuilder
/// @notice Test-only encoder of Osaka-era (21 field) block headers around a chosen state root, number and timestamp.
/// @dev The layout matches what anvil and geth hash; test/fixtures checks BlockHeader parsing on a real anvil header.
library HeaderBuilder {
    /// @notice RLP of a header with the given state root, number, timestamp and parent hash; other fields are
    /// post-merge constants.
    /// @param parentHash Parent block hash.
    /// @param stateRoot State trie root.
    /// @param number Block number.
    /// @param timestamp Block timestamp.
    /// @return The header RLP.
    function encode(bytes32 parentHash, bytes32 stateRoot, uint256 number, uint256 timestamp)
        internal
        pure
        returns (bytes memory)
    {
        bytes32 emptyTrie = keccak256(hex"80");
        bytes[] memory fields = new bytes[](21);
        fields[0] = RLP.encode(parentHash);
        fields[1] = RLP.encode(keccak256(hex"c0")); // ommers hash of an empty list
        fields[2] = RLP.encode(address(0)); // coinbase
        fields[3] = RLP.encode(stateRoot);
        fields[4] = RLP.encode(emptyTrie); // transactions root
        fields[5] = RLP.encode(emptyTrie); // receipts root
        fields[6] = RLP.encode(new bytes(256)); // logs bloom
        fields[7] = RLP.encode(uint256(0)); // difficulty
        fields[8] = RLP.encode(number);
        fields[9] = RLP.encode(uint256(30_000_000)); // gas limit
        fields[10] = RLP.encode(uint256(0)); // gas used
        fields[11] = RLP.encode(timestamp);
        fields[12] = RLP.encode(bytes("")); // extra data
        fields[13] = RLP.encode(bytes32(0)); // prevRandao
        fields[14] = RLP.encode(abi.encodePacked(bytes8(0))); // nonce, 8 bytes
        fields[15] = RLP.encode(uint256(1 gwei)); // base fee
        fields[16] = RLP.encode(emptyTrie); // withdrawals root
        fields[17] = RLP.encode(uint256(0)); // blob gas used
        fields[18] = RLP.encode(uint256(0)); // excess blob gas
        fields[19] = RLP.encode(bytes32(0)); // parent beacon block root
        fields[20] = RLP.encode(sha256("")); // requests hash of no requests
        return RLP.encode(fields);
    }
}
