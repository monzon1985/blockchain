// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import {RLP} from "@openzeppelin-contracts/utils/RLP.sol";
import {TrieProof} from "@openzeppelin-contracts/utils/cryptography/TrieProof.sol";

import {OriginSettler} from "../../src/OriginSettler.sol";
import {IEscrowSettler, OrderStatus} from "../../src/interfaces/IEscrowSettler.sol";
import {FillProofLib} from "../../src/libraries/FillProofLib.sol";
import {OptimisticSettlementModule} from "../../src/settlement/optimistic/OptimisticSettlementModule.sol";
import {HeaderStore} from "../../src/settlement/proof/HeaderStore.sol";
import {IntentTestBase} from "../utils/IntentTestBase.sol";

/// @notice The dispute game of settlement mode 2.
contract OptimisticSettlementTest is IntentTestBase {
    OrderParams internal p;
    bytes32 internal orderId;
    bytes internal originData;

    function setUp() public override {
        super.setUp();
        p = _params(address(optimistic));
        (orderId, originData) = _openOnchain(p);
    }

    function _claim(address claimant, address filler, uint64 filledAt) internal {
        _claimAs(claimant, orderId, originData, filler, filledAt);
    }

    function _challenge(address who, address filler, uint64 filledAt, DestProof memory proof) internal {
        vm.chainId(ORIGIN);
        vm.prank(who);
        optimistic.challenge(orderId, filler, filledAt, proof.blockNumber, proof.accountProof, proof.slotProof);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Happy path
    // ------------------------------------------------------------------------------------------------------------

    function test_claimThenFinalize_repaysFillerAndReturnsBond() public {
        _fill(orderId, originData, solver, solverRepayment);
        uint64 filledAt = uint64(block.timestamp);
        vm.chainId(ORIGIN);
        bondToken.mint(solver, BOND);
        vm.startPrank(solver);
        bondToken.approve(address(optimistic), BOND);
        vm.expectEmit(address(optimistic));
        emit OptimisticSettlementModule.Claimed(
            orderId, solver, solverRepayment, filledAt, uint64(block.timestamp + CHALLENGE_WINDOW)
        );
        bytes32 claimId = optimistic.claim(orderId, solverRepayment, filledAt, keccak256(originData));
        vm.stopPrank();

        assertEq(claimId, keccak256(abi.encode(orderId, solverRepayment, filledAt)), "claim id");
        assertEq(claimId, optimistic.claimIdOf(orderId, solverRepayment, filledAt));
        assertTrue(optimistic.hasPendingClaim(orderId));
        assertEq(optimistic.pendingClaims(orderId), 1);
        assertEq(bondToken.balanceOf(address(optimistic)), BOND);
        OptimisticSettlementModule.Claim memory claim = optimistic.claimOf(orderId, solverRepayment, filledAt);
        assertEq(claim.claimant, solver);
        assertEq(claim.fillHash, keccak256(originData));

        vm.expectRevert(
            abi.encodeWithSelector(OptimisticSettlementModule.ChallengeWindowOpen.selector, claim.challengeDeadline)
        );
        optimistic.finalize(orderId, solverRepayment, filledAt);

        vm.warp(uint256(claim.challengeDeadline) + 1);
        vm.expectEmit(address(optimistic));
        emit OptimisticSettlementModule.ClaimFinalized(orderId, solverRepayment, solver, filledAt);
        vm.prank(rival); // permissionless
        optimistic.finalize(orderId, solverRepayment, filledAt);

        assertEq(inputToken.balanceOf(solverRepayment), p.inputAmount);
        assertEq(bondToken.balanceOf(solver), BOND);
        assertFalse(optimistic.hasPendingClaim(orderId));
        assertEq(optimistic.claimOf(orderId, solverRepayment, filledAt).claimant, address(0));
        assertEq(uint8(origin.escrowOf(orderId).status), uint8(OrderStatus.Repaid));
    }

    // ------------------------------------------------------------------------------------------------------------
    // Challenges
    // ------------------------------------------------------------------------------------------------------------

    function test_challenge_unfilledOrderWithExclusionProof() public {
        uint64 claimedAt = uint64(block.timestamp);
        _claim(rival, rival, claimedAt);
        vm.warp(block.timestamp + 1);
        DestProof memory proof = _relayDestState(orderId);

        vm.expectEmit(address(optimistic));
        emit OptimisticSettlementModule.ClaimChallenged(orderId, challenger, rival, rival, claimedAt, address(0), 0);
        _challenge(challenger, rival, claimedAt, proof);

        assertEq(bondToken.balanceOf(challenger), BOND);
        assertFalse(optimistic.hasPendingClaim(orderId));
        assertEq(uint8(origin.escrowOf(orderId).status), uint8(OrderStatus.Open));

        // Nobody fills: the user gets the refund once the grace period is over.
        vm.warp(uint256(p.fillDeadline) + REFUND_GRACE + 1);
        origin.refund(orderId);
        assertEq(inputToken.balanceOf(user), p.inputAmount);
    }

    function test_challenge_wrongFillerWithInclusionProof() public {
        _fill(orderId, originData, solver, solverRepayment);
        uint64 filledAt = uint64(block.timestamp);
        _claim(rival, rival, filledAt); // front-runs the real filler with itself as payee
        _claim(solver, solverRepayment, filledAt); // ...which does not stop the real filler's claim
        assertEq(optimistic.pendingClaims(orderId), 2);
        vm.warp(block.timestamp + 1);
        DestProof memory proof = _relayDestState(orderId);

        vm.expectEmit(address(optimistic));
        emit OptimisticSettlementModule.ClaimChallenged(
            orderId, solver, rival, rival, filledAt, solverRepayment, filledAt
        );
        _challenge(solver, rival, filledAt, proof); // the real filler defends its order and takes the bond
        assertEq(bondToken.balanceOf(solver), BOND);

        vm.warp(block.timestamp + CHALLENGE_WINDOW + 1);
        optimistic.finalize(orderId, solverRepayment, filledAt);
        assertEq(inputToken.balanceOf(solverRepayment), p.inputAmount);
        assertEq(bondToken.balanceOf(solver), 2 * BOND, "its own bond back plus the rival's");
    }

    function test_challenge_wrongFillTime() public {
        _fill(orderId, originData, solver, solverRepayment);
        uint64 filledAt = uint64(block.timestamp);
        _claim(solver, solverRepayment, filledAt - 1);
        vm.warp(block.timestamp + 1);
        DestProof memory proof = _relayDestState(orderId);
        _challenge(challenger, solverRepayment, filledAt - 1, proof);
        assertEq(bondToken.balanceOf(challenger), BOND);
    }

    function test_challenge_failsAgainstHonestClaim() public {
        _fill(orderId, originData, solver, solverRepayment);
        uint64 filledAt = uint64(block.timestamp);
        _claim(solver, solverRepayment, filledAt);
        vm.warp(block.timestamp + 1);
        DestProof memory proof = _relayDestState(orderId);
        vm.expectRevert(abi.encodeWithSelector(OptimisticSettlementModule.ClaimNotFraudulent.selector, orderId));
        _challenge(challenger, solverRepayment, filledAt, proof);
    }

    function test_challenge_needsHeaderAfterClaimedFillTime() public {
        uint64 claimedAt = uint64(block.timestamp);
        _claim(rival, rival, claimedAt);
        DestProof memory proof = _relayDestState(orderId); // same timestamp as the claimed fill
        vm.expectRevert(
            abi.encodeWithSelector(OptimisticSettlementModule.HeaderNotAfterFill.selector, claimedAt, claimedAt)
        );
        _challenge(challenger, rival, claimedAt, proof);
    }

    function test_challenge_rejectsUnknownHeader() public {
        _claim(rival, rival, uint64(block.timestamp));
        vm.expectRevert(abi.encodeWithSelector(HeaderStore.UnknownHeader.selector, DEST, 12345));
        optimistic.challenge(orderId, rival, uint64(block.timestamp), 12345, new bytes[](0), new bytes[](0));
    }

    function test_challenge_rejectsProofOfAnotherSlot() public {
        (bytes32 otherId, bytes memory otherData) = _openOnchain(p);
        _fill(otherId, otherData, solver, solverRepayment);
        uint64 claimedAt = uint64(block.timestamp);
        _claim(rival, rival, claimedAt);
        vm.warp(block.timestamp + 1);
        // A valid proof, but of the other order's (filled) slot: the exclusion walker rejects it (the path of this
        // order's key does not end in the last node), and OpenZeppelin's traversal then fails decoding the other
        // key's leaf as a node on this key's path.
        DestProof memory proof = _relayDestState(otherId);
        vm.expectRevert(RLP.RLPInvalidEncoding.selector);
        _challenge(challenger, rival, claimedAt, proof);
    }

    function test_challenge_windowCloses() public {
        uint64 claimedAt = uint64(block.timestamp);
        _claim(rival, rival, claimedAt);
        OptimisticSettlementModule.Claim memory claim = optimistic.claimOf(orderId, rival, claimedAt);
        vm.warp(uint256(claim.challengeDeadline) + 1);
        DestProof memory proof = _relayDestState(orderId);
        vm.expectRevert(
            abi.encodeWithSelector(OptimisticSettlementModule.ChallengeWindowClosed.selector, claim.challengeDeadline)
        );
        _challenge(challenger, rival, claimedAt, proof);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Regression: fraud proofs against a header from before the settler existed (watchtower blinding)
    // ------------------------------------------------------------------------------------------------------------

    /// @dev The attack of the first review: the header relayer is honest, but anyone can import ancestors of a
    ///      stored header down to a block where the DestinationSettler did not exist yet, and a false claim may say
    ///      `filledAt = 0`. The OLDEST header after the claimed time is then pre-deployment. Its account proof is an
    ///      exclusion proof of the settler, and an absent account has no storage, so the claim is disproven there too.
    function test_challenge_withPreDeploymentAncestor_accountExclusionDisprovesClaim() public {
        vm.warp(block.timestamp + 100);
        _claim(rival, rival, 0);
        (DestProof memory ancestor,) = _relayWithPreDeploymentAncestor(orderId, block.timestamp - 50);
        assertEq(headers.header(DEST, ancestor.blockNumber).timestamp, block.timestamp - 50, "ancestor imported");

        vm.expectEmit(address(optimistic));
        emit OptimisticSettlementModule.ClaimChallenged(orderId, challenger, rival, rival, 0, address(0), 0);
        _challenge(challenger, rival, 0, ancestor);
        assertEq(bondToken.balanceOf(challenger), BOND);
        assertFalse(optimistic.hasPendingClaim(orderId));
    }

    /// @dev The same with the storage proof anvil returns for an account that does not exist: the single empty-trie
    ///      node 0x80 instead of no node at all.
    function test_challenge_withPreDeploymentAncestor_emptyTrieNodeAsSlotProof() public {
        vm.warp(block.timestamp + 100);
        _claim(rival, rival, 0);
        (DestProof memory ancestor,) = _relayWithPreDeploymentAncestor(orderId, block.timestamp - 50);
        ancestor.slotProof = new bytes[](1);
        ancestor.slotProof[0] = hex"80";
        _challenge(challenger, rival, 0, ancestor);
        assertEq(bondToken.balanceOf(challenger), BOND);
    }

    /// @dev ...and the newest header works as well, so a watcher never depends on the oldest one.
    function test_challenge_withNewestHeaderAfterAncestorImport() public {
        vm.warp(block.timestamp + 100);
        _claim(rival, rival, 0);
        (, DestProof memory child) = _relayWithPreDeploymentAncestor(orderId, block.timestamp - 50);
        _challenge(challenger, rival, 0, child);
        assertEq(bondToken.balanceOf(challenger), BOND);
    }

    /// @dev A pre-deployment header can never disprove an honest claim: it is older than any real fill.
    function test_challenge_preDeploymentAncestorCannotDisproveHonestClaim() public {
        vm.warp(block.timestamp + 100);
        _fill(orderId, originData, solver, solverRepayment);
        uint64 filledAt = uint64(block.timestamp);
        _claim(solver, solverRepayment, filledAt);
        vm.warp(block.timestamp + 1);
        (DestProof memory ancestor,) = _relayWithPreDeploymentAncestor(orderId, filledAt - 50);
        vm.expectRevert(
            abi.encodeWithSelector(OptimisticSettlementModule.HeaderNotAfterFill.selector, filledAt - 50, filledAt)
        );
        _challenge(challenger, solverRepayment, filledAt, ancestor);
    }

    /// @dev An account exclusion proof only counts against the state root it was built for.
    function test_challenge_rejectsAccountExclusionAgainstStateWhereSettlerExists() public {
        vm.warp(block.timestamp + 100);
        _claim(rival, rival, 0);
        (DestProof memory ancestor, DestProof memory child) =
            _relayWithPreDeploymentAncestor(orderId, block.timestamp - 50);
        child.accountProof = ancestor.accountProof;
        vm.expectRevert(
            abi.encodeWithSelector(TrieProof.TrieProofTraversalError.selector, TrieProof.ProofError.INVALID_ROOT)
        );
        _challenge(challenger, rival, 0, child);
    }

    /// @dev An empty slot proof does not let a challenger skip the storage proof: with the settler present, its
    ///      storage root must itself be empty for the slot to count as empty.
    function test_challenge_emptySlotProofCannotSkipTheStorageProof() public {
        _fill(orderId, originData, solver, solverRepayment);
        uint64 filledAt = uint64(block.timestamp);
        _claim(solver, solverRepayment, filledAt);
        vm.warp(block.timestamp + 1);
        DestProof memory proof = _relayDestState(orderId);
        proof.slotProof = new bytes[](0);
        vm.expectRevert(
            abi.encodeWithSelector(FillProofLib.InvalidSlotProof.selector, FillProofLib.fillerSlot(orderId))
        );
        _challenge(challenger, solverRepayment, filledAt, proof);
        proof.slotProof = new bytes[](1);
        proof.slotProof[0] = hex"80"; // the empty-trie node, as anvil returns for an empty storage trie
        vm.expectRevert(
            abi.encodeWithSelector(FillProofLib.InvalidSlotProof.selector, FillProofLib.fillerSlot(orderId))
        );
        _challenge(challenger, solverRepayment, filledAt, proof);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Regression: a false claim cannot squat the real filler's claim (claim slot per order, review finding)
    // ------------------------------------------------------------------------------------------------------------

    /// @dev The user keeps posting false claims about its own order until the refund opens, each one disproven by
    ///      the watcher within its window (the documented trust assumption), hoping to refund right after its last
    ///      false claim. The real filler's claim is keyed by its own (filler, filledAt), so it lands at once, stays
    ///      pending, blocks the refund, and repays the filler.
    function test_claimSquatting_cannotBlockTheRealFillerNorWinTheRefund() public {
        vm.warp(block.timestamp + 100);
        uint256 delivered = _fill(orderId, originData, solver, solverRepayment);
        uint64 filledAt = uint64(block.timestamp);

        _claim(user, user, filledAt); // squat first
        _claim(solver, solverRepayment, filledAt); // the real claim is not blocked
        assertEq(optimistic.pendingClaims(orderId), 2);

        uint256 falseClaims = 1;
        uint64 squatAt = filledAt;
        while (block.timestamp + CHALLENGE_WINDOW / 2 <= uint256(p.fillDeadline) + REFUND_GRACE) {
            vm.warp(block.timestamp + CHALLENGE_WINDOW / 2);
            DestProof memory proof = _relayDestState(orderId);
            _challenge(challenger, user, squatAt, proof); // the watcher disproves each false claim in time
            // The honest claim finalizes as soon as its window is over; afterwards the order is closed.
            OptimisticSettlementModule.Claim memory honest = optimistic.claimOf(orderId, solverRepayment, filledAt);
            if (honest.claimant != address(0) && block.timestamp > honest.challengeDeadline) {
                optimistic.finalize(orderId, solverRepayment, filledAt);
            }
            if (origin.escrowOf(orderId).status != OrderStatus.Open) break;
            squatAt = uint64(block.timestamp < p.fillDeadline ? block.timestamp : p.fillDeadline);
            _claim(user, user, squatAt);
            ++falseClaims;
        }

        assertEq(uint8(origin.escrowOf(orderId).status), uint8(OrderStatus.Repaid), "the filler was repaid");
        assertEq(inputToken.balanceOf(solverRepayment), p.inputAmount);
        assertEq(outputToken.balanceOf(recipient), delivered);
        assertEq(bondToken.balanceOf(challenger), falseClaims * BOND, "every false claim lost its bond");
        vm.warp(uint256(p.fillDeadline) + REFUND_GRACE + 1);
        vm.expectRevert(abi.encodeWithSelector(OriginSettler.OrderNotOpen.selector, orderId, OrderStatus.Repaid));
        origin.refund(orderId);
    }

    /// @dev While the real claim is pending the refund stays blocked, even after the last false claim is disproven.
    function test_claimSquatting_refundBlockedWhileRealClaimPending() public {
        _fill(orderId, originData, solver, solverRepayment);
        uint64 filledAt = uint64(block.timestamp);
        vm.warp(uint256(p.fillDeadline) + REFUND_GRACE - 10);
        _claim(solver, solverRepayment, filledAt);
        _claim(user, user, filledAt);
        vm.warp(uint256(p.fillDeadline) + REFUND_GRACE + 1);
        DestProof memory proof = _relayDestState(orderId);
        _challenge(user, user, filledAt, proof); // the user disproves its own claim to recover the bond...
        vm.expectRevert(abi.encodeWithSelector(OriginSettler.RepaymentClaimPending.selector, orderId));
        origin.refund(orderId); // ...but cannot refund while the real claim is pending
        vm.warp(block.timestamp + CHALLENGE_WINDOW);
        optimistic.finalize(orderId, solverRepayment, filledAt);
        assertEq(inputToken.balanceOf(solverRepayment), p.inputAmount);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Several claims of one order
    // ------------------------------------------------------------------------------------------------------------

    function test_claim_sameAssertionOnlyOnce() public {
        uint64 claimedAt = uint64(block.timestamp);
        _claim(solver, solverRepayment, claimedAt);
        bondToken.mint(rival, BOND);
        vm.startPrank(rival);
        bondToken.approve(address(optimistic), BOND);
        vm.expectRevert(
            abi.encodeWithSelector(
                OptimisticSettlementModule.ClaimAlreadyPending.selector, orderId, solverRepayment, claimedAt
            )
        );
        optimistic.claim(orderId, solverRepayment, claimedAt, keccak256(originData));
        // A different assertion about the same order is accepted.
        optimistic.claim(orderId, rival, claimedAt, keccak256(originData));
        vm.stopPrank();
        assertEq(optimistic.pendingClaims(orderId), 2);
        assertEq(bondToken.balanceOf(address(optimistic)), 2 * BOND);
    }

    /// @dev Once one claim has repaid the escrow, a surviving claim is voided: bond returned, nothing paid.
    function test_finalize_voidsClaimAfterAnotherClaimRepaid() public {
        _fill(orderId, originData, solver, solverRepayment);
        uint64 filledAt = uint64(block.timestamp);
        _claim(solver, solverRepayment, filledAt);
        vm.warp(block.timestamp + 10);
        _claim(rival, rival, filledAt); // never challenged: the watcher is not modelled here
        vm.warp(block.timestamp + CHALLENGE_WINDOW - 5);
        optimistic.finalize(orderId, solverRepayment, filledAt);
        assertEq(inputToken.balanceOf(solverRepayment), p.inputAmount);

        vm.warp(block.timestamp + 10);
        vm.expectEmit(address(optimistic));
        emit OptimisticSettlementModule.ClaimVoided(orderId, rival, rival, filledAt);
        optimistic.finalize(orderId, rival, filledAt);
        assertEq(bondToken.balanceOf(rival), BOND, "bond returned");
        assertEq(inputToken.balanceOf(rival), 0, "nothing paid");
        assertEq(optimistic.pendingClaims(orderId), 0);
        assertEq(bondToken.balanceOf(address(optimistic)), 0);
    }

    /// @dev A false claim can still be challenged after the order was repaid, so watchers keep their incentive.
    function test_challenge_stillPossibleAfterRepayment() public {
        _fill(orderId, originData, solver, solverRepayment);
        uint64 filledAt = uint64(block.timestamp);
        _claim(solver, solverRepayment, filledAt);
        vm.warp(block.timestamp + 10);
        _claim(rival, rival, filledAt);
        vm.warp(block.timestamp + CHALLENGE_WINDOW - 5);
        optimistic.finalize(orderId, solverRepayment, filledAt);
        DestProof memory proof = _relayDestState(orderId);
        _challenge(challenger, rival, filledAt, proof);
        assertEq(bondToken.balanceOf(challenger), BOND);
        assertEq(optimistic.pendingClaims(orderId), 0);
    }

    /// @dev Documents the trust assumption rather than a bug: with no honest watcher online during the window, a
    ///      false claim finalizes. The invariant suites model at least one honest challenger.
    function test_trustAssumption_unchallengedFraudFinalizes() public {
        _claim(rival, rival, uint64(block.timestamp));
        vm.warp(block.timestamp + CHALLENGE_WINDOW + 1);
        optimistic.finalize(orderId, rival, uint64(block.timestamp - CHALLENGE_WINDOW - 1));
        assertEq(inputToken.balanceOf(rival), p.inputAmount);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Claim validation
    // ------------------------------------------------------------------------------------------------------------

    function test_claim_rejectsOrdersOfOtherModulesAndClosedOrders() public {
        (bytes32 mailboxOrder, bytes memory mailboxData) = _openOnchain(_params(address(mailboxModule)));
        vm.expectRevert(abi.encodeWithSelector(OptimisticSettlementModule.OrderNotClaimable.selector, mailboxOrder));
        optimistic.claim(mailboxOrder, solver, uint64(block.timestamp), keccak256(mailboxData));

        vm.warp(uint256(p.fillDeadline) + REFUND_GRACE + 1);
        origin.refund(orderId);
        vm.expectRevert(abi.encodeWithSelector(OptimisticSettlementModule.OrderNotClaimable.selector, orderId));
        optimistic.claim(orderId, solver, uint64(p.fillDeadline), keccak256(originData));
    }

    function test_claim_rejectsBadFields() public {
        vm.expectRevert(
            abi.encodeWithSelector(OptimisticSettlementModule.FillHashMismatch.selector, orderId, bytes32(uint256(1)))
        );
        optimistic.claim(orderId, solver, uint64(block.timestamp), bytes32(uint256(1)));

        vm.expectRevert(OptimisticSettlementModule.ZeroFiller.selector);
        optimistic.claim(orderId, address(0), uint64(block.timestamp), keccak256(originData));

        vm.expectRevert(
            abi.encodeWithSelector(
                OptimisticSettlementModule.InvalidFillTime.selector, uint64(block.timestamp + 1), block.timestamp
            )
        );
        optimistic.claim(orderId, solver, uint64(block.timestamp + 1), keccak256(originData));

        vm.warp(uint256(p.fillDeadline) + 10);
        vm.expectRevert(
            abi.encodeWithSelector(
                OptimisticSettlementModule.InvalidFillTime.selector, uint64(p.fillDeadline + 1), p.fillDeadline
            )
        );
        optimistic.claim(orderId, solver, uint64(p.fillDeadline + 1), keccak256(originData));
    }

    function test_noPendingClaim() public {
        vm.expectRevert(
            abi.encodeWithSelector(OptimisticSettlementModule.NoPendingClaim.selector, orderId, solver, uint64(7))
        );
        optimistic.finalize(orderId, solver, 7);
        vm.expectRevert(
            abi.encodeWithSelector(OptimisticSettlementModule.NoPendingClaim.selector, orderId, solver, uint64(7))
        );
        optimistic.challenge(orderId, solver, 7, 1, new bytes[](0), new bytes[](0));
    }

    function test_constructor_rejectsBadConfiguration() public {
        IEscrowSettler settler = IEscrowSettler(address(origin));
        address auth = address(originManager);
        vm.expectRevert(OptimisticSettlementModule.InvalidConfiguration.selector);
        new OptimisticSettlementModule(IEscrowSettler(address(0)), headers, bondToken, BOND, CHALLENGE_WINDOW, auth);
        vm.expectRevert(OptimisticSettlementModule.InvalidConfiguration.selector);
        new OptimisticSettlementModule(settler, HeaderStore(address(0)), bondToken, BOND, CHALLENGE_WINDOW, auth);
        vm.expectRevert(OptimisticSettlementModule.InvalidConfiguration.selector);
        new OptimisticSettlementModule(settler, headers, IERC20(address(0)), BOND, CHALLENGE_WINDOW, auth);
        vm.expectRevert(OptimisticSettlementModule.InvalidConfiguration.selector);
        new OptimisticSettlementModule(settler, headers, bondToken, 0, CHALLENGE_WINDOW, auth);
        vm.expectRevert(OptimisticSettlementModule.InvalidConfiguration.selector);
        new OptimisticSettlementModule(settler, headers, bondToken, BOND, 0, auth);
        vm.expectRevert(OptimisticSettlementModule.InvalidConfiguration.selector);
        new OptimisticSettlementModule(settler, headers, bondToken, BOND, uint256(type(uint32).max) + 1, auth);
    }

    function test_refundWaitsForFinalization() public {
        _fill(orderId, originData, solver, solverRepayment);
        uint64 filledAt = uint64(block.timestamp);
        _claim(solver, solverRepayment, filledAt);
        vm.warp(uint256(p.fillDeadline) + REFUND_GRACE + CHALLENGE_WINDOW + 1);
        vm.expectRevert(abi.encodeWithSelector(OriginSettler.RepaymentClaimPending.selector, orderId));
        origin.refund(orderId);
        optimistic.finalize(orderId, solverRepayment, filledAt);
        assertEq(inputToken.balanceOf(solverRepayment), p.inputAmount);
    }
}
