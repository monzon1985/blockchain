// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IForcedInclusionQueue} from "./interfaces/IForcedInclusionQueue.sol";
import {Record} from "./lib/Types.sol";
import {RollupSpec} from "./lib/RollupSpec.sol";

/// @title ForcedInclusionQueue
/// @notice L1 -> L2 message queue with inclusion deadlines (Stage-1 style censorship resistance).
/// @dev Messages are chained into an accumulator `acc_i = keccak256(acc_{i-1}, keccak256(abi.encode(record_i)))`, so
///      the BatchInbox can check any contiguous range the sequencer claims to include with two storage reads.
///      Enqueue block numbers are non-decreasing, which lets the inbox enforce "no overdue message is left out" by
///      looking only at the first message a batch leaves out.
contract ForcedInclusionQueue is IForcedInclusionQueue {
    /// @notice Bridge allowed to enqueue deposits.
    address public immutable BRIDGE;

    /// @notice Number of L1 blocks the sequencer has to include a message voluntarily.
    uint64 public immutable INCLUSION_WINDOW;

    /// @dev Queue entry: accumulator up to and including this message, and the block it was enqueued in.
    struct Entry {
        bytes32 accumulator;
        uint64 enqueuedAt;
    }

    /// @notice All messages ever enqueued, in order.
    Entry[] private _entries;

    /// @param bridge The deposit bridge (may be a precomputed address; checked by the deployment script).
    /// @param inclusionWindow Blocks after which a message becomes overdue.
    constructor(address bridge, uint64 inclusionWindow) {
        require(bridge != address(0) && inclusionWindow != 0, ZeroParameter());
        BRIDGE = bridge;
        INCLUSION_WINDOW = inclusionWindow;
    }

    /// @inheritdoc IForcedInclusionQueue
    function enqueueDeposit(address from, address to, uint256 amount) external returns (uint256 index) {
        require(msg.sender == BRIDGE, OnlyBridge(msg.sender));
        return _enqueue(RollupSpec.KIND_DEPOSIT, from, uint256(uint160(to)), amount);
    }

    /// @inheritdoc IForcedInclusionQueue
    function forceTransfer(address to, uint256 amount) external returns (uint256 index) {
        return _enqueue(RollupSpec.KIND_FORCED_TRANSFER, msg.sender, uint256(uint160(to)), amount);
    }

    /// @inheritdoc IForcedInclusionQueue
    function forceWithdrawal(address recipient, uint256 amount) external returns (uint256 index) {
        return _enqueue(RollupSpec.KIND_FORCED_WITHDRAWAL, msg.sender, uint256(uint160(recipient)), amount);
    }

    /// @inheritdoc IForcedInclusionQueue
    function length() external view returns (uint256) {
        return _entries.length;
    }

    /// @inheritdoc IForcedInclusionQueue
    function accumulatorBefore(uint256 index) external view returns (bytes32) {
        uint256 len = _entries.length;
        require(index <= len, IndexOutOfRange(index, len));
        return index == 0 ? bytes32(0) : _entries[index - 1].accumulator;
    }

    /// @inheritdoc IForcedInclusionQueue
    function enqueuedAt(uint256 index) external view returns (uint64) {
        return _entry(index).enqueuedAt;
    }

    /// @inheritdoc IForcedInclusionQueue
    function deadline(uint256 index) public view returns (uint256) {
        return uint256(_entry(index).enqueuedAt) + INCLUSION_WINDOW;
    }

    /// @inheritdoc IForcedInclusionQueue
    function isOverdue(uint256 index) external view returns (bool) {
        return block.number > deadline(index);
    }

    /// @inheritdoc IForcedInclusionQueue
    function recordHash(Record calldata record) external pure returns (bytes32) {
        return keccak256(abi.encode(record));
    }

    function _entry(uint256 index) private view returns (Entry storage) {
        uint256 len = _entries.length;
        require(index < len, IndexOutOfRange(index, len));
        return _entries[index];
    }

    function _enqueue(uint256 kind, address from, uint256 to, uint256 amount) private returns (uint256 index) {
        Record memory record =
            Record({kind: kind, from: uint256(uint160(from)), to: to, amount: amount, nonce: 0, v: 0, r: 0, s: 0});
        index = _entries.length;
        // The first entry chains from zero; `index` is an array length, not a balance.
        // slither-disable-next-line incorrect-equality
        bytes32 previous = index == 0 ? bytes32(0) : _entries[index - 1].accumulator;
        bytes32 accumulator = keccak256(abi.encode(previous, keccak256(abi.encode(record))));
        // Block numbers fit in 64 bits for the lifetime of the chain.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 blockNumber = uint64(block.number);
        _entries.push(Entry({accumulator: accumulator, enqueuedAt: blockNumber}));
        emit MessageEnqueued(index, record, blockNumber, accumulator);
    }
}
