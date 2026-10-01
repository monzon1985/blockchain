// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Record} from "../lib/Types.sol";

/// @title IBatchInbox
/// @notice Append-only log of L2 batches (one batch = one epoch). Each batch commits to the exact input tape the
///         state-transition program executes: `[queueCount] ++ queueRecords ++ sequencedTxs`.
interface IBatchInbox {
    /// @notice Stored metadata of an epoch's batch.
    /// @param tapeHash keccak256 of the input tape; becomes the VM's `inputRoot`.
    /// @param tapeSize Tape length in words; becomes the VM's `inputSize`.
    /// @param queueStart First queue index included.
    /// @param queueEnd One past the last queue index included.
    /// @param l1Block L1 block of submission.
    /// @param forced True when posted through `forceBatch` instead of by the sequencer.
    struct Batch {
        bytes32 tapeHash;
        uint32 tapeSize;
        uint64 queueStart;
        uint64 queueEnd;
        uint64 l1Block;
        bool forced;
    }

    /// @notice A batch was appended. `txData` mirrors the calldata so derivation only needs logs.
    /// @param epoch Epoch number (1-based batch index).
    /// @param tapeHash keccak256 of the full input tape.
    /// @param tapeSize Tape length in words.
    /// @param queueStart First queue index included.
    /// @param queueEnd One past the last queue index included.
    /// @param forced True when posted through `forceBatch`.
    /// @param txData Sequenced transaction records (empty for forced batches).
    event BatchAppended(
        uint256 indexed epoch,
        bytes32 tapeHash,
        uint32 tapeSize,
        uint64 queueStart,
        uint64 queueEnd,
        bool forced,
        bytes txData
    );

    /// @notice The sequencer address changed.
    /// @param previous Old sequencer.
    /// @param current New sequencer.
    event SequencerUpdated(address indexed previous, address indexed current);

    /// @notice Caller is not the sequencer.
    /// @param caller The caller.
    error OnlySequencer(address caller);

    /// @notice `txData` is not a whole number of records or exceeds the per-batch limit.
    /// @param length Byte length supplied.
    error InvalidTxData(uint256 length);

    /// @notice More queue records than a batch may carry.
    /// @param count Records supplied.
    /// @param max Allowed maximum.
    error TooManyQueueRecords(uint256 count, uint256 max);

    /// @notice The batch claims queue messages that do not exist yet.
    /// @param end Claimed end index.
    /// @param length Current queue length.
    error QueueRangeOutOfBounds(uint256 end, uint256 length);

    /// @notice The supplied queue records do not match the queue accumulator.
    /// @param expected Accumulator stored by the queue.
    /// @param computed Accumulator implied by the records.
    error QueueRecordsMismatch(bytes32 expected, bytes32 computed);

    /// @notice The batch leaves out a queue message whose inclusion deadline has passed.
    /// @param index First queue index left out.
    /// @param deadline Last block at which it could still be left out.
    error ForcedInclusionViolated(uint256 index, uint256 deadline);

    /// @notice `forceBatch` was called while no queue message is overdue.
    error NothingOverdue();

    /// @notice Unknown epoch.
    /// @param epoch The epoch queried.
    error UnknownEpoch(uint256 epoch);

    /// @notice A constructor argument was the zero address.
    error ZeroParameter();

    /// @notice Posts a batch. Only the sequencer. Must include every overdue queue message (up to the per-batch cap).
    /// @param txData Concatenated 256-byte sequenced transaction records.
    /// @param queueRecords Queue messages `[queueCursor, queueCursor + queueRecords.length)`.
    /// @return epoch The new epoch number.
    function submitBatch(bytes calldata txData, Record[] calldata queueRecords) external returns (uint256 epoch);

    /// @notice Permissionless escape hatch: posts a batch with no sequenced transactions once a queue message is
    ///         overdue, so a censoring or offline sequencer cannot stall L1 -> L2 messages.
    /// @param queueRecords Queue messages starting at `queueCursor`; must cover every overdue one (up to the cap).
    /// @return epoch The new epoch number.
    function forceBatch(Record[] calldata queueRecords) external returns (uint256 epoch);

    /// @notice Rotates the sequencer. Owner only.
    /// @param newSequencer The new sequencer.
    function setSequencer(address newSequencer) external;

    /// @notice Current sequencer.
    /// @return The sequencer address.
    function sequencer() external view returns (address);

    /// @notice Number of batches (equal to the latest epoch).
    /// @return The count.
    function batchCount() external view returns (uint256);

    /// @notice Queue messages consumed by batches so far.
    /// @return The cursor.
    function queueCursor() external view returns (uint256);

    /// @notice Metadata of an epoch's batch.
    /// @param epoch 1-based epoch.
    /// @return The batch.
    function batch(uint256 epoch) external view returns (Batch memory);
}
