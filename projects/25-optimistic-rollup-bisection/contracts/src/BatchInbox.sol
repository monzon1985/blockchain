// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Ownable} from "@openzeppelin-contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin-contracts/access/Ownable2Step.sol";
import {Hashes} from "@openzeppelin-contracts/utils/cryptography/Hashes.sol";
import {IBatchInbox} from "./interfaces/IBatchInbox.sol";
import {IForcedInclusionQueue} from "./interfaces/IForcedInclusionQueue.sol";
import {Record} from "./lib/Types.sol";
import {RollupSpec} from "./lib/RollupSpec.sol";

/// @title BatchInbox
/// @notice Calldata batch inbox. Every batch becomes one epoch whose input tape is
///         `[uint256 queueCount] ++ queueRecords ++ txData`; only its hash and size are stored.
/// @dev Derivation rule enforced here rather than off-chain: a batch may not leave out a queue message whose deadline
///      has passed (unless it already carries the per-batch maximum), and anyone may post a queue-only batch once a
///      message is overdue. An output that ignores a forced message therefore disagrees with the tape committed on
///      L1 and loses its dispute.
contract BatchInbox is IBatchInbox, Ownable2Step {
    /// @notice Maximum sequenced transactions per batch.
    uint256 public constant MAX_SEQUENCED_TXS = 64;
    /// @notice Maximum queue messages per batch. Bounds tape size and therefore the trace length.
    uint256 public constant MAX_QUEUE_PER_BATCH = 32;

    /// @notice The L1 -> L2 message queue.
    IForcedInclusionQueue public immutable QUEUE;

    /// @inheritdoc IBatchInbox
    address public sequencer;

    /// @inheritdoc IBatchInbox
    uint256 public queueCursor;

    /// @notice Batches by epoch (1-based).
    mapping(uint256 epoch => Batch) private _batches;

    /// @inheritdoc IBatchInbox
    uint256 public batchCount;

    /// @param queue The forced-inclusion queue.
    /// @param initialOwner Owner allowed to rotate the sequencer.
    /// @param initialSequencer First sequencer.
    constructor(IForcedInclusionQueue queue, address initialOwner, address initialSequencer) Ownable(initialOwner) {
        require(address(queue) != address(0) && initialSequencer != address(0), ZeroParameter());
        QUEUE = queue;
        sequencer = initialSequencer;
        emit SequencerUpdated(address(0), initialSequencer);
    }

    /// @inheritdoc IBatchInbox
    function submitBatch(bytes calldata txData, Record[] calldata queueRecords) external returns (uint256 epoch) {
        require(msg.sender == sequencer, OnlySequencer(msg.sender));
        uint256 len = txData.length;
        require(
            len % RollupSpec.RECORD_BYTES == 0 && len / RollupSpec.RECORD_BYTES <= MAX_SEQUENCED_TXS, InvalidTxData(len)
        );
        return _append(txData, queueRecords, false);
    }

    /// @inheritdoc IBatchInbox
    function forceBatch(Record[] calldata queueRecords) external returns (uint256 epoch) {
        uint256 cursor = queueCursor;
        require(cursor < QUEUE.length() && QUEUE.isOverdue(cursor), NothingOverdue());
        return _append(msg.data[0:0], queueRecords, true);
    }

    /// @inheritdoc IBatchInbox
    function setSequencer(address newSequencer) external onlyOwner {
        require(newSequencer != address(0), ZeroParameter());
        address previous = sequencer;
        sequencer = newSequencer;
        emit SequencerUpdated(previous, newSequencer);
    }

    /// @inheritdoc IBatchInbox
    function batch(uint256 epoch) external view returns (Batch memory) {
        require(epoch != 0 && epoch <= batchCount, UnknownEpoch(epoch));
        return _batches[epoch];
    }

    function _append(bytes calldata txData, Record[] calldata queueRecords, bool forced)
        private
        returns (uint256 epoch)
    {
        (uint64 start, uint64 end) = _checkQueueRange(queueRecords);
        (bytes32 tapeHash, uint32 tapeSize) = _tapeHash(queueRecords, txData);
        return _store(
            Batch({
                tapeHash: tapeHash,
                tapeSize: tapeSize,
                queueStart: start,
                queueEnd: end,
                // forge-lint: disable-next-line(unsafe-typecast)
                l1Block: uint64(block.number),
                forced: forced
            }),
            txData
        );
    }

    function _store(Batch memory b, bytes calldata txData) private returns (uint256 epoch) {
        epoch = batchCount + 1;
        batchCount = epoch;
        queueCursor = b.queueEnd;
        _batches[epoch] = b;
        // The only earlier external calls are views on the protocol's own immutable queue.
        // forge-lint: disable-next-line(reentrancy-events)
        emit BatchAppended(epoch, b.tapeHash, b.tapeSize, b.queueStart, b.queueEnd, b.forced, txData);
    }

    /// @dev Validates that `queueRecords` are exactly the queue messages `[queueCursor, queueCursor + n)` and that no
    ///      overdue message is left out, unless the batch already carries `MAX_QUEUE_PER_BATCH` messages.
    function _checkQueueRange(Record[] calldata queueRecords) private view returns (uint64 start, uint64 end) {
        uint256 count = queueRecords.length;
        require(count <= MAX_QUEUE_PER_BATCH, TooManyQueueRecords(count, MAX_QUEUE_PER_BATCH));
        uint256 first = queueCursor;
        uint256 last = first + count;
        uint256 queueLength = QUEUE.length();
        require(last <= queueLength, QueueRangeOutOfBounds(last, queueLength));
        if (last < queueLength && count < MAX_QUEUE_PER_BATCH && QUEUE.isOverdue(last)) {
            revert ForcedInclusionViolated(last, QUEUE.deadline(last));
        }

        bytes32 acc = QUEUE.accumulatorBefore(first);
        for (uint256 i = 0; i < count; ++i) {
            acc = Hashes.efficientKeccak256(acc, keccak256(abi.encode(queueRecords[i])));
        }
        bytes32 expected = QUEUE.accumulatorBefore(last);
        // Hash-chain accumulators must match exactly; this is a bytes32 comparison, not a balance check.
        // slither-disable-next-line incorrect-equality
        require(acc == expected, QueueRecordsMismatch(expected, acc));
        // Queue indices are bounded by the number of L1 transactions ever made, far below 2^64.
        // forge-lint: disable-next-line(unsafe-typecast)
        (start, end) = (uint64(first), uint64(last));
    }

    /// @dev Hashes `[count] ++ records ++ txData` without re-encoding: `Record` is a static 256-byte struct, so a
    ///      calldata `Record[]` is laid out contiguously at `queueRecords.offset`.
    function _tapeHash(Record[] calldata queueRecords, bytes calldata txData)
        private
        pure
        returns (bytes32 tapeHash, uint32 tapeSize)
    {
        uint256 count = queueRecords.length;
        uint256 recordBytes = count * RollupSpec.RECORD_BYTES;
        uint256 tapeBytes = 32 + recordBytes + txData.length;
        bytes memory tape = new bytes(tapeBytes);
        // Writes exactly `tapeBytes` bytes into the freshly allocated `tape` buffer, so it is memory-safe.
        // Covered by testFuzz_tapeHashMatchesReference against an abi.encodePacked reference.
        // slither-disable-next-line assembly
        assembly ("memory-safe") {
            let p := add(tape, 32)
            mstore(p, count)
            calldatacopy(add(p, 32), queueRecords.offset, recordBytes)
            calldatacopy(add(add(p, 32), recordBytes), txData.offset, txData.length)
            tapeHash := keccak256(p, tapeBytes)
        }
        // tapeBytes <= 32 + (32 + 64) * 256, so the word count fits in uint32.
        // forge-lint: disable-next-line(unsafe-typecast)
        tapeSize = uint32(tapeBytes / 32);
    }
}
