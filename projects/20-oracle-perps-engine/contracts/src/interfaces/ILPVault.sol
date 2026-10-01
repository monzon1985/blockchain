// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title ILPVault
/// @notice Types, events and errors of the asynchronous LP vault.
interface ILPVault {
    /// @notice A pending two-step LP deposit or redemption. Deleted on execution or cancellation.
    /// @param account LP that created the request and receives its output.
    /// @param isDeposit True for a deposit (amount = assets), false for a redemption (amount = shares).
    /// @param createdAt Block timestamp at creation; settling reports must be strictly newer.
    /// @param amount Assets to deposit or shares to redeem (escrowed by the vault).
    /// @param minOut Minimum shares (deposit) or assets (redemption) the LP accepts.
    /// @param executionFee Collateral paid to the keeper that settles the request.
    struct LpRequest {
        address account;
        bool isDeposit;
        uint64 createdAt;
        uint128 amount;
        uint128 minOut;
        uint128 executionFee;
    }

    /// @notice An LP deposit or redemption request was created.
    /// @param requestId Identifier of the request.
    /// @param account LP.
    /// @param isDeposit Deposit or redemption.
    /// @param amount Assets (deposit) or shares (redemption) escrowed.
    /// @param minOut Minimum output accepted.
    /// @param executionFee Escrowed keeper fee.
    event LpRequestCreated(
        uint256 indexed requestId,
        address indexed account,
        bool isDeposit,
        uint256 amount,
        uint256 minOut,
        uint256 executionFee
    );

    /// @notice An LP request was executed.
    /// @param requestId Identifier of the request.
    /// @param keeper Executing keeper.
    /// @param amountIn Assets (deposit) or shares (redemption) consumed.
    /// @param amountOut Shares minted (deposit) or assets paid (redemption).
    /// @param price Oracle price used for pool valuation.
    event LpRequestExecuted(
        uint256 indexed requestId, address indexed keeper, uint256 amountIn, uint256 amountOut, uint256 price
    );

    /// @notice An LP request was cancelled and its escrow returned.
    /// @param requestId Identifier of the request.
    /// @param cancelledBy The LP (after the timeout) or the keeper (failed settlement).
    /// @param reason ABI-encoded failure reason; empty for LP cancellations.
    event LpRequestCancelled(uint256 indexed requestId, address indexed cancelledBy, bytes reason);

    /// @notice Synchronous ERC-4626 entry and exit are disabled; use the request flow.
    error SynchronousEntryDisabled();
    /// @notice New deposits are blocked while the market is paused.
    error MarketPaused();
    /// @notice The request does not exist (already executed or cancelled).
    /// @param requestId The identifier looked up.
    error UnknownRequest(uint256 requestId);
    /// @notice The caller does not own the request.
    /// @param caller The caller.
    /// @param owner The owner.
    error NotRequestOwner(address caller, address owner);
    /// @notice The request amount is zero.
    error EmptyRequest();
    /// @notice The execution fee is below the market minimum.
    /// @param fee Fee supplied.
    /// @param minFee Minimum fee.
    error ExecutionFeeTooLow(uint256 fee, uint256 minFee);
    /// @notice Requests cannot be cancelled by their owner before the timeout.
    /// @param cancellableAt First timestamp at which the owner may cancel.
    error CancelTooEarly(uint256 cancellableAt);
    /// @notice The request output is below the requested minimum (recorded as the cancellation reason).
    /// @param amountOut Output at the settlement price.
    /// @param minOut Minimum accepted.
    error SlippageExceeded(uint256 amountOut, uint256 minOut);
    /// @notice The market call ran out of gas; the keeper transaction reverts instead of cancelling the request.
    error ExecutionOutOfGas();
}
