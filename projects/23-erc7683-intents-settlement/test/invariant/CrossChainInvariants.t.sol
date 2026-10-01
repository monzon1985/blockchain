// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {console} from "forge-std/console.sol";

import {DestinationSettler} from "../../src/DestinationSettler.sol";
import {Escrow, OrderStatus} from "../../src/interfaces/IEscrowSettler.sol";
import {FillProofLib} from "../../src/libraries/FillProofLib.sol";
import {IntentTestBase} from "../utils/IntentTestBase.sol";
import {Deployment, IntentHandler} from "./IntentHandler.sol";

/// @title CrossChainInvariants
/// @notice Stateful invariants over both chains at once (chain 1001 = origin, 1002 = destination, switched with
/// vm.chainId inside one EVM), with all three settlement modes live at the same time and adversarial actors.
/// Each invariant is stated in plain English in the README and links here.
contract CrossChainInvariants is IntentTestBase {
    IntentHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new IntentHandler(
            Deployment({
                origin: origin,
                dest: dest,
                originMailbox: originMailbox,
                destMailbox: destMailbox,
                reporter: reporter,
                mailboxModule: mailboxModule,
                optimistic: optimistic,
                proofModule: proofModule,
                headers: headers,
                inputToken: inputToken,
                outputToken: outputToken,
                bondToken: bondToken,
                permit2: PERMIT2_ADDRESS,
                headerRelayer: headerRelayer,
                mailboxRelayer: mailboxRelayer
            })
        );
        targetContract(address(handler));
    }

    /// @notice INV-1 "solver repaid implies user filled": every repaid escrow went, as OBSERVED from token balances,
    /// to exactly the repayment address recorded by a real fill of that order on the destination chain, for exactly
    /// the escrowed amount, and no other balance moved while escrows were released.
    function invariant_solverRepaidImpliesUserFilled() public {
        uint256 n = handler.orderCount();
        for (uint256 i = 0; i < n; ++i) {
            IntentHandler.OrderInfo memory o = handler.orderAt(i);
            vm.chainId(ORIGIN);
            if (origin.escrowOf(o.id).status != OrderStatus.Repaid) continue;
            vm.chainId(DEST);
            address recorded = dest.fillRecord(o.id).filler;
            assertTrue(recorded != address(0), "repaid but never filled");
            assertEq(handler.ghostRepaidTo(o.id), recorded, "tokens went to someone other than the filler");
            assertEq(handler.ghostRepaidAmount(o.id), o.inputAmount, "filler received a different amount");
        }
        assertEq(handler.unexplainedMovements(), 0, "input tokens moved without an escrow release explaining it");
    }

    /// @notice INV-2 "refunded implies solver not repaid": an escrow is closed at most once, by repayment or by
    /// refund, never both; a refund went (observed) to the order's user, for the escrowed amount.
    function invariant_refundedImpliesNotRepaid() public {
        uint256 n = handler.orderCount();
        vm.chainId(ORIGIN);
        for (uint256 i = 0; i < n; ++i) {
            IntentHandler.OrderInfo memory o = handler.orderAt(i);
            OrderStatus status = origin.escrowOf(o.id).status;
            if (status == OrderStatus.Refunded) {
                assertEq(handler.ghostRepaidTo(o.id), address(0), "refunded and repaid");
                assertEq(handler.ghostRefundedTo(o.id), o.user, "refund went to someone other than the user");
                assertEq(handler.ghostRefundedAmount(o.id), o.inputAmount, "refund of a different amount");
            }
            if (status == OrderStatus.Repaid) {
                assertEq(handler.ghostRefundedTo(o.id), address(0), "repaid and refunded");
            }
            if (status == OrderStatus.Open) {
                assertEq(handler.ghostRefundedTo(o.id), address(0));
                assertEq(handler.ghostRepaidTo(o.id), address(0));
            }
        }
    }

    /// @notice INV-3 "escrowed == outstanding + repaid + refunded", and the escrow balance equals the sum of open
    /// orders exactly (nothing stuck, nothing missing).
    function invariant_escrowConservation() public {
        uint256 n = handler.orderCount();
        uint256 outstanding = 0;
        vm.chainId(ORIGIN);
        for (uint256 i = 0; i < n; ++i) {
            Escrow memory escrow = origin.escrowOf(handler.orderAt(i).id);
            if (escrow.status == OrderStatus.Open) outstanding += escrow.inputAmount;
        }
        assertEq(inputToken.balanceOf(address(origin)), outstanding, "escrow balance");
        assertEq(handler.ghostEscrowed(), outstanding + handler.ghostRepaidSum() + handler.ghostRefundedSum(), "flows");
    }

    /// @notice INV-4 every fill delivered at least the user's floor (`outputEndAmount`) to the recipient.
    function invariant_userReceivesAtLeastFloor() public view {
        uint256 n = handler.orderCount();
        for (uint256 i = 0; i < n; ++i) {
            IntentHandler.OrderInfo memory o = handler.orderAt(i);
            if (handler.ghostFirstRecord(o.id) == 0) continue;
            assertGe(handler.ghostDelivered(o.id), o.outputEnd, "below floor");
        }
    }

    /// @notice INV-5 fill records are write-once: the record written by the first fill never changes.
    function invariant_fillRecordsAreWriteOnce() public view {
        uint256 n = handler.orderCount();
        for (uint256 i = 0; i < n; ++i) {
            IntentHandler.OrderInfo memory o = handler.orderAt(i);
            uint256 first = handler.ghostFirstRecord(o.id);
            assertEq(uint256(vm.load(address(dest), FillProofLib.fillerSlot(o.id))), first, "record rewritten");
        }
    }

    /// @notice INV-6 the optimistic module holds exactly one bond per pending claim, whatever the number of claims
    /// per order.
    function invariant_bondsAreBacked() public {
        uint256 n = handler.orderCount();
        uint256 pending = 0;
        vm.chainId(ORIGIN);
        for (uint256 i = 0; i < n; ++i) {
            pending += optimistic.pendingClaims(handler.orderAt(i).id);
        }
        assertEq(bondToken.balanceOf(address(optimistic)), pending * BOND);
        assertEq(pending, handler.claimCount(), "pending claims tracked by the handler");
    }

    /// @notice INV-7 no attack succeeded: forged mailbox reports, forged or tampered storage proofs, double and
    /// late fills all reverted, and no escrow was paid twice.
    function invariant_noAttackSucceeded() public view {
        assertEq(handler.violations(), 0);
    }

    /// @notice INV-8 a false claim cannot take the real filler's repayment away: an order whose real fill was claimed
    /// through the optimistic module is never refunded, however many false claims (including the user's own) are
    /// posted around it.
    function invariant_honestClaimIsNeverRefunded() public {
        uint256 n = handler.orderCount();
        vm.chainId(ORIGIN);
        for (uint256 i = 0; i < n; ++i) {
            bytes32 id = handler.orderAt(i).id;
            if (!handler.ghostHonestlyClaimed(id)) continue;
            assertTrue(origin.escrowOf(id).status != OrderStatus.Refunded, "honestly claimed order refunded");
        }
    }

    function afterInvariant() external view {
        string[13] memory names = [
            "open",
            "fill",
            "attackFill",
            "report",
            "relay",
            "forgeReport",
            "claimHonest",
            "claimFraud",
            "challenge",
            "finalize",
            "prove",
            "forgeProof",
            "refund"
        ];
        for (uint256 i = 0; i < names.length; ++i) {
            console.log(names[i], handler.calls(bytes32(bytes(names[i]))));
        }
    }
}
