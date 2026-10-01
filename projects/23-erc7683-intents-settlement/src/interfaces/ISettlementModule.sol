// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title ISettlementModule
/// @notice A pluggable way for the origin chain to learn that an order was filled on a destination chain.
/// @dev Each order names its module at open time and only that module can release its escrow. Modules differ only
///      in what they trust: a messaging layer (mailbox), one honest watcher (optimistic), or a relayed block header
///      plus a Merkle-Patricia proof (storage proof).
interface ISettlementModule {
    /// @notice DestinationSettler whose fills this module can attest on `chainId`, or address(0) if unsupported.
    /// @dev OriginSettler refuses to open an order whose `destinationSettler` differs from this value, so every open
    ///      order is settleable by construction.
    /// @param chainId Destination chain id.
    /// @return The destination settler address.
    function destinationSettler(uint256 chainId) external view returns (address);

    /// @notice Whether an unresolved repayment claim exists for `orderId`. While true, the escrow cannot be refunded.
    /// @param orderId The order id.
    /// @return True if a claim is pending.
    function hasPendingClaim(bytes32 orderId) external view returns (bool);
}
