// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @notice Lifecycle of an escrow on the origin chain. `Repaid` and `Refunded` are terminal and mutually exclusive.
enum OrderStatus {
    None,
    Open,
    Repaid,
    Refunded
}

/// @notice Escrow record kept by the OriginSettler (three storage slots).
/// @param user Owner of the escrowed input, refunded after `fillDeadline` plus the grace period.
/// @param fillDeadline Last timestamp at which the destination accepts a fill.
/// @param status Lifecycle status.
/// @param inputToken Escrowed ERC-20.
/// @param inputAmount Escrowed amount (fits 96 bits, enforced at open).
/// @param settlementModule The only address allowed to release the escrow to a filler.
/// @param destinationChainId Chain on which the order must be filled.
struct Escrow {
    address user;
    uint32 fillDeadline;
    OrderStatus status;
    address inputToken;
    uint96 inputAmount;
    address settlementModule;
    uint64 destinationChainId;
}

/// @title IEscrowSettler
/// @notice The part of the OriginSettler that settlement modules talk to.
interface IEscrowSettler {
    /// @notice Releases the escrow of `orderId` to `filler`. Only callable by the order's settlement module.
    /// @param orderId The order id.
    /// @param destinationChainId Chain on which the module observed the fill.
    /// @param filler Origin-chain repayment address recorded by the fill.
    /// @param fillHash keccak256 of the `originData` that was filled; must hash to `orderId`.
    function settle(bytes32 orderId, uint256 destinationChainId, address filler, bytes32 fillHash) external;

    /// @notice Escrow record of `orderId` (all zero if unknown).
    /// @param orderId The order id.
    /// @return The escrow record.
    function escrowOf(bytes32 orderId) external view returns (Escrow memory);
}
