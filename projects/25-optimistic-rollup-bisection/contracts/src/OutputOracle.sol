// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Address} from "@openzeppelin-contracts/utils/Address.sol";
import {ReentrancyGuardTransient} from "@openzeppelin-contracts/utils/ReentrancyGuardTransient.sol";
import {IOutputOracle} from "./interfaces/IOutputOracle.sol";
import {IBatchInbox} from "./interfaces/IBatchInbox.sol";
import {RollupSpec} from "./lib/RollupSpec.sol";

/// @title OutputOracle
/// @notice Permissionless, bonded output proposals and the single vault for every dispute bond.
/// @dev Proposals form a chain: epoch `e` can only be proposed on top of the canonical proposal for `e - 1`, and a
///      dispute on `e` takes that parent's state root as the agreed pre-state. When a dispute proves `e` wrong, the
///      chain is truncated back to `e` (`nextEpoch = e`): later proposals become orphaned, their bonds refundable and
///      their disputes cancellable.
///
///      Accounting invariant (checked by the invariant suite):
///      `address(this).balance == lockedBonds + totalCredit + totalBurned`.
contract OutputOracle is IOutputOracle, ReentrancyGuardTransient {
    /// @notice Share of a forfeited bond that is burned instead of paid to the winner, in basis points (10%).
    uint256 public constant BURN_BPS = 1_000;
    /// @notice Basis-point denominator.
    uint256 public constant BPS = 10_000;

    /// @notice Batch inbox; a proposal needs its epoch's batch to exist.
    IBatchInbox public immutable INBOX;
    /// @notice The only contract allowed to lock and settle challenger bonds.
    address public immutable DISPUTE_GAME;
    /// @notice L2 state root before epoch 1.
    bytes32 public immutable GENESIS_STATE_ROOT;
    /// @inheritdoc IOutputOracle
    uint256 public immutable PROPOSER_BOND;
    /// @inheritdoc IOutputOracle
    uint64 public immutable CHALLENGE_WINDOW;

    /// @notice Proposals by id (ids start at 1).
    mapping(uint256 proposalId => Proposal) private _proposals;
    /// @notice Number of proposals ever made.
    uint256 public proposalCount;
    /// @inheritdoc IOutputOracle
    mapping(uint64 epoch => uint256 proposalId) public proposalIdAt;
    /// @inheritdoc IOutputOracle
    uint64 public nextEpoch = 1;
    /// @inheritdoc IOutputOracle
    uint64 public lastFinalizedEpoch;

    /// @notice Withdrawable wei per account.
    mapping(address account => uint256 amount) public credit;
    /// @notice Wei locked in live proposer bonds and open challenger bonds.
    uint256 public lockedBonds;
    /// @notice Sum of all unclaimed credit.
    uint256 public totalCredit;
    /// @notice Wei burned so far (held here with no withdrawal path).
    uint256 public totalBurned;

    modifier onlyDisputeGame() {
        _onlyDisputeGame();
        _;
    }

    /// @param inbox Batch inbox.
    /// @param disputeGame Dispute game (may be a precomputed address; checked by the deployment script).
    /// @param genesisStateRoot L2 state root before epoch 1.
    /// @param proposerBond Bond per proposal, in wei.
    /// @param challengeWindow Seconds a proposal stays open to disputes.
    constructor(
        IBatchInbox inbox,
        address disputeGame,
        bytes32 genesisStateRoot,
        uint256 proposerBond,
        uint64 challengeWindow
    ) {
        require(
            address(inbox) != address(0) && disputeGame != address(0) && proposerBond != 0 && challengeWindow != 0,
            ZeroParameter()
        );
        INBOX = inbox;
        DISPUTE_GAME = disputeGame;
        GENESIS_STATE_ROOT = genesisStateRoot;
        PROPOSER_BOND = proposerBond;
        CHALLENGE_WINDOW = challengeWindow;
    }

    /// @inheritdoc IOutputOracle
    function propose(uint64 epoch, bytes32 stateRoot) external payable returns (uint256 proposalId) {
        require(msg.value == PROPOSER_BOND, IncorrectBond(PROPOSER_BOND, msg.value));
        require(epoch == nextEpoch, NotNextEpoch(nextEpoch, epoch));
        uint256 posted = INBOX.batchCount();
        require(epoch <= posted, EpochNotPosted(epoch, posted));

        proposalId = ++proposalCount;
        _proposals[proposalId] = Proposal({
            stateRoot: stateRoot,
            proposer: msg.sender,
            epoch: epoch,
            // Timestamps fit in 64 bits for billions of years.
            // forge-lint: disable-next-line(unsafe-typecast)
            proposedAt: uint64(block.timestamp),
            activeGames: 0,
            status: ProposalStatus.Proposed
        });
        proposalIdAt[epoch] = proposalId;
        nextEpoch = epoch + 1;
        lockedBonds += msg.value;
        emit OutputProposed(proposalId, epoch, stateRoot, RollupSpec.outputRoot(epoch, stateRoot), msg.sender);
    }

    /// @inheritdoc IOutputOracle
    function finalize(uint64 epoch) external {
        require(epoch == lastFinalizedEpoch + 1 && epoch < nextEpoch, CannotFinalize(epoch));
        uint256 id = proposalIdAt[epoch];
        Proposal storage p = _proposals[id];
        // Windows are hours to days long; the seconds of drift a block producer controls are irrelevant.
        // slither-disable-next-line timestamp
        require(
            p.status == ProposalStatus.Proposed && p.activeGames == 0
                // forge-lint: disable-next-line(block-timestamp)
                && block.timestamp >= uint256(p.proposedAt) + CHALLENGE_WINDOW,
            CannotFinalize(epoch)
        );
        p.status = ProposalStatus.Finalized;
        lastFinalizedEpoch = epoch;
        lockedBonds -= PROPOSER_BOND;
        emit OutputFinalized(id, epoch);
        _credit(p.proposer, PROPOSER_BOND);
    }

    /// @inheritdoc IOutputOracle
    function reclaimOrphanedBond(uint256 proposalId) external {
        Proposal storage p = _proposals[proposalId];
        // Status and chain-position checks only (Slither's taint reaches the struct through `proposedAt`).
        // slither-disable-next-line timestamp
        require(p.status == ProposalStatus.Proposed && !_isCanonical(proposalId, p), NotOrphaned(proposalId));
        p.status = ProposalStatus.Orphaned;
        lockedBonds -= PROPOSER_BOND;
        emit OrphanedBondReclaimed(proposalId, p.proposer);
        _credit(p.proposer, PROPOSER_BOND);
    }

    /// @inheritdoc IOutputOracle
    function claimCredit() external nonReentrant {
        uint256 amount = credit[msg.sender];
        require(amount != 0, NoCredit());
        credit[msg.sender] = 0;
        totalCredit -= amount;
        emit CreditClaimed(msg.sender, amount);
        Address.sendValue(payable(msg.sender), amount);
    }

    /// @inheritdoc IOutputOracle
    function openChallenge(uint64 epoch, address challenger)
        external
        payable
        onlyDisputeGame
        returns (uint256 proposalId, bytes32 preStateRoot)
    {
        proposalId = proposalIdAt[epoch];
        Proposal storage p = _proposals[proposalId];
        // The window check below compares hours-to-days windows with a timestamp producers can shift by seconds (T6).
        // slither-disable-next-line timestamp
        require(proposalId != 0 && _isLive(proposalId, p), ProposalNotLive(proposalId));
        uint256 closesAt = uint256(p.proposedAt) + CHALLENGE_WINDOW;
        // forge-lint: disable-next-line(block-timestamp)
        require(block.timestamp < closesAt, ChallengeWindowClosed(proposalId, closesAt));

        p.activeGames += 1;
        lockedBonds += msg.value;
        preStateRoot = epoch == 1 ? GENESIS_STATE_ROOT : _proposals[proposalIdAt[epoch - 1]].stateRoot;
        emit ChallengeOpened(proposalId, challenger, msg.value);
    }

    /// @inheritdoc IOutputOracle
    function settleChallenge(uint256 proposalId, address challenger, uint256 bond, Outcome outcome)
        external
        onlyDisputeGame
        returns (Outcome effective)
    {
        Proposal storage p = _proposals[proposalId];
        effective = _isLive(proposalId, p) ? outcome : Outcome.Cancelled;
        // The game only settles games it opened, so activeGames >= 1 here.
        p.activeGames -= 1;
        lockedBonds -= bond;

        if (effective == Outcome.ChallengerWins) {
            p.status = ProposalStatus.Invalidated;
            nextEpoch = p.epoch;
            lockedBonds -= PROPOSER_BOND;
            uint256 burn = PROPOSER_BOND * BURN_BPS / BPS;
            _burn(burn);
            emit OutputInvalidated(proposalId, p.epoch, challenger);
            _credit(challenger, bond + PROPOSER_BOND - burn);
        } else if (effective == Outcome.DefenderWins) {
            uint256 burn = bond * BURN_BPS / BPS;
            _burn(burn);
            _credit(p.proposer, bond - burn);
        } else {
            _credit(challenger, bond);
        }
        emit ChallengeSettled(proposalId, challenger, effective);
    }

    /// @inheritdoc IOutputOracle
    function isLive(uint256 proposalId) external view returns (bool) {
        return _isLive(proposalId, _proposals[proposalId]);
    }

    /// @inheritdoc IOutputOracle
    function getProposal(uint256 proposalId) external view returns (Proposal memory) {
        return _proposals[proposalId];
    }

    /// @inheritdoc IOutputOracle
    function finalizedStateRoot(uint64 epoch) external view returns (bytes32) {
        require(epoch <= lastFinalizedEpoch, NotFinalized(epoch));
        return epoch == 0 ? GENESIS_STATE_ROOT : _proposals[proposalIdAt[epoch]].stateRoot;
    }

    /// @notice Output root of an epoch's canonical proposal.
    /// @param epoch The epoch.
    /// @return keccak256(abi.encode(OUTPUT_VERSION, epoch, stateRoot)).
    function outputRootAt(uint64 epoch) external view returns (bytes32) {
        require(epoch < nextEpoch, UnknownEpoch(epoch));
        bytes32 root = epoch == 0 ? GENESIS_STATE_ROOT : _proposals[proposalIdAt[epoch]].stateRoot;
        return RollupSpec.outputRoot(epoch, root);
    }

    function _isCanonical(uint256 proposalId, Proposal storage p) private view returns (bool) {
        return p.epoch != 0 && p.epoch < nextEpoch && proposalIdAt[p.epoch] == proposalId;
    }

    function _isLive(uint256 proposalId, Proposal storage p) private view returns (bool) {
        return p.status == ProposalStatus.Proposed && _isCanonical(proposalId, p);
    }

    function _credit(address account, uint256 amount) private {
        if (amount == 0) return;
        credit[account] += amount;
        totalCredit += amount;
        emit Credited(account, amount);
    }

    function _burn(uint256 amount) private {
        if (amount == 0) return;
        totalBurned += amount;
        emit Burned(amount);
    }

    function _onlyDisputeGame() private view {
        require(msg.sender == DISPUTE_GAME, OnlyDisputeGame(msg.sender));
    }
}
