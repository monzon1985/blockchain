// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { BaseTest } from "../BaseTest.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { KestrelGovernor } from "kestrel/KestrelGovernor.sol";
import { GovToken } from "shared/GovToken.sol";

/// @notice Unit tests for {KestrelGovernor} and {GovToken}: happy paths and every revert path.
contract GovernorUnit is BaseTest {
    uint256 internal constant TREASURY = 10_000e18;

    function setUp() public override {
        super.setUp();
        gov.transfer(address(governor), TREASURY);
        vm.roll(block.number + 1);
    }

    function _transferData(address to, uint256 amount) internal pure returns (bytes memory) {
        return abi.encodeCall(IERC20.transfer, (to, amount));
    }

    function test_constructor_rejectsBadParameters() public {
        vm.expectRevert(KestrelGovernor.InvalidParameter.selector);
        new KestrelGovernor(gov, 0, 4000, 6666, 50);
        vm.expectRevert(KestrelGovernor.InvalidParameter.selector);
        new KestrelGovernor(gov, 10, 0, 6666, 50);
        vm.expectRevert(KestrelGovernor.InvalidParameter.selector);
        new KestrelGovernor(gov, 10, 10_001, 6666, 50);
        vm.expectRevert(KestrelGovernor.InvalidParameter.selector);
        new KestrelGovernor(gov, 10, 4000, 0, 50);
        vm.expectRevert(KestrelGovernor.InvalidParameter.selector);
        new KestrelGovernor(gov, 10, 4000, 10_001, 50);
        vm.expectRevert(KestrelGovernor.InvalidParameter.selector);
        new KestrelGovernor(gov, 10, 4000, 6666, 0);
    }

    function test_normalProposalFlow() public {
        uint256 id = governor.propose(address(gov), 0, _transferData(bob, TREASURY));
        governor.castVote(id, true);
        vm.roll(block.number + VOTING_PERIOD + 1);
        governor.execute(id);
        assertEq(gov.balanceOf(bob), TREASURY);
        (,,,,,,, bool executed) = governor.proposals(id);
        assertTrue(executed);
    }

    function test_proposal_ethTreasury() public {
        vm.deal(address(governor), 1 ether);
        uint256 id = governor.propose(bob, 1 ether, "");
        governor.castVote(id, true);
        vm.roll(block.number + VOTING_PERIOD + 1);
        governor.execute(id);
        assertEq(bob.balance, 1 ether);
    }

    function test_propose_rejectsDuplicateInSameBlock() public {
        bytes memory data = _transferData(bob, 1);
        uint256 id = governor.propose(address(gov), 0, data);
        vm.expectRevert(abi.encodeWithSelector(KestrelGovernor.ProposalExists.selector, id));
        governor.propose(address(gov), 0, data);
    }

    function test_propose_existenceCheckSurvivesSnapshotZero() public {
        // At block 1 the snapshot is block 0; the proposal must still be recognized as existing.
        vm.roll(1);
        bytes memory data = _transferData(bob, 1);
        uint256 id = governor.propose(address(gov), 0, data);
        (,,, uint256 snapshot,,,,) = governor.proposals(id);
        assertEq(snapshot, 0, "snapshot at block 0");
        vm.expectRevert(abi.encodeWithSelector(KestrelGovernor.ProposalExists.selector, id));
        governor.propose(address(gov), 0, data);
    }

    function test_castVote_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(KestrelGovernor.UnknownProposal.selector, 7));
        governor.castVote(7, true);

        uint256 id = governor.propose(address(gov), 0, _transferData(bob, 1));
        governor.castVote(id, false);
        vm.expectRevert(abi.encodeWithSelector(KestrelGovernor.AlreadyVoted.selector, deployer));
        governor.castVote(id, true);

        (,,,, uint256 deadline,,,) = governor.proposals(id);
        vm.roll(deadline + 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(KestrelGovernor.VotingClosed.selector, deadline));
        governor.castVote(id, true);
    }

    function test_execute_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(KestrelGovernor.UnknownProposal.selector, 7));
        governor.execute(7);

        uint256 id = governor.propose(address(gov), 0, _transferData(bob, TREASURY));
        (,,,, uint256 deadline,,,) = governor.proposals(id);
        vm.expectRevert(abi.encodeWithSelector(KestrelGovernor.VotingOpen.selector, deadline));
        governor.execute(id);

        // Nobody voted: quorum not met.
        vm.roll(deadline + 1);
        uint256 quorum = GOV_SUPPLY * QUORUM_BPS / 10_000;
        vm.expectRevert(abi.encodeWithSelector(KestrelGovernor.ProposalNotPassed.selector, 0, 0, quorum));
        governor.execute(id);
    }

    function test_execute_rejectsReplayAndFailedCalls() public {
        uint256 id = governor.propose(address(gov), 0, _transferData(bob, TREASURY));
        uint256 bad = governor.propose(address(gov), 0, _transferData(bob, TREASURY + 1));
        governor.castVote(id, true);
        governor.castVote(bad, true);
        vm.roll(block.number + VOTING_PERIOD + 1);
        governor.execute(id);
        vm.expectRevert(abi.encodeWithSelector(KestrelGovernor.AlreadyExecuted.selector, id));
        governor.execute(id);
        vm.expectRevert(KestrelGovernor.ExecutionFailed.selector);
        governor.execute(bad);
    }

    function test_execute_majorityAgainstFails() public {
        gov.transfer(alice, 300_000e18);
        vm.prank(alice);
        gov.delegate(alice);
        vm.roll(block.number + 2);
        uint256 id = governor.propose(address(gov), 0, _transferData(bob, 1));
        governor.castVote(id, false); // deployer: 690k against
        vm.prank(alice);
        governor.castVote(id, true); // alice: 300k for (quorum 400k not met either)
        vm.roll(block.number + VOTING_PERIOD + 1);
        vm.expectPartialRevert(KestrelGovernor.ProposalNotPassed.selector);
        governor.execute(id);
    }

    function test_emergencyExecute_legitSupermajority() public {
        governor.emergencyExecute(address(gov), 0, _transferData(bob, TREASURY));
        assertEq(gov.balanceOf(bob), TREASURY);
    }

    function test_emergencyExecute_reverts() public {
        uint256 required = GOV_SUPPLY * EMERGENCY_QUORUM_BPS / 10_000;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(KestrelGovernor.InsufficientSupport.selector, 0, required));
        governor.emergencyExecute(address(gov), 0, _transferData(alice, 1));

        vm.expectRevert(KestrelGovernor.ExecutionFailed.selector);
        governor.emergencyExecute(address(gov), 0, _transferData(bob, TREASURY + 1));
    }

    function test_emergencyExecute_beforeLookbackHasNoHistory() public {
        GovToken t = new GovToken(deployer, 1000e18);
        t.delegate(deployer);
        KestrelGovernor g = new KestrelGovernor(t, 10, 4000, 6666, 1_000_000);
        vm.expectRevert(abi.encodeWithSelector(KestrelGovernor.InsufficientSupport.selector, 0, 0));
        g.emergencyExecute(address(t), 0, "");
    }

    function test_receiveAcceptsEth() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(governor).call{ value: 1 ether }("");
        assertTrue(ok);
        assertEq(address(governor).balance, 1 ether);
    }

    function test_govToken_delegateMintAndPermitNonces() public {
        gov.delegate(bob);
        assertEq(gov.delegates(deployer), bob);
        gov.mint(alice, 1000e18);
        assertEq(gov.balanceOf(alice), 1000e18);
        assertEq(gov.nonces(alice), 0);
    }
}
