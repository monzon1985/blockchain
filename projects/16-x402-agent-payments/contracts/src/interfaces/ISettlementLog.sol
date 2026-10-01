// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title ISettlementLog
/// @notice Append-only registry of settled x402 payments. A receipt exists only if value actually moved from
///         `payer` to `payee` through one of the log's trusted settlement paths.
interface ISettlementLog {
    /// @notice How a receipt was produced.
    enum Scheme {
        None,
        Exact,
        BudgetExec,
        Escrow
    }

    /// @notice A settled payment. Packed into three storage slots.
    /// @param payer Account whose balance was debited (EOA or smart account).
    /// @param settledAt Block timestamp of settlement.
    /// @param scheme Settlement path that produced the receipt.
    /// @param payee Account that was credited.
    /// @param amount Amount credited, in token base units.
    /// @param resourceHash keccak256 of the canonical x402 resource string the payment was bound to.
    struct Receipt {
        address payer;
        uint64 settledAt;
        Scheme scheme;
        address payee;
        uint96 amount;
        bytes32 resourceHash;
    }

    /// @notice Records a payment that a trusted recorder (budget executor, escrow) has just executed.
    /// @param scheme The recorder's scheme.
    /// @param payer Debited account.
    /// @param payee Credited account.
    /// @param amount Amount transferred.
    /// @param resourceHash Resource the payment was bound to.
    /// @param paymentKey Recorder-unique key for this payment (intent nonce, escrow id).
    /// @return receiptId The id of the new receipt.
    function recordReceipt(
        Scheme scheme,
        address payer,
        address payee,
        uint256 amount,
        bytes32 resourceHash,
        bytes32 paymentKey
    ) external returns (bytes32 receiptId);

    /// @notice Returns a receipt; `payer == address(0)` means it does not exist.
    /// @param receiptId The receipt id.
    /// @return The stored receipt.
    function receiptOf(bytes32 receiptId) external view returns (Receipt memory);

    /// @notice The single settlement asset of this deployment.
    /// @return The token address.
    function asset() external view returns (address);
}
