// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {SmtProof} from "../lib/Types.sol";

/// @title IBridge
/// @notice ETH bridge: deposits enter the forced-inclusion queue, withdrawals are paid against finalized outputs.
interface IBridge {
    /// @notice ETH was locked for an L2 deposit.
    /// @param from L1 depositor.
    /// @param to L2 recipient.
    /// @param amount Wei.
    /// @param queueIndex Index of the deposit message in the queue.
    event DepositInitiated(address indexed from, address indexed to, uint256 amount, uint256 queueIndex);

    /// @notice A withdrawal was paid out on L1.
    /// @param withdrawalId L2 withdrawal id.
    /// @param recipient L1 recipient.
    /// @param amount Wei.
    /// @param epoch Finalized epoch whose state root proved it.
    event WithdrawalFinalized(uint256 indexed withdrawalId, address indexed recipient, uint256 amount, uint64 epoch);

    /// @notice Deposits must carry ETH.
    error ZeroDeposit();

    /// @notice The withdrawal was already paid.
    /// @param withdrawalId The id.
    error AlreadyFinalized(uint256 withdrawalId);

    /// @notice The proof does not show the withdrawal in the finalized state root.
    /// @param stateRoot Finalized state root.
    /// @param computed Root implied by the proof.
    error InvalidWithdrawalProof(bytes32 stateRoot, bytes32 computed);

    /// @notice A constructor argument was the zero address.
    error ZeroParameter();

    /// @notice Locks `msg.value` and enqueues a deposit crediting `to` on L2.
    /// @param to L2 recipient.
    /// @return queueIndex Queue index of the deposit.
    function deposit(address to) external payable returns (uint256 queueIndex);

    /// @notice Pays out an L2 withdrawal proven against a finalized output.
    /// @param epoch A finalized epoch at or after the withdrawal.
    /// @param withdrawalId Sequential id assigned by the L2.
    /// @param recipient L1 recipient recorded on L2.
    /// @param amount Wei recorded on L2.
    /// @param proof Sparse-Merkle proof of the withdrawal leaf.
    function finalizeWithdrawal(
        uint64 epoch,
        uint256 withdrawalId,
        address recipient,
        uint256 amount,
        SmtProof calldata proof
    ) external;

    /// @notice Whether a withdrawal was paid.
    /// @param withdrawalId The id.
    /// @return True once paid.
    function finalized(uint256 withdrawalId) external view returns (bool);
}
