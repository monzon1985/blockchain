// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {AccessManaged} from "@openzeppelin-contracts/access/manager/AccessManaged.sol";

import {IEscrowSettler} from "../../interfaces/IEscrowSettler.sol";
import {IMessageRecipient} from "../../interfaces/IMailbox.sol";
import {ISettlementModule} from "../../interfaces/ISettlementModule.sol";

/// @title MailboxSettlementModule
/// @notice Settlement mode 1 (origin half). Releases an escrow when the mailbox delivers a fill report from the
/// configured MailboxFillReporter of the destination chain.
/// @dev Trusts the mailbox completely: a forged message from the mailbox pays whoever it names. Routes are
///      write-once so the admin cannot later swap the trusted reporter of a chain.
contract MailboxSettlementModule is ISettlementModule, IMessageRecipient, AccessManaged {
    /// @notice Trusted endpoints on a destination chain.
    /// @param reporter MailboxFillReporter allowed to send reports.
    /// @param destinationSettler DestinationSettler the reporter reads.
    struct Route {
        address reporter;
        address destinationSettler;
    }

    /// @notice OriginSettler whose escrows this module releases.
    IEscrowSettler public immutable ORIGIN_SETTLER;

    /// @notice Local mailbox, the only caller of `handle`.
    address public immutable MAILBOX;

    /// @notice Route of each destination chain.
    mapping(uint256 chainId => Route) public routes;

    /// @notice Emitted when a destination route is configured.
    /// @param chainId The destination chain.
    /// @param reporter The trusted reporter.
    /// @param destinationSettler The settler it reports on.
    event RouteSet(uint256 indexed chainId, address indexed reporter, address indexed destinationSettler);

    /// @notice Emitted when a report is accepted and forwarded to the OriginSettler.
    /// @param orderId The order id.
    /// @param chainId The destination chain.
    /// @param filler The repayment address.
    /// @param filledAt Fill timestamp on the destination chain.
    event FillAttested(bytes32 indexed orderId, uint256 indexed chainId, address indexed filler, uint64 filledAt);

    /// @notice The caller is not the mailbox.
    /// @param caller The caller.
    error NotMailbox(address caller);
    /// @notice The message does not come from the configured reporter of its chain.
    /// @param chainId The sending chain.
    /// @param sender The sending contract.
    error UntrustedReporter(uint256 chainId, address sender);
    /// @notice The route is already configured.
    /// @param chainId The destination chain.
    error RouteAlreadySet(uint256 chainId);
    /// @notice A route or constructor address is zero.
    error ZeroRouteAddress();

    /// @param originSettler OriginSettler whose escrows this module releases.
    /// @param mailbox Local mailbox.
    /// @param authority AccessManager governing `setRoute`.
    constructor(IEscrowSettler originSettler, address mailbox, address authority) AccessManaged(authority) {
        require(address(originSettler) != address(0) && mailbox != address(0), ZeroRouteAddress());
        ORIGIN_SETTLER = originSettler;
        MAILBOX = mailbox;
    }

    /// @notice Configures, once, the trusted reporter and settler of `chainId`.
    /// @param chainId The destination chain.
    /// @param reporter The MailboxFillReporter on that chain.
    /// @param destinationSettler_ The DestinationSettler it reports on.
    function setRoute(uint256 chainId, address reporter, address destinationSettler_) external restricted {
        require(reporter != address(0) && destinationSettler_ != address(0), ZeroRouteAddress());
        require(routes[chainId].reporter == address(0), RouteAlreadySet(chainId));
        routes[chainId] = Route({reporter: reporter, destinationSettler: destinationSettler_});
        // The only prior external call is AccessManager.canCall, made by the `restricted` modifier.
        // forge-lint: disable-next-line(reentrancy-events)
        emit RouteSet(chainId, reporter, destinationSettler_);
    }

    /// @inheritdoc IMessageRecipient
    function handle(uint256 originDomain, address sender, bytes calldata body) external {
        require(msg.sender == MAILBOX, NotMailbox(msg.sender));
        address reporter = routes[originDomain].reporter;
        require(reporter != address(0) && sender == reporter, UntrustedReporter(originDomain, sender));
        (bytes32 orderId, address filler, bytes32 fillHash, uint64 filledAt) =
            abi.decode(body, (bytes32, address, bytes32, uint64));
        emit FillAttested(orderId, originDomain, filler, filledAt);
        ORIGIN_SETTLER.settle(orderId, originDomain, filler, fillHash);
    }

    /// @inheritdoc ISettlementModule
    function destinationSettler(uint256 chainId) external view returns (address) {
        return routes[chainId].destinationSettler;
    }

    /// @inheritdoc ISettlementModule
    /// @dev Reports settle atomically on delivery, so there is never a pending claim.
    function hasPendingClaim(bytes32) external pure returns (bool) {
        return false;
    }
}
