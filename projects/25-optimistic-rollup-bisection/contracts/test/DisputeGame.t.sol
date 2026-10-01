// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {SystemFixture} from "./utils/SystemFixture.sol";
import {DisputeGame} from "../src/DisputeGame.sol";
import {IDisputeGame} from "../src/interfaces/IDisputeGame.sol";
import {IOutputOracle} from "../src/interfaces/IOutputOracle.sol";
import {IBatchInbox} from "../src/interfaces/IBatchInbox.sol";
import {IOneStepVM} from "../src/interfaces/IOneStepVM.sol";
import {Machine, StepProof} from "../src/lib/Types.sol";
import {VmSpec} from "../src/lib/VmSpec.sol";

contract DisputeGameTest is SystemFixture {
    uint64 internal epoch;

    function setUp() public override {
        super.setUp();
        epoch = uint64(_postEmptyBatch());
        _computeHonestTrace(epoch);
    }

    // ---- full games -----------------------------------------------------------------------------------------------

    function test_fraudulentOutput_bisectionFindsTheLastStep_challengerWins() public {
        bytes32 fake = keccak256("minted");
        uint256 pid = _propose(proposer, epoch, fake);
        uint256 id = _challenge(challenger, epoch);
        assertEq(game.getGame(id).loHash, _honestHash(0), "step 0 is computed on L1");

        vm.prank(proposer);
        game.commitEnd(id, _endWithRoot(fake));
        _playHonestChallenger(id, true); // honest midpoints, dishonest end: disagreement is at the last step
        (uint64 lo, uint64 hi) = _range(id);
        assertEq(hi - lo, 1);
        assertEq(lo, 7);
        _stepAtLeaf(id);

        DisputeGame.Game memory g = game.getGame(id);
        assertEq(uint8(g.phase), uint8(IDisputeGame.Phase.Resolved));
        assertEq(uint8(g.outcome), uint8(IOutputOracle.Outcome.ChallengerWins));
        assertEq(g.moves, 2 * MAX_DEPTH + 2);
        assertEq(uint8(oracle.getProposal(pid).status), uint8(IOutputOracle.ProposalStatus.Invalidated));
        assertEq(oracle.nextEpoch(), epoch, "chain truncated back to the invalid epoch");
        // challenger: own bond + 90% of the proposer bond; 10% burned
        assertEq(oracle.credit(challenger), CHALLENGER_BOND + PROPOSER_BOND * 9 / 10);
        assertEq(oracle.totalBurned(), PROPOSER_BOND / 10);
    }

    function test_lyingDefenderMidpoints_divergenceAtFirstStep() public {
        _propose(proposer, epoch, keccak256("fake"));
        uint256 id = _challenge(challenger, epoch);
        vm.prank(proposer);
        game.commitEnd(id, _endWithRoot(keccak256("fake")));
        _playHonestChallenger(id, false);
        (uint64 lo, uint64 hi) = _range(id);
        assertEq(lo, 0);
        assertEq(hi, 1);
        _stepAtLeaf(id);
        assertEq(uint8(game.getGame(id).outcome), uint8(IOutputOracle.Outcome.ChallengerWins));
    }

    function test_honestDefender_beatsLyingChallenger() public {
        uint256 pid = _propose(proposer, epoch, r42);
        uint256 id = _challenge(challenger, epoch);
        vm.prank(proposer);
        game.commitEnd(id, honest[4]);
        for (uint256 round = 0; round < MAX_DEPTH; ++round) {
            (uint64 lo, uint64 hi) = _range(id);
            uint64 mid = lo + (hi - lo) / 2;
            vm.prank(proposer);
            game.bisect(id, _honestHash(mid));
            vm.prank(challenger);
            game.choose(id, false); // always disagrees
        }
        // Anyone may execute the step; the defender does it to end the game early.
        vm.prank(proposer);
        _stepAtLeaf(id);
        assertEq(uint8(game.getGame(id).outcome), uint8(IOutputOracle.Outcome.DefenderWins));
        assertEq(oracle.credit(proposer), CHALLENGER_BOND * 9 / 10);
        assertEq(oracle.getProposal(pid).activeGames, 0);

        // The output then finalizes normally and the bond is returned.
        vm.warp(vm.getBlockTimestamp() + CHALLENGE_WINDOW);
        oracle.finalize(epoch);
        assertEq(oracle.credit(proposer), CHALLENGER_BOND * 9 / 10 + PROPOSER_BOND);
    }

    function test_defenderTimeout_onCommitEnd() public {
        _propose(proposer, epoch, keccak256("fake"));
        uint256 id = _challenge(challenger, epoch);
        assertEq(game.toMove(id), proposer);
        uint256 dl = game.deadline(id);
        vm.warp(dl);
        vm.expectRevert(abi.encodeWithSelector(IDisputeGame.ClockNotExpired.selector, id, dl));
        game.claimTimeout(id);
        vm.warp(dl + 1);
        game.claimTimeout(id);
        assertEq(uint8(game.getGame(id).outcome), uint8(IOutputOracle.Outcome.ChallengerWins));
        assertEq(game.toMove(id), address(0));
    }

    function test_challengerTimeout_onChoice() public {
        _propose(proposer, epoch, r42);
        uint256 id = _challenge(challenger, epoch);
        vm.prank(proposer);
        game.commitEnd(id, honest[4]);
        vm.prank(proposer);
        game.bisect(id, _honestHash(4));
        assertEq(game.toMove(id), challenger);
        vm.warp(vm.getBlockTimestamp() + CLOCK + 1);
        vm.prank(challenger);
        vm.expectRevert(abi.encodeWithSelector(IDisputeGame.ClockExpired.selector, id));
        game.choose(id, true);
        game.claimTimeout(id);
        assertEq(uint8(game.getGame(id).outcome), uint8(IOutputOracle.Outcome.DefenderWins));
    }

    function test_chessClock_chargesOnlyTheMover() public {
        _propose(proposer, epoch, r42);
        uint256 id = _challenge(challenger, epoch);
        vm.warp(vm.getBlockTimestamp() + 100);
        vm.prank(proposer);
        game.commitEnd(id, honest[4]);
        vm.warp(vm.getBlockTimestamp() + 50);
        vm.prank(proposer);
        game.bisect(id, _honestHash(4));
        vm.warp(vm.getBlockTimestamp() + 30);
        vm.prank(challenger);
        game.choose(id, true);
        DisputeGame.Game memory g = game.getGame(id);
        assertEq(g.defenderClock, CLOCK - 150);
        assertEq(g.challengerClock, CLOCK - 30);
    }

    function test_stepAfterChallengerClockExpired_reverts() public {
        _propose(proposer, epoch, keccak256("fake"));
        uint256 id = _challenge(challenger, epoch);
        vm.prank(proposer);
        game.commitEnd(id, _endWithRoot(keccak256("fake")));
        _playHonestChallenger(id, true);
        vm.warp(vm.getBlockTimestamp() + CLOCK + 1);
        (uint64 lo,) = _range(id);
        Machine memory pre = honest[4];
        StepProof memory empty;
        assertEq(lo, 7);
        vm.expectRevert(abi.encodeWithSelector(IDisputeGame.ClockExpired.selector, id));
        game.step(id, pre, empty);
    }

    function test_cancel_whenProposalOrphaned() public {
        // Epoch 1 is fraudulent, epoch 2 builds on it and gets its own challenge.
        _postEmptyBatch();
        _propose(proposer, epoch, keccak256("fake1"));
        uint256 pid2 = _propose(proposer, epoch + 1, keccak256("fake2"));
        uint256 g1 = _challenge(challenger, epoch);
        uint256 g2 = _challenge(challenger, epoch + 1);
        vm.expectRevert(abi.encodeWithSelector(IDisputeGame.ProposalStillLive.selector, pid2));
        game.cancel(g2);
        vm.warp(vm.getBlockTimestamp() + CLOCK + 1);
        game.claimTimeout(g1); // defender never moved: epoch 1 invalidated, epoch 2 orphaned
        game.cancel(g2);
        assertEq(uint8(game.getGame(g2).outcome), uint8(IOutputOracle.Outcome.Cancelled));
        assertEq(oracle.credit(challenger), 2 * CHALLENGER_BOND + PROPOSER_BOND * 9 / 10);
        oracle.reclaimOrphanedBond(pid2);
        assertEq(oracle.credit(proposer), PROPOSER_BOND);
    }

    // ---- reverts --------------------------------------------------------------------------------------------------

    function test_revert_challengeWrongBond() public {
        _propose(proposer, epoch, r42);
        vm.prank(challenger);
        vm.expectRevert(abi.encodeWithSelector(IDisputeGame.IncorrectBond.selector, CHALLENGER_BOND, 1));
        game.challenge{value: 1}(epoch);
    }

    function test_revert_challengeAfterWindow() public {
        uint256 pid = _propose(proposer, epoch, r42);
        vm.warp(vm.getBlockTimestamp() + CHALLENGE_WINDOW);
        vm.prank(challenger);
        vm.expectRevert(
            abi.encodeWithSelector(IOutputOracle.ChallengeWindowClosed.selector, pid, vm.getBlockTimestamp())
        );
        game.challenge{value: CHALLENGER_BOND}(epoch);
    }

    function test_revert_challengeWithoutProposal() public {
        vm.prank(challenger);
        vm.expectRevert(abi.encodeWithSelector(IOutputOracle.ProposalNotLive.selector, 0));
        game.challenge{value: CHALLENGER_BOND}(epoch);
    }

    function test_revert_wrongTurnAndPhase() public {
        _propose(proposer, epoch, r42);
        uint256 id = _challenge(challenger, epoch);
        vm.prank(challenger);
        vm.expectRevert(abi.encodeWithSelector(IDisputeGame.NotYourTurn.selector, challenger, proposer));
        game.commitEnd(id, honest[4]);
        vm.prank(proposer);
        vm.expectRevert(abi.encodeWithSelector(IDisputeGame.WrongPhase.selector, id, IDisputeGame.Phase.AwaitingEnd));
        game.bisect(id, bytes32(0));
        vm.prank(challenger);
        vm.expectRevert(abi.encodeWithSelector(IDisputeGame.WrongPhase.selector, id, IDisputeGame.Phase.AwaitingEnd));
        game.choose(id, true);
        StepProof memory empty;
        vm.expectRevert(abi.encodeWithSelector(IDisputeGame.WrongPhase.selector, id, IDisputeGame.Phase.AwaitingEnd));
        game.step(id, honest[0], empty);
    }

    function test_revert_invalidEndState() public {
        _propose(proposer, epoch, r42);
        uint256 id = _challenge(challenger, epoch);
        Machine memory running = honest[3];
        vm.prank(proposer);
        vm.expectRevert(abi.encodeWithSelector(IDisputeGame.InvalidEndState.selector, 0, running.stateRoot));
        game.commitEnd(id, running);
        vm.prank(proposer);
        vm.expectRevert(abi.encodeWithSelector(IDisputeGame.InvalidEndState.selector, 1, bytes32(uint256(7))));
        game.commitEnd(id, _endWithRoot(bytes32(uint256(7))));
    }

    function test_revert_preStateMismatch() public {
        _propose(proposer, epoch, keccak256("fake"));
        uint256 id = _challenge(challenger, epoch);
        vm.prank(proposer);
        game.commitEnd(id, _endWithRoot(keccak256("fake")));
        _playHonestChallenger(id, true);
        StepProof memory empty;
        vm.expectRevert(
            abi.encodeWithSelector(IDisputeGame.PreStateMismatch.selector, _honestHash(7), VmSpec.hash(honest[0]))
        );
        game.step(id, honest[0], empty);
    }

    function test_revert_unknownGame() public {
        vm.expectRevert(abi.encodeWithSelector(IDisputeGame.UnknownGame.selector, 9));
        game.claimTimeout(9);
        vm.expectRevert(abi.encodeWithSelector(IDisputeGame.UnknownGame.selector, 9));
        game.toMove(9);
    }

    function test_revert_resolvedGameCannotMove() public {
        _propose(proposer, epoch, keccak256("fake"));
        uint256 id = _challenge(challenger, epoch);
        vm.warp(vm.getBlockTimestamp() + CLOCK + 1);
        game.claimTimeout(id);
        vm.expectRevert(abi.encodeWithSelector(IDisputeGame.WrongPhase.selector, id, IDisputeGame.Phase.Resolved));
        game.claimTimeout(id);
        vm.expectRevert(abi.encodeWithSelector(IDisputeGame.WrongPhase.selector, id, IDisputeGame.Phase.Resolved));
        game.cancel(id);
    }

    function test_revert_constructorParameters() public {
        vm.expectRevert(IDisputeGame.InvalidParameter.selector);
        new DisputeGame(oracle, inbox, osvm, bytes32(0), 1, 3, 1, 1);
        vm.expectRevert(IDisputeGame.InvalidParameter.selector);
        new DisputeGame(oracle, inbox, osvm, bytes32(uint256(1)), 1, 41, 1, 1);
        vm.expectRevert(IDisputeGame.InvalidParameter.selector);
        new DisputeGame(
            IOutputOracle(address(0)),
            IBatchInbox(address(inbox)),
            IOneStepVM(address(osvm)),
            bytes32(uint256(1)),
            1,
            3,
            1,
            1
        );
    }

    // ---- fuzz -----------------------------------------------------------------------------------------------------

    /// @notice Whatever midpoints a dishonest defender posts, an honest challenger wins in exactly 2 * depth + 2 moves.
    function testFuzz_honestChallengerAlwaysWins(uint256 lieMask, bytes32 fakeRoot) public {
        vm.assume(fakeRoot != r42);
        _propose(proposer, epoch, fakeRoot);
        uint256 id = _challenge(challenger, epoch);
        vm.prank(proposer);
        game.commitEnd(id, _endWithRoot(fakeRoot));
        for (uint256 round = 0; round < MAX_DEPTH; ++round) {
            (uint64 lo, uint64 hi) = _range(id);
            uint64 mid = lo + (hi - lo) / 2;
            bytes32 claimed = (lieMask >> round) & 1 == 1 ? keccak256(abi.encode(lieMask, round)) : _honestHash(mid);
            vm.prank(proposer);
            game.bisect(id, claimed);
            vm.prank(challenger);
            game.choose(id, claimed == _honestHash(mid));
        }
        _stepAtLeaf(id);
        assertEq(uint8(game.getGame(id).outcome), uint8(IOutputOracle.Outcome.ChallengerWins));
        assertEq(game.getGame(id).moves, 2 * MAX_DEPTH + 2);
    }

    /// @notice Whatever a dishonest challenger chooses, an honest defender wins.
    function testFuzz_honestDefenderAlwaysWins(uint256 choiceMask) public {
        _propose(proposer, epoch, r42);
        uint256 id = _challenge(challenger, epoch);
        vm.prank(proposer);
        game.commitEnd(id, honest[4]);
        for (uint256 round = 0; round < MAX_DEPTH; ++round) {
            (uint64 lo, uint64 hi) = _range(id);
            uint64 mid = lo + (hi - lo) / 2;
            vm.prank(proposer);
            game.bisect(id, _honestHash(mid));
            vm.prank(challenger);
            game.choose(id, (choiceMask >> round) & 1 == 1);
        }
        _stepAtLeaf(id);
        assertEq(uint8(game.getGame(id).outcome), uint8(IOutputOracle.Outcome.DefenderWins));
    }
}
