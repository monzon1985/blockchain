// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {RLP} from "@openzeppelin-contracts/utils/RLP.sol";
import {TrieProof} from "@openzeppelin-contracts/utils/cryptography/TrieProof.sol";

import {DestinationSettler} from "../../src/DestinationSettler.sol";
import {Escrow, OrderStatus} from "../../src/interfaces/IEscrowSettler.sol";
import {IMailbox} from "../../src/interfaces/IMailbox.sol";
import {FillProofLib} from "../../src/libraries/FillProofLib.sol";
import {MailboxFillReporter} from "../../src/settlement/mailbox/MailboxFillReporter.sol";
import {MailboxSettlementModule} from "../../src/settlement/mailbox/MailboxSettlementModule.sol";
import {MockMailbox} from "../../src/settlement/mailbox/MockMailbox.sol";
import {OptimisticSettlementModule} from "../../src/settlement/optimistic/OptimisticSettlementModule.sol";
import {IntentTestBase} from "../utils/IntentTestBase.sol";

/// @title SolverPaidUserNotFilled
/// @notice Every settlement mode fuzzed against the violation "the escrow is released although the user was not
/// filled (or to someone other than the filler)". IntentFuzz (Augusto et al., 2026) leaves this class to the
/// off-chain settlement layer as a "settlement exposure"; here settlement is on-chain, so it is tested directly.
contract SolverPaidUserNotFilled is IntentTestBase {
    // ------------------------------------------------------------------------------------------------------------
    // Mode 1: mailbox
    // ------------------------------------------------------------------------------------------------------------

    /// @dev Any report that does not come from the trusted reporter is rejected, whatever it claims.
    function testFuzz_mailbox_forgedReportNeverPays(address sender, address filler, bytes32 fillHash, uint64 filledAt)
        public
    {
        vm.assume(sender != address(reporter));
        (bytes32 orderId,) = _openOnchain(_params(address(mailboxModule)));
        vm.chainId(DEST);
        vm.recordLogs();
        vm.prank(sender);
        IMailbox(address(destMailbox))
            .dispatch(ORIGIN, address(mailboxModule), abi.encode(orderId, filler, fillHash, filledAt));
        bytes memory message = _lastDispatch();
        vm.chainId(ORIGIN);
        vm.prank(mailboxRelayer);
        vm.expectRevert(abi.encodeWithSelector(MailboxSettlementModule.UntrustedReporter.selector, DEST, sender));
        originMailbox.process(message);
        assertEq(uint8(origin.escrowOf(orderId).status), uint8(OrderStatus.Open));
    }

    /// @dev The trusted reporter reports exactly the orders that have a fill record, with the recorded filler, fill
    ///      time and fill hash; for every other id (open but unfilled, or never opened) it reverts. Several orders are
    ///      opened and some of them filled first, so "reports nothing" and "reports anything" both fail this test.
    function testFuzz_mailbox_reporterOnlyReportsRealFills(
        uint8 orderCount,
        uint256 fillMask,
        uint256 pick,
        bytes32 randomId
    ) public {
        uint256 n = bound(orderCount, 2, 6);
        bytes32[] memory ids = new bytes32[](n + 1);
        bool[] memory filled = new bool[](n + 1);
        address[] memory repayments = new address[](n + 1);
        for (uint256 i = 0; i < n; ++i) {
            bytes memory originData;
            (ids[i], originData) = _openOnchain(_params(address(mailboxModule)));
            // At least one filled and one unfilled order.
            filled[i] = i == 0 || (i != 1 && (fillMask >> i) & 1 == 1);
            repayments[i] = makeAddr(string.concat("repay", vm.toString(i)));
            if (filled[i]) _fill(ids[i], originData, solver, repayments[i]);
        }
        ids[n] = randomId; // never opened (collision with a real id has probability 2^-256)
        uint256 k = bound(pick, 0, n);

        vm.chainId(DEST);
        if (!filled[k]) {
            vm.expectRevert(abi.encodeWithSelector(MailboxFillReporter.OrderNotFilled.selector, ids[k]));
            reporter.report(ids[k], ORIGIN);
            return;
        }
        DestinationSettler.FillRecord memory record = dest.fillRecord(ids[k]);
        vm.recordLogs();
        reporter.report(ids[k], ORIGIN);
        MockMailbox.Message memory message = abi.decode(_lastDispatch(), (MockMailbox.Message));
        (bytes32 reportedId, address reportedFiller, bytes32 reportedHash, uint64 reportedAt) =
            abi.decode(message.body, (bytes32, address, bytes32, uint64));
        assertEq(reportedId, ids[k]);
        assertEq(reportedFiller, repayments[k], "reports the recorded filler");
        assertEq(reportedHash, record.fillHash);
        assertEq(reportedAt, record.filledAt);
        assertEq(message.sender, address(reporter));
        assertEq(message.recipient, address(mailboxModule));
    }

    // ------------------------------------------------------------------------------------------------------------
    // Mode 2: optimistic
    // ------------------------------------------------------------------------------------------------------------

    /// @dev Whatever an attacker asserts about an order (filled or not), if it differs from the destination
    ///      record an honest watcher wins the challenge, and only the real filler can end up repaid.
    function testFuzz_optimistic_everyFalseClaimLoses(
        bool filled,
        address claimedFiller,
        uint256 claimedAtSeed,
        uint256 delay
    ) public {
        vm.assume(claimedFiller != address(0));
        OrderParams memory p = _params(address(optimistic));
        (bytes32 orderId, bytes memory originData) = _openOnchain(p);
        vm.warp(block.timestamp + bound(delay, 0, 500));
        if (filled) _fill(orderId, originData, solver, solverRepayment);
        uint64 actualAt = filled ? uint64(block.timestamp) : 0;
        uint64 claimedAt = uint64(bound(claimedAtSeed, 0, block.timestamp));
        vm.assume(!(filled && claimedFiller == solverRepayment && claimedAt == actualAt));

        _claimAs(rival, orderId, originData, claimedFiller, claimedAt);
        // The real filler's claim can be pending at the same time: the false one does not block it.
        if (filled) _claimAs(solver, orderId, originData, solverRepayment, actualAt);

        vm.warp(block.timestamp + 1);
        DestProof memory proof = _relayDestState(orderId);
        vm.prank(challenger);
        optimistic.challenge(orderId, claimedFiller, claimedAt, proof.blockNumber, proof.accountProof, proof.slotProof);
        assertEq(bondToken.balanceOf(challenger), BOND, "challenger wins the bond");
        assertEq(uint8(origin.escrowOf(orderId).status), uint8(OrderStatus.Open), "escrow untouched");

        if (filled) {
            vm.warp(block.timestamp + CHALLENGE_WINDOW + 1);
            optimistic.finalize(orderId, solverRepayment, actualAt);
            assertEq(inputToken.balanceOf(solverRepayment), p.inputAmount);
        } else {
            vm.warp(uint256(p.fillDeadline) + REFUND_GRACE + 1);
            origin.refund(orderId);
            assertEq(inputToken.balanceOf(user), p.inputAmount);
        }
    }

    /// @dev An honest claim cannot be griefed: every challenge against it fails, whichever header is used.
    function testFuzz_optimistic_honestClaimSurvives(uint256 delay) public {
        OrderParams memory p = _params(address(optimistic));
        (bytes32 orderId, bytes memory originData) = _openOnchain(p);
        _fill(orderId, originData, solver, solverRepayment);
        uint64 filledAt = uint64(block.timestamp);
        _claimAs(solver, orderId, originData, solverRepayment, filledAt);

        vm.warp(block.timestamp + bound(delay, 1, CHALLENGE_WINDOW));
        DestProof memory proof = _relayDestState(orderId);
        vm.prank(rival);
        vm.expectRevert(abi.encodeWithSelector(OptimisticSettlementModule.ClaimNotFraudulent.selector, orderId));
        optimistic.challenge(orderId, solverRepayment, filledAt, proof.blockNumber, proof.accountProof, proof.slotProof);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Mode 3: storage proof
    // ------------------------------------------------------------------------------------------------------------

    /// @dev No proof of an unfilled order's slot can pay anyone.
    function testFuzz_proof_unfilledOrderNeverPays(uint8 otherFills) public {
        OrderParams memory p = _params(address(proofModule));
        (bytes32 orderId, bytes memory originData) = _openGasless(p, 1);
        for (uint256 i = 0; i < bound(otherFills, 0, 6); ++i) {
            (bytes32 otherId, bytes memory otherData) = _openGasless(p, 100 + i);
            _fill(otherId, otherData, solver, solverRepayment);
        }
        DestProof memory proof = _relayDestState(orderId);
        _assertProofRejected(orderId, proof.blockNumber, keccak256(originData), proof.accountProof, proof.slotProof);
        assertEq(uint8(origin.escrowOf(orderId).status), uint8(OrderStatus.Open));
    }

    /// @dev Any single-byte change to a valid proof is rejected by the proof verification itself.
    function testFuzz_proof_tamperedProofNeverPays(bool account, uint256 nodeSeed, uint256 byteSeed, uint8 mask)
        public
    {
        vm.assume(mask != 0);
        OrderParams memory p = _params(address(proofModule));
        (bytes32 orderId, bytes memory originData) = _openGasless(p, 1);
        _fill(orderId, originData, solver, solverRepayment);
        DestProof memory proof = _relayDestState(orderId);
        bytes[] memory target = account ? proof.accountProof : proof.slotProof;
        bytes memory node = target[bound(nodeSeed, 0, target.length - 1)];
        uint256 pos = bound(byteSeed, 0, node.length - 1);
        node[pos] = bytes1(uint8(node[pos]) ^ mask);
        _assertProofRejected(orderId, proof.blockNumber, keccak256(originData), proof.accountProof, proof.slotProof);
        assertEq(uint8(origin.escrowOf(orderId).status), uint8(OrderStatus.Open));
    }

    /// @dev A valid proof always pays exactly the repayment address the filler recorded, whoever submits it.
    function testFuzz_proof_paysExactlyTheRecordedFiller(address repayment, address submitter) public {
        vm.assume(repayment != address(0) && repayment != address(origin));
        OrderParams memory p = _params(address(proofModule));
        (bytes32 orderId, bytes memory originData) = _openGasless(p, 1);
        _fill(orderId, originData, solver, repayment);
        DestProof memory proof = _relayDestState(orderId);
        uint256 before = inputToken.balanceOf(repayment);
        vm.prank(submitter);
        proofModule.proveFill(orderId, proof.blockNumber, keccak256(originData), proof.accountProof, proof.slotProof);
        assertEq(inputToken.balanceOf(repayment) - before, p.inputAmount);
        Escrow memory escrow = origin.escrowOf(orderId);
        assertEq(uint8(escrow.status), uint8(OrderStatus.Repaid));
    }

    /// @dev proveFill must revert, and with one of the proof verifiers' own errors (a trie traversal error, an RLP
    ///      decoding error or a malformed account), not with anything downstream such as a settlement check.
    function _assertProofRejected(
        bytes32 orderId,
        uint256 blockNumber,
        bytes32 fillHash,
        bytes[] memory accountProof,
        bytes[] memory slotProof
    ) internal {
        vm.chainId(ORIGIN);
        try proofModule.proveFill(orderId, blockNumber, fillHash, accountProof, slotProof) {
            revert("proof accepted");
        } catch (bytes memory reason) {
            bytes4 selector = bytes4(reason);
            assertTrue(
                selector == TrieProof.TrieProofTraversalError.selector || selector == RLP.RLPInvalidEncoding.selector
                    || selector == FillProofLib.MalformedAccount.selector,
                "rejected by the proof verifiers"
            );
        }
    }
}
