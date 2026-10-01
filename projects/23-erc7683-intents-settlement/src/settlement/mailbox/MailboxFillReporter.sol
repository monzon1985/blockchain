// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {AccessManaged} from "@openzeppelin-contracts/access/manager/AccessManaged.sol";

import {DestinationSettler} from "../../DestinationSettler.sol";
import {IMailbox} from "../../interfaces/IMailbox.sol";

/// @title MailboxFillReporter
/// @notice Destination-chain half of settlement mode 1. Reads a FillRecord from the DestinationSettler and sends it
/// through the mailbox to the MailboxSettlementModule of the order's origin chain.
/// @dev Permissionless: the report only relays what the settler recorded, so anyone (usually the filler) can pay
///      for it. Routes to origin-chain modules are write-once so the admin cannot redirect reports later.
contract MailboxFillReporter is AccessManaged {
    /// @notice Settler whose fills are reported.
    DestinationSettler public immutable SETTLER;

    /// @notice Mailbox used to send reports.
    IMailbox public immutable MAILBOX;

    /// @notice MailboxSettlementModule on each origin chain.
    mapping(uint256 originChainId => address module) public originModule;

    /// @notice Emitted when an origin route is configured.
    /// @param originChainId The origin chain.
    /// @param module The MailboxSettlementModule on that chain.
    event OriginModuleSet(uint256 indexed originChainId, address indexed module);

    /// @notice Emitted when a fill is reported.
    /// @param orderId The order id.
    /// @param originChainId The origin chain the report is sent to.
    /// @param messageId The mailbox message id.
    event FillReported(bytes32 indexed orderId, uint256 indexed originChainId, bytes32 messageId);

    /// @notice The order has no fill record.
    /// @param orderId The order id.
    error OrderNotFilled(bytes32 orderId);
    /// @notice No module is configured for the origin chain.
    /// @param originChainId The origin chain.
    error UnknownOriginChain(uint256 originChainId);
    /// @notice The origin route is already configured.
    /// @param originChainId The origin chain.
    error OriginModuleAlreadySet(uint256 originChainId);
    /// @notice The module, settler or mailbox address is zero.
    error ZeroModule();

    /// @param settler DestinationSettler to report fills of.
    /// @param mailbox Local mailbox.
    /// @param authority AccessManager governing `setOriginModule`.
    constructor(DestinationSettler settler, IMailbox mailbox, address authority) AccessManaged(authority) {
        require(address(settler) != address(0) && address(mailbox) != address(0), ZeroModule());
        SETTLER = settler;
        MAILBOX = mailbox;
    }

    /// @notice Configures, once, the module that receives reports on `originChainId`.
    /// @param originChainId The origin chain.
    /// @param module The MailboxSettlementModule on that chain.
    function setOriginModule(uint256 originChainId, address module) external restricted {
        require(module != address(0), ZeroModule());
        require(originModule[originChainId] == address(0), OriginModuleAlreadySet(originChainId));
        originModule[originChainId] = module;
        // The only prior external call is AccessManager.canCall, made by the `restricted` modifier.
        // forge-lint: disable-next-line(reentrancy-events)
        emit OriginModuleSet(originChainId, module);
    }

    /// @notice Sends the fill record of `orderId` to `originChainId`.
    /// @param orderId The order id.
    /// @param originChainId The order's origin chain.
    /// @return messageId The mailbox message id.
    // slither-disable-next-line reentrancy-events
    function report(bytes32 orderId, uint256 originChainId) external returns (bytes32 messageId) {
        DestinationSettler.FillRecord memory record = SETTLER.fillRecord(orderId);
        require(record.filler != address(0), OrderNotFilled(orderId));
        address module = originModule[originChainId];
        require(module != address(0), UnknownOriginChain(originChainId));
        messageId = MAILBOX.dispatch(
            originChainId, module, abi.encode(orderId, record.filler, record.fillHash, record.filledAt)
        );
        // Needs the id returned by the mailbox; both callees are immutable protocol contracts and `report` keeps
        // no state of its own.
        // forge-lint: disable-next-line(reentrancy-events)
        emit FillReported(orderId, originChainId, messageId);
    }
}
