// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ReentrancyGuardTransient} from "@openzeppelin-contracts/utils/ReentrancyGuardTransient.sol";
import {SystemFixture} from "./utils/SystemFixture.sol";
import {OutputOracle} from "../src/OutputOracle.sol";
import {IOutputOracle} from "../src/interfaces/IOutputOracle.sol";
import {IBatchInbox} from "../src/interfaces/IBatchInbox.sol";
import {RollupSpec} from "../src/lib/RollupSpec.sol";

/// @dev Re-enters `claimCredit` from its receive hook.
contract ReentrantClaimer {
    OutputOracle internal immutable ORACLE;

    constructor(OutputOracle oracle) {
        ORACLE = oracle;
    }

    function claim() external {
        ORACLE.claimCredit();
    }

    receive() external payable {
        ORACLE.claimCredit();
    }
}

contract OutputOracleTest is SystemFixture {
    function test_propose_recordsAndEmits() public {
        _postEmptyBatch();
        vm.expectEmit(address(oracle));
        emit IOutputOracle.OutputProposed(1, 1, r42, RollupSpec.outputRoot(1, r42), proposer);
        uint256 id = _propose(proposer, 1, r42);
        IOutputOracle.Proposal memory p = oracle.getProposal(id);
        assertEq(p.stateRoot, r42);
        assertEq(p.proposer, proposer);
        assertEq(p.epoch, 1);
        assertEq(p.proposedAt, vm.getBlockTimestamp());
        assertEq(uint8(p.status), uint8(IOutputOracle.ProposalStatus.Proposed));
        assertEq(oracle.proposalIdAt(1), id);
        assertEq(oracle.nextEpoch(), 2);
        assertEq(oracle.lockedBonds(), PROPOSER_BOND);
        assertEq(oracle.outputRootAt(1), RollupSpec.outputRoot(1, r42));
        assertEq(oracle.outputRootAt(0), RollupSpec.outputRoot(0, bytes32(0)));
        vm.expectRevert(abi.encodeWithSelector(IOutputOracle.UnknownEpoch.selector, 2));
        oracle.outputRootAt(2);
        assertTrue(oracle.isLive(id));
    }

    function test_revert_proposeChecks() public {
        vm.prank(proposer);
        vm.expectRevert(abi.encodeWithSelector(IOutputOracle.IncorrectBond.selector, PROPOSER_BOND, 1));
        oracle.propose{value: 1}(1, r42);
        vm.prank(proposer);
        vm.expectRevert(abi.encodeWithSelector(IOutputOracle.EpochNotPosted.selector, 1, 0));
        oracle.propose{value: PROPOSER_BOND}(1, r42);
        _postEmptyBatch();
        vm.prank(proposer);
        vm.expectRevert(abi.encodeWithSelector(IOutputOracle.NotNextEpoch.selector, 1, 2));
        oracle.propose{value: PROPOSER_BOND}(2, r42);
    }

    function test_finalize_afterWindowRefundsBond() public {
        _postEmptyBatch();
        uint256 id = _propose(proposer, 1, r42);
        vm.warp(vm.getBlockTimestamp() + CHALLENGE_WINDOW - 1);
        vm.expectRevert(abi.encodeWithSelector(IOutputOracle.CannotFinalize.selector, 1));
        oracle.finalize(1);
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.expectEmit(address(oracle));
        emit IOutputOracle.OutputFinalized(id, 1);
        oracle.finalize(1);
        assertEq(oracle.lastFinalizedEpoch(), 1);
        assertEq(oracle.finalizedStateRoot(1), r42);
        assertEq(oracle.finalizedStateRoot(0), bytes32(0));
        assertEq(oracle.credit(proposer), PROPOSER_BOND);
        assertFalse(oracle.isLive(id));

        uint256 before = proposer.balance;
        vm.prank(proposer);
        oracle.claimCredit();
        assertEq(proposer.balance, before + PROPOSER_BOND);
        assertEq(address(oracle).balance, 0);
    }

    function test_revert_finalizeChecks() public {
        _postEmptyBatch();
        _postEmptyBatch();
        _propose(proposer, 1, r42);
        _propose(proposer, 2, r42);
        _challenge(challenger, 1);
        vm.warp(vm.getBlockTimestamp() + CHALLENGE_WINDOW);
        vm.expectRevert(abi.encodeWithSelector(IOutputOracle.CannotFinalize.selector, 2));
        oracle.finalize(2); // out of order
        vm.expectRevert(abi.encodeWithSelector(IOutputOracle.CannotFinalize.selector, 1));
        oracle.finalize(1); // open dispute
        vm.expectRevert(abi.encodeWithSelector(IOutputOracle.CannotFinalize.selector, 3));
        oracle.finalize(3); // does not exist
        vm.expectRevert(abi.encodeWithSelector(IOutputOracle.NotFinalized.selector, 1));
        oracle.finalizedStateRoot(1);
    }

    function test_revert_claimWithoutCredit() public {
        vm.expectRevert(IOutputOracle.NoCredit.selector);
        oracle.claimCredit();
    }

    function test_claimCredit_isReentrancySafe() public {
        ReentrantClaimer attacker = new ReentrantClaimer(oracle);
        vm.deal(address(attacker), 10 ether);
        _postEmptyBatch();
        vm.prank(address(attacker));
        oracle.propose{value: PROPOSER_BOND}(1, r42);
        vm.warp(vm.getBlockTimestamp() + CHALLENGE_WINDOW);
        oracle.finalize(1);
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        attacker.claim();
        assertEq(oracle.credit(address(attacker)), PROPOSER_BOND, "credit untouched after the failed claim");
    }

    function test_revert_reclaimLiveBond() public {
        _postEmptyBatch();
        uint256 id = _propose(proposer, 1, r42);
        vm.expectRevert(abi.encodeWithSelector(IOutputOracle.NotOrphaned.selector, id));
        oracle.reclaimOrphanedBond(id);
        vm.expectRevert(abi.encodeWithSelector(IOutputOracle.NotOrphaned.selector, 99));
        oracle.reclaimOrphanedBond(99);
    }

    function test_revert_onlyDisputeGame() public {
        vm.expectRevert(abi.encodeWithSelector(IOutputOracle.OnlyDisputeGame.selector, address(this)));
        oracle.openChallenge(1, address(this));
        vm.expectRevert(abi.encodeWithSelector(IOutputOracle.OnlyDisputeGame.selector, address(this)));
        oracle.settleChallenge(1, address(this), 0, IOutputOracle.Outcome.ChallengerWins);
    }

    function test_revert_constructorZeroParameters() public {
        vm.expectRevert(IOutputOracle.ZeroParameter.selector);
        new OutputOracle(IBatchInbox(address(0)), address(game), 0, 1, 1);
        vm.expectRevert(IOutputOracle.ZeroParameter.selector);
        new OutputOracle(inbox, address(game), 0, 0, 1);
        vm.expectRevert(IOutputOracle.ZeroParameter.selector);
        new OutputOracle(inbox, address(game), 0, 1, 0);
    }

    function test_invalidationTruncatesAndReproposalWorks() public {
        _postEmptyBatch();
        _postEmptyBatch();
        uint256 bad = _propose(proposer, 1, keccak256("bad"));
        uint256 child = _propose(proposer, 2, keccak256("child"));
        uint256 g = _challenge(challenger, 1);
        vm.warp(vm.getBlockTimestamp() + CLOCK + 1);
        game.claimTimeout(g);
        assertEq(uint8(oracle.getProposal(bad).status), uint8(IOutputOracle.ProposalStatus.Invalidated));
        assertEq(oracle.nextEpoch(), 1);
        assertFalse(oracle.isLive(child));

        address honestProposer = makeAddr("honest");
        vm.deal(honestProposer, 10 ether);
        uint256 good = _propose(honestProposer, 1, r42);
        assertEq(oracle.proposalIdAt(1), good);
        oracle.reclaimOrphanedBond(child);
        assertEq(uint8(oracle.getProposal(child).status), uint8(IOutputOracle.ProposalStatus.Orphaned));
        // Books: locked = honest bond; credits = challenger payout + orphan refund; burned = 10% of the slashed bond.
        assertEq(oracle.lockedBonds(), PROPOSER_BOND);
        assertEq(address(oracle).balance, oracle.lockedBonds() + oracle.totalCredit() + oracle.totalBurned());
    }
}
