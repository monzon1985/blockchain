// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Record} from "../lib/Types.sol";

/// @title IForcedInclusionQueue
/// @notice FIFO queue of L1-originated messages (deposits, forced transfers, forced withdrawals) that the L2 must
///         process. Each message carries an inclusion deadline; the BatchInbox refuses batches that skip an overdue
///         message and lets anyone post a batch that includes it.
interface IForcedInclusionQueue {
    /// @notice A message was appended to the queue.
    /// @param index Position of the message in the queue.
    /// @param record The tape record the L2 will execute.
    /// @param enqueuedAt L1 block number at which the message was enqueued.
    /// @param accumulator Hash-chain accumulator over messages `[0, index]`.
    event MessageEnqueued(uint256 indexed index, Record record, uint64 enqueuedAt, bytes32 accumulator);

    /// @notice Only the bridge may enqueue deposits (it holds the deposited ETH).
    /// @param caller The unauthorized caller.
    error OnlyBridge(address caller);

    /// @notice A queue index beyond the current length was queried.
    /// @param index The queried index.
    /// @param length The current queue length.
    error IndexOutOfRange(uint256 index, uint256 length);

    /// @notice A constructor argument was the zero address or zero.
    error ZeroParameter();

    /// @notice Enqueues a deposit that credits `to` on L2. Only callable by the bridge.
    /// @param from L1 depositor.
    /// @param to L2 recipient.
    /// @param amount Wei locked in the bridge.
    /// @return index Queue index of the message.
    function enqueueDeposit(address from, address to, uint256 amount) external returns (uint256 index);

    /// @notice Forces an L2 transfer from `msg.sender`, bypassing the sequencer.
    /// @param to L2 recipient.
    /// @param amount Wei to move on L2 (skipped by the L2 if the balance is insufficient).
    /// @return index Queue index of the message.
    function forceTransfer(address to, uint256 amount) external returns (uint256 index);

    /// @notice Forces an L2 withdrawal from `msg.sender` to an L1 recipient, bypassing the sequencer.
    /// @param recipient L1 address that can finalize the withdrawal.
    /// @param amount Wei to withdraw (skipped by the L2 if the balance is insufficient).
    /// @return index Queue index of the message.
    function forceWithdrawal(address recipient, uint256 amount) external returns (uint256 index);

    /// @notice Number of messages ever enqueued.
    /// @return The queue length.
    function length() external view returns (uint256);

    /// @notice Accumulator over messages `[0, index)`; zero for `index == 0`.
    /// @param index Exclusive upper bound, at most `length()`.
    /// @return The accumulator.
    function accumulatorBefore(uint256 index) external view returns (bytes32);

    /// @notice L1 block at which message `index` was enqueued.
    /// @param index Queue index.
    /// @return The block number.
    function enqueuedAt(uint256 index) external view returns (uint64);

    /// @notice Last L1 block at which a batch may still leave message `index` out.
    /// @param index Queue index.
    /// @return enqueuedAt(index) + INCLUSION_WINDOW.
    function deadline(uint256 index) external view returns (uint256);

    /// @notice Whether message `index` must be included by any batch posted in the current block.
    /// @param index Queue index.
    /// @return True when `block.number > deadline(index)`.
    function isOverdue(uint256 index) external view returns (bool);

    /// @notice Hash of a record as chained into the accumulator.
    /// @param record The record.
    /// @return keccak256(abi.encode(record)).
    function recordHash(Record calldata record) external pure returns (bytes32);
}
