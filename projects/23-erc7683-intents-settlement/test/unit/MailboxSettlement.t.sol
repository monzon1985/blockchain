// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IAccessManaged} from "@openzeppelin-contracts/access/manager/IAccessManaged.sol";

import {DestinationSettler} from "../../src/DestinationSettler.sol";
import {IEscrowSettler, OrderStatus} from "../../src/interfaces/IEscrowSettler.sol";
import {IMailbox} from "../../src/interfaces/IMailbox.sol";
import {MailboxFillReporter} from "../../src/settlement/mailbox/MailboxFillReporter.sol";
import {MailboxSettlementModule} from "../../src/settlement/mailbox/MailboxSettlementModule.sol";
import {MockMailbox} from "../../src/settlement/mailbox/MockMailbox.sol";
import {IntentTestBase} from "../utils/IntentTestBase.sol";

contract MailboxSettlementTest is IntentTestBase {
    function test_happyPath_fillReportRelayRepay() public {
        OrderParams memory p = _params(address(mailboxModule));
        (bytes32 orderId, bytes memory originData) = _openGasless(p, 1);
        _fill(orderId, originData, solver, solverRepayment);

        vm.chainId(DEST);
        vm.recordLogs();
        // messageId is checked against the Dispatch log below; only the indexed fields are compared here
        vm.expectEmit(true, true, false, false, address(reporter));
        emit MailboxFillReporter.FillReported(orderId, ORIGIN, bytes32(0));
        bytes32 messageId = reporter.report(orderId, ORIGIN);
        bytes memory message = _lastDispatch();
        assertEq(keccak256(message), messageId);
        assertEq(destMailbox.outboundNonce(), 1);

        vm.chainId(ORIGIN);
        vm.expectEmit(address(mailboxModule));
        emit MailboxSettlementModule.FillAttested(orderId, DEST, solverRepayment, uint64(block.timestamp));
        vm.prank(mailboxRelayer);
        originMailbox.process(message);
        assertTrue(originMailbox.delivered(messageId));
        assertEq(inputToken.balanceOf(solverRepayment), p.inputAmount);
        assertEq(uint8(origin.escrowOf(orderId).status), uint8(OrderStatus.Repaid));
    }

    function test_reporter_revertsForUnfilledOrder() public {
        vm.chainId(DEST);
        vm.expectRevert(abi.encodeWithSelector(MailboxFillReporter.OrderNotFilled.selector, bytes32(uint256(1))));
        reporter.report(bytes32(uint256(1)), ORIGIN);
    }

    function test_reporter_revertsForUnknownOrigin() public {
        (bytes32 orderId, bytes memory originData) = _openOnchain(_params(address(mailboxModule)));
        _fill(orderId, originData, solver, solverRepayment);
        vm.expectRevert(abi.encodeWithSelector(MailboxFillReporter.UnknownOriginChain.selector, 5));
        reporter.report(orderId, 5);
    }

    function test_reporter_routesAreWriteOnceAndRestricted() public {
        vm.chainId(DEST);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, address(this)));
        reporter.setOriginModule(7, address(1));
        vm.startPrank(admin);
        vm.expectRevert(MailboxFillReporter.ZeroModule.selector);
        reporter.setOriginModule(7, address(0));
        vm.expectRevert(abi.encodeWithSelector(MailboxFillReporter.OriginModuleAlreadySet.selector, ORIGIN));
        reporter.setOriginModule(ORIGIN, address(1));
        vm.expectEmit(address(reporter));
        emit MailboxFillReporter.OriginModuleSet(7, address(1));
        reporter.setOriginModule(7, address(1));
        vm.stopPrank();
        assertEq(reporter.originModule(7), address(1));
    }

    function test_mailbox_processIsRestricted() public {
        vm.chainId(ORIGIN);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, address(this)));
        originMailbox.process("");
    }

    function test_mailbox_rejectsWrongDomainAndReplay() public {
        (bytes32 orderId, bytes memory originData) = _openOnchain(_params(address(mailboxModule)));
        _fill(orderId, originData, solver, solverRepayment);
        vm.chainId(DEST);
        vm.recordLogs();
        reporter.report(orderId, ORIGIN);
        bytes memory message = _lastDispatch();

        // Delivering on the destination chain itself is rejected.
        vm.prank(mailboxRelayer);
        vm.expectRevert(abi.encodeWithSelector(MockMailbox.WrongDestinationDomain.selector, DEST, ORIGIN));
        destMailbox.process(message);

        vm.chainId(ORIGIN);
        vm.prank(mailboxRelayer);
        originMailbox.process(message);
        vm.prank(mailboxRelayer);
        vm.expectRevert(abi.encodeWithSelector(MockMailbox.AlreadyDelivered.selector, keccak256(message)));
        originMailbox.process(message);
    }

    /// @dev "Solver paid but user not filled" through mode 1: a message claiming a fill that did not happen, sent
    ///      by anything other than the trusted reporter, is rejected even when a relayer faithfully delivers it.
    function test_module_rejectsReportsFromUntrustedSenders() public {
        OrderParams memory p = _params(address(mailboxModule));
        (bytes32 orderId, bytes memory originData) = _openOnchain(p);
        vm.chainId(DEST);
        vm.recordLogs();
        vm.prank(rival);
        IMailbox(address(destMailbox))
            .dispatch(
                ORIGIN,
                address(mailboxModule),
                abi.encode(orderId, rival, keccak256(originData), uint64(block.timestamp))
            );
        bytes memory message = _lastDispatch();
        vm.chainId(ORIGIN);
        vm.prank(mailboxRelayer);
        vm.expectRevert(abi.encodeWithSelector(MailboxSettlementModule.UntrustedReporter.selector, DEST, rival));
        originMailbox.process(message);
        assertEq(uint8(origin.escrowOf(orderId).status), uint8(OrderStatus.Open));
    }

    function test_module_onlyMailboxCanHandle() public {
        vm.chainId(ORIGIN);
        vm.expectRevert(abi.encodeWithSelector(MailboxSettlementModule.NotMailbox.selector, address(this)));
        mailboxModule.handle(DEST, address(reporter), "");
    }

    function test_module_rejectsUnknownChain() public {
        vm.chainId(ORIGIN);
        vm.prank(address(originMailbox));
        vm.expectRevert(
            abi.encodeWithSelector(MailboxSettlementModule.UntrustedReporter.selector, 9, address(reporter))
        );
        mailboxModule.handle(9, address(reporter), "");
    }

    function test_module_routesAreWriteOnceAndRestricted() public {
        vm.chainId(ORIGIN);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, address(this)));
        mailboxModule.setRoute(7, address(1), address(2));
        vm.startPrank(admin);
        vm.expectRevert(MailboxSettlementModule.ZeroRouteAddress.selector);
        mailboxModule.setRoute(7, address(0), address(2));
        vm.expectRevert(MailboxSettlementModule.ZeroRouteAddress.selector);
        mailboxModule.setRoute(7, address(1), address(0));
        vm.expectRevert(abi.encodeWithSelector(MailboxSettlementModule.RouteAlreadySet.selector, DEST));
        mailboxModule.setRoute(DEST, address(1), address(2));
        vm.expectEmit(address(mailboxModule));
        emit MailboxSettlementModule.RouteSet(7, address(1), address(2));
        mailboxModule.setRoute(7, address(1), address(2));
        vm.stopPrank();
        assertEq(mailboxModule.destinationSettler(7), address(2));
        assertEq(mailboxModule.destinationSettler(DEST), address(dest));
        assertFalse(mailboxModule.hasPendingClaim(bytes32(0)));
    }

    function test_constructors_rejectZeroDependencies() public {
        vm.expectRevert(MailboxFillReporter.ZeroModule.selector);
        new MailboxFillReporter(DestinationSettler(address(0)), IMailbox(address(destMailbox)), address(destManager));
        vm.expectRevert(MailboxFillReporter.ZeroModule.selector);
        new MailboxFillReporter(dest, IMailbox(address(0)), address(destManager));
        vm.expectRevert(MailboxSettlementModule.ZeroRouteAddress.selector);
        new MailboxSettlementModule(IEscrowSettler(address(0)), address(originMailbox), address(originManager));
        vm.expectRevert(MailboxSettlementModule.ZeroRouteAddress.selector);
        new MailboxSettlementModule(IEscrowSettler(address(origin)), address(0), address(originManager));
    }

    function test_constructorsWireImmutables() public view {
        assertEq(address(reporter.SETTLER()), address(dest));
        assertEq(address(reporter.MAILBOX()), address(destMailbox));
        assertEq(address(mailboxModule.ORIGIN_SETTLER()), address(origin));
        assertEq(mailboxModule.MAILBOX(), address(originMailbox));
    }
}
