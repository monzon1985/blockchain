// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Machine, StepProof} from "../lib/Types.sol";
import {IOutputOracle} from "./IOutputOracle.sol";

/// @title IDisputeGame
/// @notice Two-party interactive bisection over the execution trace of an epoch, ending in a single instruction
///         executed on-chain by the OneStepVM. Each party has a chess clock.
interface IDisputeGame {
    /// @notice Whose move it is and what the move must be.
    enum Phase {
        None,
        AwaitingEnd, // defender reveals its claimed final machine state
        AwaitingMid, // defender posts the state hash at the midpoint of [lo, hi]
        AwaitingChoice, // challenger agrees or disagrees with the midpoint
        AwaitingStep, // hi == lo + 1: the one-step proof decides
        Resolved
    }

    /// @notice A dispute.
    /// @param proposalId Disputed proposal.
    /// @param epoch Its epoch.
    /// @param defender The proposer.
    /// @param challenger The challenger.
    /// @param bond Challenger bond.
    /// @param createdAt Creation timestamp.
    /// @param lastMoveAt Timestamp of the last move (the current mover's clock runs from here).
    /// @param defenderClock Seconds the defender has left.
    /// @param challengerClock Seconds the challenger has left.
    /// @param lo Step index of the agreed state.
    /// @param hi Step index of the disputed state.
    /// @param loHash Agreed state hash at `lo`.
    /// @param hiHash Defender's (disputed) state hash at `hi`.
    /// @param midHash Defender's state hash at `(lo + hi) / 2`, pending the challenger's choice.
    /// @param moves Number of moves played.
    /// @param phase Current phase.
    /// @param outcome Final outcome once resolved.
    struct Game {
        uint256 proposalId;
        uint64 epoch;
        address defender;
        address challenger;
        uint128 bond;
        uint64 createdAt;
        uint64 lastMoveAt;
        uint64 defenderClock;
        uint64 challengerClock;
        uint64 lo;
        uint64 hi;
        bytes32 loHash;
        bytes32 hiHash;
        bytes32 midHash;
        uint16 moves;
        Phase phase;
        IOutputOracle.Outcome outcome;
    }

    /// @notice A dispute started.
    /// @param gameId Game id.
    /// @param proposalId Disputed proposal.
    /// @param epoch Its epoch.
    /// @param defender The proposer.
    /// @param challenger The challenger.
    /// @param initialHash Hash of the L1-computed initial machine state (step 0).
    event GameCreated(
        uint256 indexed gameId,
        uint256 indexed proposalId,
        uint64 epoch,
        address defender,
        address indexed challenger,
        bytes32 initialHash
    );

    /// @notice The defender committed to its final machine state.
    /// @param gameId Game id.
    /// @param endHash Hash of the claimed state at step `2^MAX_DEPTH`.
    event EndCommitted(uint256 indexed gameId, bytes32 endHash);

    /// @notice The defender posted a midpoint.
    /// @param gameId Game id.
    /// @param mid Step index of the midpoint.
    /// @param midHash Claimed state hash at `mid`.
    event Bisected(uint256 indexed gameId, uint64 mid, bytes32 midHash);

    /// @notice The challenger chose a half.
    /// @param gameId Game id.
    /// @param agree True when the challenger agreed with the midpoint (dispute moves to the upper half).
    /// @param lo New agreed step.
    /// @param hi New disputed step.
    event Chosen(uint256 indexed gameId, bool agree, uint64 lo, uint64 hi);

    /// @notice The disputed instruction was executed on-chain.
    /// @param gameId Game id.
    /// @param stepIndex Index of the executed step (`lo`).
    /// @param postHash Post-state hash computed by the OneStepVM.
    /// @param defenderCorrect True when it matched the defender's claim.
    event StepExecuted(uint256 indexed gameId, uint64 stepIndex, bytes32 postHash, bool defenderCorrect);

    /// @notice The game ended.
    /// @param gameId Game id.
    /// @param outcome Effective outcome applied by the oracle.
    event GameResolved(uint256 indexed gameId, IOutputOracle.Outcome outcome);

    /// @notice Wrong challenger bond.
    /// @param expected Required bond.
    /// @param supplied `msg.value`.
    error IncorrectBond(uint256 expected, uint256 supplied);

    /// @notice Unknown game.
    /// @param gameId The id.
    error UnknownGame(uint256 gameId);

    /// @notice The move does not fit the game's phase.
    /// @param gameId The game.
    /// @param phase Current phase.
    error WrongPhase(uint256 gameId, Phase phase);

    /// @notice Caller is not the party whose move it is.
    /// @param caller The caller.
    /// @param expected The party to move.
    error NotYourTurn(address caller, address expected);

    /// @notice The mover's clock has run out; only `claimTimeout` is possible now.
    /// @param gameId The game.
    error ClockExpired(uint256 gameId);

    /// @notice The mover's clock has not run out yet.
    /// @param gameId The game.
    /// @param expiresAt Timestamp after which the timeout can be claimed.
    error ClockNotExpired(uint256 gameId, uint256 expiresAt);

    /// @notice The revealed end state is not halted or does not carry the proposed state root.
    /// @param status Revealed status.
    /// @param stateRoot Revealed state root.
    error InvalidEndState(uint8 status, bytes32 stateRoot);

    /// @notice The supplied pre-state does not match the agreed hash.
    /// @param expected Agreed hash at `lo`.
    /// @param supplied Hash of the supplied machine.
    error PreStateMismatch(bytes32 expected, bytes32 supplied);

    /// @notice The disputed proposal is still live, so the game cannot be cancelled.
    /// @param proposalId The proposal.
    error ProposalStillLive(uint256 proposalId);

    /// @notice A constructor argument was zero or out of range.
    error InvalidParameter();

    /// @notice Opens a dispute against the canonical proposal of `epoch`, locking `CHALLENGER_BOND()`.
    /// @param epoch Disputed epoch.
    /// @return gameId The new game.
    function challenge(uint64 epoch) external payable returns (uint256 gameId);

    /// @notice Defender reveals its final machine state (must be halted with the proposed state root).
    /// @param gameId The game.
    /// @param end Claimed machine state at step `2^MAX_DEPTH`.
    function commitEnd(uint256 gameId, Machine calldata end) external;

    /// @notice Defender posts its state hash at the midpoint of the disputed range.
    /// @param gameId The game.
    /// @param midHash Claimed hash at `(lo + hi) / 2`.
    function bisect(uint256 gameId, bytes32 midHash) external;

    /// @notice Challenger agrees (dispute continues in the upper half) or disagrees (lower half) with the midpoint.
    /// @param gameId The game.
    /// @param agree Whether the challenger agrees with `midHash`.
    function choose(uint256 gameId, bool agree) external;

    /// @notice Executes the single disputed instruction and resolves the game. Callable by anyone while the
    ///         challenger's clock runs.
    /// @param gameId The game.
    /// @param pre Machine state whose hash is `loHash`.
    /// @param proof Witness for the instruction.
    function step(uint256 gameId, Machine calldata pre, StepProof calldata proof) external;

    /// @notice Resolves the game against the party whose clock has run out.
    /// @param gameId The game.
    function claimTimeout(uint256 gameId) external;

    /// @notice Cancels a game whose proposal left the canonical chain; refunds the challenger.
    /// @param gameId The game.
    function cancel(uint256 gameId) external;

    /// @notice Game by id.
    /// @param gameId The game.
    /// @return The game.
    function getGame(uint256 gameId) external view returns (Game memory);

    /// @notice Initial machine state for an epoch starting from `preStateRoot`.
    /// @param epoch The epoch.
    /// @param preStateRoot Agreed pre-state root.
    /// @return The machine at step 0.
    function initialMachine(uint64 epoch, bytes32 preStateRoot) external view returns (Machine memory);

    /// @notice Party that must move next (zero address once resolved).
    /// @param gameId The game.
    /// @return The address.
    function toMove(uint256 gameId) external view returns (address);

    /// @notice Timestamp after which the current mover can be timed out.
    /// @param gameId The game.
    /// @return lastMoveAt + remaining clock of the mover.
    function deadline(uint256 gameId) external view returns (uint256);
}
