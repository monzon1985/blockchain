// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title IMailbox
/// @notice Minimal Hyperlane-style dispatch interface of the mock messaging layer.
interface IMailbox {
    /// @notice Sends `body` to `recipient` on `destinationDomain`.
    /// @param destinationDomain Chain id of the receiving chain.
    /// @param recipient Receiver contract on that chain.
    /// @param body Application payload.
    /// @return messageId keccak256 of the encoded message.
    function dispatch(uint256 destinationDomain, address recipient, bytes calldata body)
        external
        returns (bytes32 messageId);
}

/// @title IMessageRecipient
/// @notice Receiver side of the mock messaging layer.
interface IMessageRecipient {
    /// @notice Delivers a message from `sender` on `originDomain`. Only the local mailbox may call this.
    /// @param originDomain Chain id the message was sent from.
    /// @param sender Contract that dispatched the message.
    /// @param body Application payload.
    function handle(uint256 originDomain, address sender, bytes calldata body) external;
}
