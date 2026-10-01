// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Vm} from "forge-std/Vm.sol";

import {FillProofLib} from "../../src/libraries/FillProofLib.sol";
import {HeaderBuilder} from "./HeaderBuilder.sol";
import {MerklePatriciaBuilder} from "./MerklePatriciaBuilder.sol";

/// @title DestStateProofs
/// @notice Builds a destination state root, header and eth_getProof-shaped proofs from the DestinationSettler's REAL
/// storage inside a single test EVM, standing in for an honest header relayer plus an archive node.
/// @dev The storage trie holds exactly the slots the settler has written (both record slots of every known order,
///      read with vm.load; zero slots are omitted as in a real trie). The settler has no other storage, so this is
///      its true storage trie. The state trie adds three unrelated accounts so account proofs have some depth.
library DestStateProofs {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice A header over the destination state and the proofs of one order's first record slot.
    /// @param header RLP-encoded header to relay.
    /// @param accountProof Proof of the settler account.
    /// @param slotProof Proof (inclusion or exclusion) of the record slot of the target order.
    struct Snapshot {
        bytes header;
        bytes[] accountProof;
        bytes[] slotProof;
    }

    /// @notice Snapshot of `settler`'s storage for `orderIds`, proving the record slot of `target`.
    /// @param settler The DestinationSettler.
    /// @param orderIds Every order id that may have been filled on `settler`.
    /// @param target Order whose record slot to prove.
    /// @param blockNumber Number of the synthetic header.
    /// @param timestamp Timestamp of the synthetic header.
    /// @return snap The header and proofs.
    function snapshot(
        address settler,
        bytes32[] memory orderIds,
        bytes32 target,
        uint256 blockNumber,
        uint256 timestamp
    ) internal view returns (Snapshot memory snap) {
        return snapshotWithParent(settler, orderIds, target, blockNumber, timestamp, bytes32(blockNumber - 1));
    }

    /// @notice `snapshot` with an explicit parent hash, so that a real ancestor can be imported through it.
    /// @param settler The DestinationSettler.
    /// @param orderIds Every order id that may have been filled on `settler`.
    /// @param target Order whose record slot to prove.
    /// @param blockNumber Number of the synthetic header.
    /// @param timestamp Timestamp of the synthetic header.
    /// @param parentHash Parent hash written into the header.
    /// @return snap The header and proofs.
    function snapshotWithParent(
        address settler,
        bytes32[] memory orderIds,
        bytes32 target,
        uint256 blockNumber,
        uint256 timestamp,
        bytes32 parentHash
    ) internal view returns (Snapshot memory snap) {
        (bytes32[] memory keys, bytes[] memory values) = _storage(settler, orderIds);
        (bytes32 storageRoot, bytes[] memory slotProof) =
            MerklePatriciaBuilder.prove(keys, values, keccak256(abi.encode(FillProofLib.fillerSlot(target))));
        (bytes32 stateRoot, bytes[] memory accountProof) = _stateTrie(settler, storageRoot);
        snap.header = HeaderBuilder.encode(parentHash, stateRoot, blockNumber, timestamp);
        snap.accountProof = accountProof;
        snap.slotProof = slotProof;
    }

    /// @notice Snapshot of a destination state in which `settler` does not exist yet (a block before its deployment):
    /// the state trie holds only the unrelated accounts, and the account proof is an EXCLUSION proof of `settler`.
    /// @param settler The DestinationSettler (absent from this state).
    /// @param blockNumber Number of the synthetic header.
    /// @param timestamp Timestamp of the synthetic header.
    /// @return snap The header, the account exclusion proof and an empty slot proof.
    function snapshotBeforeDeployment(address settler, uint256 blockNumber, uint256 timestamp)
        internal
        pure
        returns (Snapshot memory snap)
    {
        bytes32[] memory keys = new bytes32[](3);
        bytes[] memory values = new bytes[](3);
        for (uint256 i = 0; i < 3; ++i) {
            keys[i] = keccak256(abi.encodePacked(address(uint160(0xA001 + i))));
            values[i] = MerklePatriciaBuilder.accountLeaf(i + 1, (i + 1) * 1 ether, keccak256(hex"80"), keccak256(""));
        }
        (bytes32 stateRoot, bytes[] memory accountProof) =
            MerklePatriciaBuilder.prove(keys, values, keccak256(abi.encodePacked(settler)));
        snap.header = HeaderBuilder.encode(bytes32(blockNumber - 1), stateRoot, blockNumber, timestamp);
        snap.accountProof = accountProof;
        snap.slotProof = new bytes[](0);
    }

    function _storage(address settler, bytes32[] memory orderIds)
        private
        view
        returns (bytes32[] memory keys, bytes[] memory values)
    {
        uint256 count = 0;
        bytes32[] memory allKeys = new bytes32[](orderIds.length * 2);
        bytes[] memory allValues = new bytes[](orderIds.length * 2);
        for (uint256 i = 0; i < orderIds.length; ++i) {
            bytes32 slot = FillProofLib.fillerSlot(orderIds[i]);
            for (uint256 j = 0; j < 2; ++j) {
                bytes32 key = bytes32(uint256(slot) + j);
                uint256 value = uint256(VM.load(settler, key));
                if (value == 0) continue;
                bytes32 hashed = keccak256(abi.encode(key));
                bool duplicate = false;
                for (uint256 k = 0; k < count; ++k) {
                    if (allKeys[k] == hashed) duplicate = true;
                }
                if (duplicate) continue;
                allKeys[count] = hashed;
                allValues[count] = MerklePatriciaBuilder.storageLeaf(value);
                ++count;
            }
        }
        keys = new bytes32[](count);
        values = new bytes[](count);
        for (uint256 i = 0; i < count; ++i) {
            keys[i] = allKeys[i];
            values[i] = allValues[i];
        }
    }

    function _stateTrie(address settler, bytes32 storageRoot)
        private
        view
        returns (bytes32 stateRoot, bytes[] memory accountProof)
    {
        bytes32[] memory keys = new bytes32[](4);
        bytes[] memory values = new bytes[](4);
        keys[0] = keccak256(abi.encodePacked(settler));
        values[0] = MerklePatriciaBuilder.accountLeaf(1, 0, storageRoot, keccak256(settler.code));
        for (uint256 i = 1; i < 4; ++i) {
            keys[i] = keccak256(abi.encodePacked(address(uint160(0xA000 + i))));
            values[i] = MerklePatriciaBuilder.accountLeaf(i, i * 1 ether, keccak256(hex"80"), keccak256(""));
        }
        return MerklePatriciaBuilder.prove(keys, values, keys[0]);
    }
}
