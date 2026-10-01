// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title IOutputOracle
/// @notice Bonded L2 output proposals, one canonical proposal per epoch, plus the bond vault for disputes.
interface IOutputOracle {
    /// @notice Lifecycle of a proposal.
    enum ProposalStatus {
        None,
        Proposed,
        Finalized,
        Invalidated,
        Orphaned
    }

    /// @notice How a dispute ended, as settled by the oracle.
    enum Outcome {
        None,
        ChallengerWins,
        DefenderWins,
        Cancelled
    }

    /// @notice A proposal.
    /// @param stateRoot Claimed L2 state root after the epoch.
    /// @param proposer Account whose bond backs the claim; defends it in disputes.
    /// @param epoch Epoch the claim is about.
    /// @param proposedAt Timestamp of the proposal; the challenge window starts here.
    /// @param activeGames Disputes currently open against the proposal.
    /// @param status Lifecycle status.
    struct Proposal {
        bytes32 stateRoot;
        address proposer;
        uint64 epoch;
        uint64 proposedAt;
        uint32 activeGames;
        ProposalStatus status;
    }

    /// @notice A new output was proposed.
    /// @param proposalId Unique id of the proposal.
    /// @param epoch Epoch of the output.
    /// @param stateRoot Claimed state root.
    /// @param outputRoot Output root committed for the epoch.
    /// @param proposer The proposer.
    event OutputProposed(
        uint256 indexed proposalId,
        uint64 indexed epoch,
        bytes32 stateRoot,
        bytes32 outputRoot,
        address indexed proposer
    );

    /// @notice An output passed its challenge window undisputed and is final.
    /// @param proposalId The proposal.
    /// @param epoch Its epoch.
    event OutputFinalized(uint256 indexed proposalId, uint64 indexed epoch);

    /// @notice An output was proven wrong; it and every later proposal leave the canonical chain.
    /// @param proposalId The invalidated proposal.
    /// @param epoch Its epoch (the new `nextEpoch`).
    /// @param challenger The winning challenger.
    event OutputInvalidated(uint256 indexed proposalId, uint64 indexed epoch, address indexed challenger);

    /// @notice The bond of a proposal orphaned by an earlier invalidation was refunded.
    /// @param proposalId The orphaned proposal.
    /// @param proposer Refunded account.
    event OrphanedBondReclaimed(uint256 indexed proposalId, address indexed proposer);

    /// @notice A dispute bond was locked against a proposal.
    /// @param proposalId The disputed proposal.
    /// @param challenger The challenger.
    /// @param bond Wei locked.
    event ChallengeOpened(uint256 indexed proposalId, address indexed challenger, uint256 bond);

    /// @notice A dispute was settled and its bonds redistributed.
    /// @param proposalId The disputed proposal.
    /// @param challenger The challenger.
    /// @param outcome Effective outcome.
    event ChallengeSettled(uint256 indexed proposalId, address indexed challenger, Outcome outcome);

    /// @notice An account's withdrawable credit increased.
    /// @param account Credited account.
    /// @param amount Wei credited.
    event Credited(address indexed account, uint256 amount);

    /// @notice Part of a forfeited bond was burned (locked in this contract forever).
    /// @param amount Wei burned.
    event Burned(uint256 amount);

    /// @notice An account withdrew its credit.
    /// @param account The account.
    /// @param amount Wei paid out.
    event CreditClaimed(address indexed account, uint256 amount);

    /// @notice Wrong bond amount.
    /// @param expected Required bond.
    /// @param supplied `msg.value`.
    error IncorrectBond(uint256 expected, uint256 supplied);

    /// @notice Proposals must extend the canonical chain one epoch at a time.
    /// @param expected The next epoch.
    /// @param supplied The epoch proposed.
    error NotNextEpoch(uint64 expected, uint64 supplied);

    /// @notice The epoch has no batch on L1 yet.
    /// @param epoch The epoch proposed.
    /// @param batchCount Batches posted so far.
    error EpochNotPosted(uint64 epoch, uint256 batchCount);

    /// @notice Caller is not the dispute game.
    /// @param caller The caller.
    error OnlyDisputeGame(address caller);

    /// @notice The proposal is not canonical and pending.
    /// @param proposalId The proposal.
    error ProposalNotLive(uint256 proposalId);

    /// @notice The challenge window of the proposal has closed.
    /// @param proposalId The proposal.
    /// @param closedAt Timestamp at which it closed.
    error ChallengeWindowClosed(uint256 proposalId, uint256 closedAt);

    /// @notice Finalization preconditions are not met.
    /// @param epoch Epoch whose finalization was attempted.
    error CannotFinalize(uint64 epoch);

    /// @notice The proposal is not orphaned (or its bond was already reclaimed).
    /// @param proposalId The proposal.
    error NotOrphaned(uint256 proposalId);

    /// @notice The caller has nothing to claim.
    error NoCredit();

    /// @notice The epoch is not finalized.
    /// @param epoch The epoch queried.
    error NotFinalized(uint64 epoch);

    /// @notice The epoch has no canonical proposal.
    /// @param epoch The epoch queried.
    error UnknownEpoch(uint64 epoch);

    /// @notice A constructor argument was zero.
    error ZeroParameter();

    /// @notice Proposes `stateRoot` for `epoch`, locking `PROPOSER_BOND()`.
    /// @param epoch Must equal `nextEpoch()` and have a posted batch.
    /// @param stateRoot Claimed L2 state root after executing the epoch.
    /// @return proposalId Id of the new proposal.
    function propose(uint64 epoch, bytes32 stateRoot) external payable returns (uint256 proposalId);

    /// @notice Finalizes the next epoch once its window has passed with no open dispute; refunds the bond.
    /// @param epoch Must equal `lastFinalizedEpoch() + 1`.
    function finalize(uint64 epoch) external;

    /// @notice Refunds the bond of a proposal that left the canonical chain because an ancestor was invalidated.
    /// @param proposalId The orphaned proposal.
    function reclaimOrphanedBond(uint256 proposalId) external;

    /// @notice Withdraws the caller's credit.
    function claimCredit() external;

    /// @notice Locks a challenger bond against the canonical proposal of `epoch`. Dispute game only.
    /// @param epoch Disputed epoch.
    /// @param challenger The challenger.
    /// @return proposalId Disputed proposal.
    /// @return preStateRoot Agreed state root the epoch starts from (parent output or genesis).
    function openChallenge(uint64 epoch, address challenger)
        external
        payable
        returns (uint256 proposalId, bytes32 preStateRoot);

    /// @notice Settles a dispute. Dispute game only. A proposal that is no longer live is always settled as
    ///         `Cancelled`, which refunds the challenger.
    /// @param proposalId Disputed proposal.
    /// @param challenger The challenger.
    /// @param bond Challenger bond locked by `openChallenge`.
    /// @param outcome Result decided by the game.
    /// @return effective The outcome actually applied.
    function settleChallenge(uint256 proposalId, address challenger, uint256 bond, Outcome outcome)
        external
        returns (Outcome effective);

    /// @notice Whether a proposal is canonical and still pending.
    /// @param proposalId The proposal.
    /// @return True when it can still be disputed or finalized.
    function isLive(uint256 proposalId) external view returns (bool);

    /// @notice Proposal by id.
    /// @param proposalId The proposal.
    /// @return The proposal.
    function getProposal(uint256 proposalId) external view returns (Proposal memory);

    /// @notice Canonical proposal id of an epoch (0 when none).
    /// @param epoch The epoch.
    /// @return The id.
    function proposalIdAt(uint64 epoch) external view returns (uint256);

    /// @notice Next epoch to propose.
    /// @return The epoch.
    function nextEpoch() external view returns (uint64);

    /// @notice Highest finalized epoch (0 = genesis only).
    /// @return The epoch.
    function lastFinalizedEpoch() external view returns (uint64);

    /// @notice State root of a finalized epoch (genesis root for epoch 0).
    /// @param epoch A finalized epoch.
    /// @return The state root.
    function finalizedStateRoot(uint64 epoch) external view returns (bytes32);

    /// @notice Bond required per proposal.
    /// @return Wei.
    function PROPOSER_BOND() external view returns (uint256);

    /// @notice Challenge window per proposal.
    /// @return Seconds.
    function CHALLENGE_WINDOW() external view returns (uint64);
}
