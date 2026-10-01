// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {PaymentEscrow} from "../../src/escrow/PaymentEscrow.sol";
import {ISettlementLog} from "../../src/interfaces/ISettlementLog.sol";
import {ResourceBinding} from "../../src/settlement/ResourceBinding.sol";
import {Fixture} from "../utils/Fixture.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC3009} from "@openzeppelin/contracts/token/ERC20/extensions/draft-ERC3009.sol";

contract PaymentEscrowTest is Fixture {
    bytes32 internal constant SALT = keccak256("escrow-salt");
    bytes32 internal constant DELIVERY = keccak256("result bytes");
    uint64 internal deadline;

    function setUp() public override {
        super.setUp();
        _mint(payer, 100 * ONE);
        deadline = uint64(block.timestamp + 1 hours);
    }

    function _open(uint256 value) internal returns (bytes32 escrowId) {
        (PaymentEscrow.OpenRequest memory r, bytes memory sig) =
            _escrowRequest(payerKey, payee, value, RESOURCE, deadline, SALT);
        vm.prank(relayer);
        escrowId = escrow.open(r, sig);
    }

    function test_Open() public {
        (PaymentEscrow.OpenRequest memory r, bytes memory sig) =
            _escrowRequest(payerKey, payee, ONE, RESOURCE, deadline, SALT);
        bytes32 expectedId = escrow.escrowIdFor(payer, r.nonce);
        vm.expectEmit(address(escrow));
        emit PaymentEscrow.EscrowOpened(expectedId, payer, payee, ONE, RESOURCE, deadline);
        vm.prank(relayer);
        bytes32 id = escrow.open(r, sig);

        assertEq(id, expectedId);
        PaymentEscrow.Escrow memory e = escrow.escrowOf(id);
        assertEq(e.payer, payer);
        assertEq(e.payee, payee);
        assertEq(e.amount, ONE);
        assertEq(e.deadline, deadline);
        assertEq(uint8(e.status), uint8(PaymentEscrow.Status.Open));
        assertEq(token.balanceOf(address(escrow)), ONE);
        assertEq(escrow.totalEscrowed(), ONE);
        assertEq(escrow.escrowNonce(payee, RESOURCE, deadline, SALT), r.nonce);
    }

    function test_RevertWhen_TermsTampered() public {
        (PaymentEscrow.OpenRequest memory r, bytes memory sig) =
            _escrowRequest(payerKey, payee, ONE, RESOURCE, deadline, SALT);
        r.payee = otherPayee;
        bytes32 expected = ResourceBinding.escrowNonce(otherPayee, RESOURCE, deadline, SALT);
        vm.expectRevert(abi.encodeWithSelector(PaymentEscrow.TermsBindingMismatch.selector, r.nonce, expected));
        escrow.open(r, sig);

        (r, sig) = _escrowRequest(payerKey, payee, ONE, RESOURCE, deadline, SALT);
        r.deliveryDeadline = deadline + 1 days;
        vm.expectRevert();
        escrow.open(r, sig);

        (r, sig) = _escrowRequest(payerKey, payee, ONE, RESOURCE, deadline, SALT);
        r.resourceHash = OTHER_RESOURCE;
        vm.expectRevert();
        escrow.open(r, sig);
    }

    function test_RevertWhen_AmountTampered() public {
        (PaymentEscrow.OpenRequest memory r, bytes memory sig) =
            _escrowRequest(payerKey, payee, ONE, RESOURCE, deadline, SALT);
        r.value = 2 * ONE;
        vm.expectRevert(ERC3009.ERC3009InvalidSignature.selector);
        escrow.open(r, sig);
    }

    function test_RevertWhen_TransferAuthorizationUsedInsteadOfReceive() public {
        // A TransferWithAuthorization signature (type hash differs) cannot fund an escrow.
        (PaymentEscrow.OpenRequest memory r,) = _escrowRequest(payerKey, payee, ONE, RESOURCE, deadline, SALT);
        bytes memory transferSig = _sign(
            payerKey,
            _authDigest(
                TRANSFER_WITH_AUTHORIZATION_TYPEHASH,
                payer,
                address(escrow),
                r.value,
                r.validAfter,
                r.validBefore,
                r.nonce
            )
        );
        vm.expectRevert(ERC3009.ERC3009InvalidSignature.selector);
        escrow.open(r, transferSig);
    }

    function test_RevertWhen_FrontRunnerCallsTokenDirectly() public {
        (PaymentEscrow.OpenRequest memory r, bytes memory sig) =
            _escrowRequest(payerKey, payee, ONE, RESOURCE, deadline, SALT);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(escrow)));
        vm.prank(relayer);
        token.receiveWithAuthorization(r.from, address(escrow), r.value, r.validAfter, r.validBefore, r.nonce, sig);
    }

    function test_RevertWhen_InvalidOpenParameters() public {
        (PaymentEscrow.OpenRequest memory r, bytes memory sig) =
            _escrowRequest(payerKey, payee, 0, RESOURCE, deadline, SALT);
        vm.expectRevert(PaymentEscrow.ZeroAmount.selector);
        escrow.open(r, sig);

        (r, sig) = _escrowRequest(payerKey, payer, ONE, RESOURCE, deadline, SALT);
        vm.expectRevert(abi.encodeWithSelector(PaymentEscrow.InvalidPayee.selector, payer));
        escrow.open(r, sig);

        (r, sig) = _escrowRequest(payerKey, address(0), ONE, RESOURCE, deadline, SALT);
        vm.expectRevert(abi.encodeWithSelector(PaymentEscrow.InvalidPayee.selector, address(0)));
        escrow.open(r, sig);

        uint64 past = uint64(block.timestamp);
        (r, sig) = _escrowRequest(payerKey, payee, ONE, RESOURCE, past, SALT);
        vm.expectRevert(abi.encodeWithSelector(PaymentEscrow.InvalidDeadline.selector, past, block.timestamp));
        escrow.open(r, sig);

        uint64 tooFar = uint64(block.timestamp + escrow.MAX_DELIVERY_WINDOW() + 1);
        (r, sig) = _escrowRequest(payerKey, payee, ONE, RESOURCE, tooFar, SALT);
        vm.expectRevert(abi.encodeWithSelector(PaymentEscrow.InvalidDeadline.selector, tooFar, block.timestamp));
        escrow.open(r, sig);
    }

    function test_Deliver() public {
        bytes32 id = _open(ONE);
        bytes32 expectedReceipt = settlement.receiptIdFor(address(escrow), ISettlementLog.Scheme.Escrow, payer, id);
        vm.expectEmit(address(escrow));
        emit PaymentEscrow.EscrowReleased(id, DELIVERY, expectedReceipt);
        vm.prank(payee);
        bytes32 receiptId = escrow.deliver(id, DELIVERY);

        assertEq(receiptId, expectedReceipt);
        assertEq(token.balanceOf(payee), ONE);
        assertEq(token.balanceOf(address(escrow)), 0);
        assertEq(escrow.totalEscrowed(), 0);
        PaymentEscrow.Escrow memory e = escrow.escrowOf(id);
        assertEq(uint8(e.status), uint8(PaymentEscrow.Status.Released));
        assertEq(e.deliveryHash, DELIVERY);
        ISettlementLog.Receipt memory r = settlement.receiptOf(receiptId);
        assertEq(r.payer, payer);
        assertEq(r.payee, payee);
        assertEq(r.amount, ONE);
        assertEq(uint8(r.scheme), uint8(ISettlementLog.Scheme.Escrow));
    }

    function test_DeliverAtDeadline() public {
        bytes32 id = _open(ONE);
        vm.warp(deadline);
        vm.prank(payee);
        escrow.deliver(id, DELIVERY);
        assertEq(token.balanceOf(payee), ONE);
    }

    function test_RevertWhen_DeliverChecksFail() public {
        bytes32 id = _open(ONE);
        vm.expectRevert(abi.encodeWithSelector(PaymentEscrow.NotPayee.selector, relayer));
        vm.prank(relayer);
        escrow.deliver(id, DELIVERY);

        vm.expectRevert(PaymentEscrow.EmptyDeliveryHash.selector);
        vm.prank(payee);
        escrow.deliver(id, bytes32(0));

        vm.warp(uint256(deadline) + 1);
        vm.expectRevert(
            abi.encodeWithSelector(PaymentEscrow.DeliveryDeadlinePassed.selector, deadline, block.timestamp)
        );
        vm.prank(payee);
        escrow.deliver(id, DELIVERY);

        bytes32 unknown = keccak256("unknown");
        vm.expectRevert(abi.encodeWithSelector(PaymentEscrow.NotOpen.selector, unknown, PaymentEscrow.Status.None));
        vm.prank(payee);
        escrow.deliver(unknown, DELIVERY);
    }

    function test_Refund() public {
        bytes32 id = _open(ONE);
        vm.warp(uint256(deadline) + 1);
        vm.expectEmit(address(escrow));
        emit PaymentEscrow.EscrowRefunded(id, payer, ONE);
        vm.prank(relayer);
        escrow.refund(id);
        assertEq(token.balanceOf(payer), 100 * ONE);
        assertEq(escrow.totalEscrowed(), 0);
        assertEq(uint8(escrow.escrowOf(id).status), uint8(PaymentEscrow.Status.Refunded));
        assertEq(settlement.receiptCount(), 0, "refunds produce no receipt");
    }

    function test_RevertWhen_RefundBeforeDeadline() public {
        bytes32 id = _open(ONE);
        vm.warp(deadline);
        vm.expectRevert(abi.encodeWithSelector(PaymentEscrow.RefundNotYetAvailable.selector, deadline, block.timestamp));
        escrow.refund(id);
    }

    function test_TerminalStatesAreFinal() public {
        bytes32 id = _open(ONE);
        vm.prank(payee);
        escrow.deliver(id, DELIVERY);
        vm.warp(uint256(deadline) + 1);
        vm.expectRevert(abi.encodeWithSelector(PaymentEscrow.NotOpen.selector, id, PaymentEscrow.Status.Released));
        escrow.refund(id);

        (PaymentEscrow.OpenRequest memory r, bytes memory sig) =
            _escrowRequest(payerKey, payee, ONE, RESOURCE, uint64(block.timestamp + 1 hours), keccak256("s2"));
        bytes32 id2 = escrow.open(r, sig);
        vm.warp(block.timestamp + 2 hours);
        escrow.refund(id2);
        vm.expectRevert(abi.encodeWithSelector(PaymentEscrow.NotOpen.selector, id2, PaymentEscrow.Status.Refunded));
        escrow.refund(id2);
        vm.expectRevert(abi.encodeWithSelector(PaymentEscrow.NotOpen.selector, id2, PaymentEscrow.Status.Refunded));
        vm.prank(payee);
        escrow.deliver(id2, DELIVERY);
    }

    function test_RevertWhen_OpenReplayed() public {
        (PaymentEscrow.OpenRequest memory r, bytes memory sig) =
            _escrowRequest(payerKey, payee, ONE, RESOURCE, deadline, SALT);
        escrow.open(r, sig);
        vm.expectRevert();
        escrow.open(r, sig);
        assertEq(escrow.totalEscrowed(), ONE);
    }

    /// @notice Delivery is possible exactly up to the deadline and refund exactly after it; never both.
    function testFuzz_DeadlineBoundary(uint256 elapsed) public {
        elapsed = bound(elapsed, 0, 2 hours);
        bytes32 id = _open(ONE);
        vm.warp(block.timestamp + elapsed);
        if (block.timestamp <= deadline) {
            vm.expectRevert(
                abi.encodeWithSelector(PaymentEscrow.RefundNotYetAvailable.selector, deadline, block.timestamp)
            );
            escrow.refund(id);
            vm.prank(payee);
            escrow.deliver(id, DELIVERY);
            assertEq(token.balanceOf(payee), ONE);
        } else {
            vm.expectRevert(
                abi.encodeWithSelector(PaymentEscrow.DeliveryDeadlinePassed.selector, deadline, block.timestamp)
            );
            vm.prank(payee);
            escrow.deliver(id, DELIVERY);
            escrow.refund(id);
            assertEq(token.balanceOf(payer), 100 * ONE);
        }
    }
}
