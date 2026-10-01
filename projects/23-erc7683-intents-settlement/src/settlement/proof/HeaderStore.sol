// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {AccessManaged} from "@openzeppelin-contracts/access/manager/AccessManaged.sol";
import {BlockHeader} from "@openzeppelin-contracts/utils/BlockHeader.sol";
import {Memory} from "@openzeppelin-contracts/utils/Memory.sol";
import {SafeCast} from "@openzeppelin-contracts/utils/math/SafeCast.sol";

/// @title HeaderStore
/// @notice Origin-chain registry of destination-chain block headers, used by the proof-based settlement modes.
/// @dev Trust model: a permissioned relayer vouches that a header is canonical and final on `chainId`; this is the
///      single trusted input of settlement mode 3. Everything after the header (state root, account, storage slot)
///      is verified on-chain. Two properties narrow what the relayer can do:
///        - Stored headers are immutable. A conflicting header for the same height reverts instead of overwriting,
///          so a relayer cannot rewrite history after proofs were accepted against it.
///        - Ancestors of a stored header can be imported by anyone through the parentHash chain, so the relayer only
///          needs to vouch for occasional anchors, not for every block a prover wants.
///      Headers are parsed with OpenZeppelin's BlockHeader, which works for every fork from Frontier to Osaka.
contract HeaderStore is AccessManaged {
    using BlockHeader for Memory.Slice[];

    /// @notice What the store keeps from a header.
    /// @param blockHash keccak256 of the header RLP.
    /// @param stateRoot State trie root.
    /// @param timestamp Block timestamp.
    struct StoredHeader {
        bytes32 blockHash;
        bytes32 stateRoot;
        uint64 timestamp;
    }

    /// @dev Headers by chain id and block number.
    mapping(uint256 chainId => mapping(uint256 blockNumber => StoredHeader)) internal _headers;

    /// @notice Emitted when a header is stored.
    /// @param chainId Chain the header belongs to.
    /// @param blockNumber Block number.
    /// @param blockHash Block hash.
    /// @param stateRoot State root.
    /// @param timestamp Block timestamp.
    /// @param viaAncestry True when imported permissionlessly as the parent of a stored header.
    event HeaderStored(
        uint256 indexed chainId,
        uint256 indexed blockNumber,
        bytes32 blockHash,
        bytes32 stateRoot,
        uint64 timestamp,
        bool viaAncestry
    );

    /// @notice A different header is already stored at this height.
    /// @param chainId The chain.
    /// @param blockNumber The height.
    /// @param stored Hash already stored.
    /// @param submitted Hash submitted.
    error HeaderConflict(uint256 chainId, uint256 blockNumber, bytes32 stored, bytes32 submitted);
    /// @notice No header is stored at this height.
    /// @param chainId The chain.
    /// @param blockNumber The height.
    error UnknownHeader(uint256 chainId, uint256 blockNumber);
    /// @notice The child header RLP does not match the stored child.
    /// @param expected Stored hash of the child.
    /// @param actual keccak256 of the submitted child RLP.
    error ChildHashMismatch(bytes32 expected, bytes32 actual);
    /// @notice The parent header RLP is not the child's parent.
    /// @param expected The child's parentHash.
    /// @param actual keccak256 of the submitted parent RLP.
    error ParentHashMismatch(bytes32 expected, bytes32 actual);
    /// @notice Headers of the local chain are not accepted (use BLOCKHASH / EIP-2935 instead).
    error LocalChain();

    /// @param authority AccessManager that grants the relayer role for `submitHeader`.
    constructor(address authority) AccessManaged(authority) {}

    /// @notice Stores a header of `chainId`. Restricted to the header relayer role.
    /// @dev Idempotent for the same header; reverts on a conflicting one.
    /// @param chainId Chain the header belongs to.
    /// @param headerRlp RLP-encoded block header.
    function submitHeader(uint256 chainId, bytes calldata headerRlp) external restricted {
        _store(chainId, headerRlp, false);
    }

    /// @notice Imports the parent of a stored header without trusting the caller: the parent is authenticated by the
    /// child's parentHash.
    /// @param chainId Chain of both headers.
    /// @param childNumber Height of the stored child.
    /// @param childRlp RLP of the stored child.
    /// @param parentRlp RLP of the child's parent.
    function submitAncestor(uint256 chainId, uint256 childNumber, bytes calldata childRlp, bytes calldata parentRlp)
        external
    {
        bytes32 childHash = _headers[chainId][childNumber].blockHash;
        require(childHash != bytes32(0), UnknownHeader(chainId, childNumber));
        bytes32 submittedChild = keccak256(childRlp);
        require(submittedChild == childHash, ChildHashMismatch(childHash, submittedChild));
        bytes32 parentHash = BlockHeader.getParentHash(childRlp);
        bytes32 submittedParent = keccak256(parentRlp);
        require(submittedParent == parentHash, ParentHashMismatch(parentHash, submittedParent));
        _store(chainId, parentRlp, true);
    }

    /// @notice Stored header of `chainId` at `blockNumber` (all zero if unknown).
    /// @param chainId The chain.
    /// @param blockNumber The height.
    /// @return The stored header.
    function header(uint256 chainId, uint256 blockNumber) external view returns (StoredHeader memory) {
        return _headers[chainId][blockNumber];
    }

    /// @notice State root and timestamp of a stored header; reverts if unknown.
    /// @param chainId The chain.
    /// @param blockNumber The height.
    /// @return stateRoot The state root.
    /// @return timestamp The block timestamp.
    function stateRootAt(uint256 chainId, uint256 blockNumber)
        external
        view
        returns (bytes32 stateRoot, uint64 timestamp)
    {
        StoredHeader storage stored = _headers[chainId][blockNumber];
        require(stored.blockHash != bytes32(0), UnknownHeader(chainId, blockNumber));
        return (stored.stateRoot, stored.timestamp);
    }

    /// @dev Parses and stores a header, rejecting conflicts.
    function _store(uint256 chainId, bytes calldata headerRlp, bool viaAncestry) internal {
        require(chainId != block.chainid, LocalChain());
        Memory.Slice[] memory fields = BlockHeader.parseHeader(headerRlp);
        bytes32 blockHash = keccak256(headerRlp);
        uint256 blockNumber = fields.getNumber();
        StoredHeader storage stored = _headers[chainId][blockNumber];
        bytes32 existing = stored.blockHash;
        if (existing == blockHash) return;
        require(existing == bytes32(0), HeaderConflict(chainId, blockNumber, existing, blockHash));
        bytes32 stateRoot = fields.getStateRoot();
        uint64 timestamp = SafeCast.toUint64(fields.getTimestamp());
        stored.blockHash = blockHash;
        stored.stateRoot = stateRoot;
        stored.timestamp = timestamp;
        // Reached from `submitHeader`, whose only prior external call is AccessManager.canCall (`restricted`).
        // forge-lint: disable-next-line(reentrancy-events)
        emit HeaderStored(chainId, blockNumber, blockHash, stateRoot, timestamp, viaAncestry);
    }
}
