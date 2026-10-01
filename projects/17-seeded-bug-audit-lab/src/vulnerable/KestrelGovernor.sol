// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { GovToken } from "shared/GovToken.sol";

/// @title KestrelGovernor
/// @notice Token-weighted governance with a snapshot-based proposal flow and a fast "emergency"
///         path that lets a supermajority stakeholder execute a time-critical call at once.
/// @dev    Holds the protocol treasury (ETH and tokens). Normal proposals snapshot voting power
///         at the block before creation. Emergency support is measured against
///         {emergencyQuorumBps} of the supply {emergencyLookback} blocks ago.
contract KestrelGovernor is ReentrancyGuardTransient {
    /// @notice Basis-point denominator.
    uint256 internal constant BPS = 10_000;

    /// @notice Governance token providing checkpointed voting power.
    GovToken public immutable token;
    /// @notice Blocks a normal proposal stays open for voting.
    uint256 public immutable votingPeriod;
    /// @notice Quorum for normal proposals, in basis points of snapshot supply.
    uint256 public immutable quorumBps;
    /// @notice Quorum for emergency execution, in basis points of supply.
    uint256 public immutable emergencyQuorumBps;
    /// @notice How many blocks in the past emergency voting power is measured.
    uint256 public immutable emergencyLookback;

    /// @notice A normal governance proposal.
    /// @param target Call target.
    /// @param value ETH value to send.
    /// @param data Calldata.
    /// @param snapshot Block whose voting power counts.
    /// @param deadline Last block on which votes are accepted (non-zero once created).
    /// @param forVotes Accumulated support.
    /// @param againstVotes Accumulated opposition.
    /// @param executed Whether the proposal has been executed.
    struct Proposal {
        address target;
        uint256 value;
        bytes data;
        uint256 snapshot;
        uint256 deadline;
        uint256 forVotes;
        uint256 againstVotes;
        bool executed;
    }

    /// @notice Proposals by id.
    mapping(uint256 id => Proposal proposal) public proposals;
    /// @notice Whether an account has voted on a proposal.
    mapping(uint256 id => mapping(address voter => bool)) public hasVoted;

    /// @notice Emitted when a proposal is created.
    /// @param id Proposal id.
    /// @param proposer Creator.
    /// @param target Call target.
    /// @param snapshot Block whose voting power counts.
    event ProposalCreated(uint256 indexed id, address indexed proposer, address target, uint256 snapshot);
    /// @notice Emitted when a vote is cast.
    /// @param id Proposal id.
    /// @param voter Voter.
    /// @param support True for, false against.
    /// @param weight Voting power applied.
    event VoteCast(uint256 indexed id, address indexed voter, bool support, uint256 weight);
    /// @notice Emitted when a normal proposal is executed.
    /// @param id Proposal id.
    event ProposalExecuted(uint256 indexed id);
    /// @notice Emitted when an emergency action is executed.
    /// @param caller Stakeholder that executed it.
    /// @param target Call target.
    /// @param weight Support presented.
    event EmergencyExecuted(address indexed caller, address indexed target, uint256 weight);

    /// @notice Thrown on a duplicate proposal id.
    /// @param id The existing proposal id.
    error ProposalExists(uint256 id);
    /// @notice Thrown when acting on an unknown proposal.
    /// @param id The unknown id.
    error UnknownProposal(uint256 id);
    /// @notice Thrown when voting after the deadline.
    /// @param deadline The proposal deadline.
    error VotingClosed(uint256 deadline);
    /// @notice Thrown when an account votes twice.
    /// @param voter The voter.
    error AlreadyVoted(address voter);
    /// @notice Thrown when executing before the deadline has passed.
    /// @param deadline The proposal deadline.
    error VotingOpen(uint256 deadline);
    /// @notice Thrown when a proposal did not reach quorum or majority.
    /// @param forVotes Support.
    /// @param againstVotes Opposition.
    /// @param quorum Required support.
    error ProposalNotPassed(uint256 forVotes, uint256 againstVotes, uint256 quorum);
    /// @notice Thrown when a proposal was already executed.
    /// @param id Proposal id.
    error AlreadyExecuted(uint256 id);
    /// @notice Thrown when emergency support is below the emergency quorum.
    /// @param weight Support presented.
    /// @param required Support required.
    error InsufficientSupport(uint256 weight, uint256 required);
    /// @notice Thrown when the executed call reverts.
    error ExecutionFailed();
    /// @notice Thrown when a constructor parameter is out of range.
    error InvalidParameter();

    /// @notice Deploy the governor.
    /// @param _token Governance token.
    /// @param _votingPeriod Voting window in blocks (> 0).
    /// @param _quorumBps Normal quorum in basis points (1..10,000).
    /// @param _emergencyQuorumBps Emergency quorum in basis points (1..10,000).
    /// @param _emergencyLookback Blocks in the past at which emergency support is measured (> 0).
    constructor(
        GovToken _token,
        uint256 _votingPeriod,
        uint256 _quorumBps,
        uint256 _emergencyQuorumBps,
        uint256 _emergencyLookback
    ) {
        require(
            _votingPeriod > 0 && _quorumBps > 0 && _quorumBps <= BPS && _emergencyQuorumBps > 0
                && _emergencyQuorumBps <= BPS && _emergencyLookback > 0,
            InvalidParameter()
        );
        token = _token;
        votingPeriod = _votingPeriod;
        quorumBps = _quorumBps;
        emergencyQuorumBps = _emergencyQuorumBps;
        emergencyLookback = _emergencyLookback;
    }

    /// @notice Accept ETH into the treasury.
    receive() external payable { }

    /// @notice Create a proposal.
    /// @param target Call target.
    /// @param value ETH value to send on execution.
    /// @param data Calldata to execute.
    /// @return id The proposal id.
    function propose(address target, uint256 value, bytes calldata data) external returns (uint256 id) {
        id = uint256(keccak256(abi.encode(target, value, data, block.number, msg.sender)));
        require(proposals[id].deadline == 0, ProposalExists(id));
        uint256 snapshot = block.number > 0 ? block.number - 1 : 0;
        proposals[id] = Proposal({
            target: target,
            value: value,
            data: data,
            snapshot: snapshot,
            deadline: block.number + votingPeriod,
            forVotes: 0,
            againstVotes: 0,
            executed: false
        });
        emit ProposalCreated(id, msg.sender, target, snapshot);
    }

    /// @notice Cast a vote weighted by snapshot voting power.
    /// @param id Proposal id.
    /// @param support True to support, false to oppose.
    function castVote(uint256 id, bool support) external {
        Proposal storage p = proposals[id];
        require(p.deadline != 0, UnknownProposal(id));
        require(block.number <= p.deadline, VotingClosed(p.deadline));
        require(!hasVoted[id][msg.sender], AlreadyVoted(msg.sender));
        hasVoted[id][msg.sender] = true;
        uint256 weight = token.getPastVotes(msg.sender, p.snapshot);
        if (support) {
            p.forVotes += weight;
        } else {
            p.againstVotes += weight;
        }
        emit VoteCast(id, msg.sender, support, weight);
    }

    /// @notice Execute a passed proposal after its deadline.
    /// @param id Proposal id.
    /// @return ret Return data of the executed call.
    function execute(uint256 id) external nonReentrant returns (bytes memory ret) {
        Proposal storage p = proposals[id];
        require(p.deadline != 0, UnknownProposal(id));
        require(block.number > p.deadline, VotingOpen(p.deadline));
        require(!p.executed, AlreadyExecuted(id));
        uint256 quorum = token.getPastTotalSupply(p.snapshot) * quorumBps / BPS;
        require(
            p.forVotes >= quorum && p.forVotes > p.againstVotes,
            ProposalNotPassed(p.forVotes, p.againstVotes, quorum)
        );
        p.executed = true;
        emit ProposalExecuted(id);
        bool ok;
        (ok, ret) = p.target.call{ value: p.value }(p.data);
        require(ok, ExecutionFailed());
    }

    /// @notice Immediately execute an action if the caller presents emergency-quorum support.
    /// @param target Call target.
    /// @param value ETH value to send.
    /// @param data Calldata to execute.
    /// @return ret Return data of the executed call.
    function emergencyExecute(address target, uint256 value, bytes calldata data)
        external
        nonReentrant
        returns (bytes memory ret)
    {
        uint256 timepoint = block.number > emergencyLookback ? block.number - emergencyLookback : 0;
        uint256 supply = token.getPastTotalSupply(timepoint);
        uint256 weight = token.balanceOf(msg.sender);
        uint256 required = supply * emergencyQuorumBps / BPS;
        require(weight > 0 && weight >= required, InsufficientSupport(weight, required));
        emit EmergencyExecuted(msg.sender, target, weight);
        bool ok;
        (ok, ret) = target.call{ value: value }(data);
        require(ok, ExecutionFailed());
    }
}
