// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {AccessManaged} from "@openzeppelin-contracts/access/manager/AccessManaged.sol";

import {IMailbox, IMessageRecipient} from "../../interfaces/IMailbox.sol";

/// @title MockMailbox
/// @notice Stand-in for a cross-chain messaging layer (Hyperlane-style dispatch/process). One instance per chain.
/// @dev Trust model: `process` is restricted to a relayer role, so whoever holds that role on the receiving chain can
///      forge any message. That is the security of a trusted relayer set or a multisig bridge, and it is why this is
///      the least trust-minimized settlement mode. Swapping this contract for a production mailbox with a real
///      interchain security module does not change the settlement module or the reporter.
contract MockMailbox is IMailbox, AccessManaged {
    /// @notice A message in transit.
    /// @param nonce Per-mailbox sequence number.
    /// @param originDomain Chain id of the sending chain.
    /// @param sender Dispatching contract.
    /// @param destinationDomain Chain id of the receiving chain.
    /// @param recipient Receiving contract.
    /// @param body Application payload.
    struct Message {
        uint64 nonce;
        uint256 originDomain;
        address sender;
        uint256 destinationDomain;
        address recipient;
        bytes body;
    }

    /// @notice Number of messages dispatched so far; the nonce of the next message.
    uint64 public outboundNonce;

    /// @notice Whether an inbound message id has been processed.
    mapping(bytes32 messageId => bool) public delivered;

    /// @notice Emitted when a message is dispatched.
    /// @param messageId keccak256 of `message`.
    /// @param sender Dispatching contract.
    /// @param destinationDomain Receiving chain.
    /// @param message ABI-encoded Message, as `process` expects it.
    event Dispatch(bytes32 indexed messageId, address indexed sender, uint256 indexed destinationDomain, bytes message);

    /// @notice Emitted when a message is delivered.
    /// @param messageId keccak256 of the message.
    /// @param originDomain Sending chain.
    /// @param recipient Receiving contract.
    event Process(bytes32 indexed messageId, uint256 indexed originDomain, address indexed recipient);

    /// @notice The message targets another chain.
    /// @param expected The current chain id.
    /// @param actual The message's destination domain.
    error WrongDestinationDomain(uint256 expected, uint256 actual);
    /// @notice The message was already processed.
    /// @param messageId The message id.
    error AlreadyDelivered(bytes32 messageId);

    /// @param authority AccessManager that grants the relayer role for `process`.
    constructor(address authority) AccessManaged(authority) {}

    /// @inheritdoc IMailbox
    function dispatch(uint256 destinationDomain, address recipient, bytes calldata body)
        external
        returns (bytes32 messageId)
    {
        uint64 nonce = outboundNonce++;
        bytes memory message = abi.encode(
            Message({
                nonce: nonce,
                originDomain: block.chainid,
                sender: msg.sender,
                destinationDomain: destinationDomain,
                recipient: recipient,
                body: body
            })
        );
        messageId = keccak256(message);
        emit Dispatch(messageId, msg.sender, destinationDomain, message);
    }

    /// @notice Delivers a message dispatched on another chain. Restricted to the relayer role.
    /// @param message ABI-encoded Message, taken verbatim from the origin chain's Dispatch event.
    function process(bytes calldata message) external restricted {
        Message memory decoded = abi.decode(message, (Message));
        require(
            decoded.destinationDomain == block.chainid, WrongDestinationDomain(block.chainid, decoded.destinationDomain)
        );
        bytes32 messageId = keccak256(message);
        require(!delivered[messageId], AlreadyDelivered(messageId));
        delivered[messageId] = true;
        // The only prior external call is AccessManager.canCall, made by the `restricted` modifier.
        // forge-lint: disable-next-line(reentrancy-events)
        emit Process(messageId, decoded.originDomain, decoded.recipient);
        IMessageRecipient(decoded.recipient).handle(decoded.originDomain, decoded.sender, decoded.body);
    }
}
