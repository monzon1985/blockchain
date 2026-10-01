// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Memory} from "@openzeppelin-contracts/utils/Memory.sol";
import {RLP} from "@openzeppelin-contracts/utils/RLP.sol";
import {TrieProof} from "@openzeppelin-contracts/utils/cryptography/TrieProof.sol";

import {MerklePatriciaExclusion} from "./MerklePatriciaExclusion.sol";

/// @title FillProofLib
/// @notice Reads a DestinationSettler FillRecord out of a destination-chain state root (eth_getProof format).
/// @dev state root --account proof--> account [nonce, balance, storageRoot, codeHash]
///                 --storage proof--> slot keccak256(abi.encode(orderId, 0)) = filledAt << 160 | filler
///      Inclusion is verified with OpenZeppelin's TrieProof, absence with MerklePatriciaExclusion. Only the first
///      record slot is proven: `orderId` commits to `fillHash` (orderId = H(originChainId, originSettler, fillHash)),
///      and the OriginSettler re-checks any claimed fillHash against the order id, so proving the second slot would
///      add a storage proof without adding security.
library FillProofLib {
    using RLP for Memory.Slice;

    /// @notice The proven account is not a 4-item RLP list.
    error MalformedAccount();
    /// @notice The storage proof proves neither inclusion nor absence of the slot.
    /// @param slot The storage slot.
    error InvalidSlotProof(bytes32 slot);

    /// @notice Slot of `_fills` in DestinationSettler.
    uint256 internal constant FILLS_SLOT = 0;

    /// @notice First storage slot of the FillRecord of `orderId` (filledAt | filler).
    /// @param orderId The order id.
    /// @return The storage slot.
    function fillerSlot(bytes32 orderId) internal pure returns (bytes32) {
        return keccak256(abi.encode(orderId, FILLS_SLOT));
    }

    /// @notice Splits the packed first slot of a FillRecord.
    /// @param packed Raw slot value.
    /// @return filler Repayment address.
    /// @return filledAt Fill timestamp.
    function unpack(uint256 packed) internal pure returns (address filler, uint64 filledAt) {
        // Truncation is the point: bits 0..159 hold the filler and bits 160..223 the timestamp.
        // forge-lint: disable-next-line(unsafe-typecast)
        filler = address(uint160(packed));
        // forge-lint: disable-next-line(unsafe-typecast)
        filledAt = uint64(packed >> 160);
    }

    /// @notice Packs a FillRecord's first slot, the inverse of `unpack`.
    /// @param filler Repayment address.
    /// @param filledAt Fill timestamp.
    /// @return The packed slot value.
    function pack(address filler, uint64 filledAt) internal pure returns (uint256) {
        return (uint256(filledAt) << 160) | uint256(uint160(filler));
    }

    /// @notice Storage root of `account` under `stateRoot`; reverts unless `accountProof` proves the account.
    /// @param stateRoot State root of a trusted header.
    /// @param account The account.
    /// @param accountProof eth_getProof `accountProof`.
    /// @return The account's storage root.
    function storageRoot(bytes32 stateRoot, address account, bytes[] memory accountProof)
        internal
        pure
        returns (bytes32)
    {
        bytes memory accountRlp =
            TrieProof.traverse(stateRoot, abi.encodePacked(keccak256(abi.encodePacked(account))), accountProof);
        Memory.Slice[] memory fields = RLP.decodeList(accountRlp);
        require(fields.length == 4, MalformedAccount());
        return fields[2].readBytes32();
    }

    /// @notice Storage root of `account` under `stateRoot`, or the empty-trie root when `accountProof` proves that
    /// the account does not exist there (for example at a block before it was deployed); reverts if it proves
    /// neither.
    /// @dev Only for disproving a record: an account that does not exist has no storage, so every slot is empty.
    ///      The state trie is a secure trie keyed by keccak256(address), like storage tries, so the same
    ///      MerklePatriciaExclusion walker proves the account's absence.
    /// @param stateRoot State root of a trusted header.
    /// @param account The account.
    /// @param accountProof eth_getProof `accountProof` (inclusion or exclusion).
    /// @return The account's storage root, or `MerklePatriciaExclusion.EMPTY_TRIE_ROOT` if the account is absent.
    function storageRootOrEmpty(bytes32 stateRoot, address account, bytes[] memory accountProof)
        internal
        pure
        returns (bytes32)
    {
        bytes memory key = abi.encodePacked(keccak256(abi.encodePacked(account)));
        if (MerklePatriciaExclusion.isAbsent(stateRoot, key, accountProof)) {
            return MerklePatriciaExclusion.EMPTY_TRIE_ROOT;
        }
        return storageRoot(stateRoot, account, accountProof);
    }

    /// @notice Whether `proof` is what eth_getProof returns for a key of an empty trie: no node at all, or the single
    /// empty node `0x80` (whose hash is the empty-trie root).
    /// @param proof A storage proof.
    /// @return True for an empty-trie proof.
    function isEmptyTrieProof(bytes[] calldata proof) internal pure returns (bool) {
        return
            proof.length == 0 || (proof.length == 1 && keccak256(proof[0]) == MerklePatriciaExclusion.EMPTY_TRIE_ROOT);
    }

    /// @notice Value of a slot that must exist; reverts unless `proof` proves inclusion.
    /// @param root Storage root.
    /// @param slot Storage slot.
    /// @param proof eth_getProof `storageProof[i].proof`.
    /// @return The slot value.
    function includedSlot(bytes32 root, bytes32 slot, bytes[] memory proof) internal pure returns (uint256) {
        return RLP.decodeUint256(TrieProof.traverse(root, _key(slot), proof));
    }

    /// @notice Value of a slot, zero when `proof` proves it absent; reverts if it proves neither.
    /// @param root Storage root.
    /// @param slot Storage slot.
    /// @param proof eth_getProof `storageProof[i].proof`.
    /// @return value The slot value (0 if absent).
    function slotValue(bytes32 root, bytes32 slot, bytes[] memory proof) internal pure returns (uint256 value) {
        bytes memory key = _key(slot);
        // Absence first: OpenZeppelin's traversal reverts, rather than erroring, on an exclusion proof.
        if (MerklePatriciaExclusion.isAbsent(root, key, proof)) return 0;
        (bytes memory raw, TrieProof.ProofError err) = TrieProof.tryTraverse(root, key, proof);
        require(err == TrieProof.ProofError.NO_ERROR, InvalidSlotProof(slot));
        return RLP.decodeUint256(raw);
    }

    /// @dev Secure-trie key of a storage slot.
    function _key(bytes32 slot) private pure returns (bytes memory) {
        return abi.encodePacked(keccak256(abi.encode(slot)));
    }
}
