// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IDisputeGame} from "./interfaces/IDisputeGame.sol";
import {IOutputOracle} from "./interfaces/IOutputOracle.sol";
import {IBatchInbox} from "./interfaces/IBatchInbox.sol";
import {IOneStepVM} from "./interfaces/IOneStepVM.sol";
import {Machine, StepProof} from "./lib/Types.sol";
import {VmSpec} from "./lib/VmSpec.sol";

/// @title DisputeGame
/// @notice Referee for two-party bisection games over an epoch's execution trace.
/// @dev The trace of an epoch has exactly `2^MAX_DEPTH` steps: the program halts well before that (the inbox bounds
///      the tape, and so the trace), and a halted machine is a fixed point of `step`. Step 0 is computed here from L1
///      data only (parent state root, the batch's tape hash and size, the program's code root), so it is objectively
///      agreed. The defender claims the final state; each round it posts a midpoint and the challenger keeps the half
///      that still contains the disagreement. After `MAX_DEPTH` rounds one instruction separates an agreed state from
///      a disputed one, and the OneStepVM decides. Both parties play on chess clocks of `CLOCK` seconds each, so a game
///      is always resolvable by `createdAt + 2 * CLOCK + 1` and never needs more than `2 * MAX_DEPTH + 2` moves.
///      All ETH lives in the OutputOracle; this contract only forwards the challenger bond.
contract DisputeGame is IDisputeGame {
    /// @notice Output oracle and bond vault.
    IOutputOracle public immutable ORACLE;
    /// @notice Batch inbox (source of the epoch's input commitment).
    IBatchInbox public immutable INBOX;
    /// @notice One-step verifier.
    IOneStepVM public immutable VM;
    /// @notice Merkle root of the state-transition program.
    bytes32 public immutable CODE_ROOT;
    /// @notice Number of instructions in the state-transition program.
    uint32 public immutable CODE_SIZE;
    /// @notice Bisection depth; traces have `2^MAX_DEPTH` steps.
    uint8 public immutable MAX_DEPTH;
    /// @notice Seconds each party may spend in total across its moves.
    uint64 public immutable CLOCK;
    /// @notice Bond required to open a game, in wei.
    uint256 public immutable CHALLENGER_BOND;

    /// @notice Games by id (ids start at 1).
    mapping(uint256 gameId => Game) private _games;
    /// @notice Number of games ever created.
    uint256 public gameCount;

    /// @param oracle Output oracle.
    /// @param inbox Batch inbox.
    /// @param vm One-step verifier.
    /// @param codeRoot Program Merkle root.
    /// @param codeSize Program length.
    /// @param maxDepth Bisection depth (1..40). The program's longest possible trace must fit in `2^maxDepth` steps: for
    ///        the rollup's STF the worst batch the inbox accepts takes 11,832 steps, so deployments of this rollup use
    ///        14..40 (enforced by script/Deploy.s.sol; the step count is checked by `worst_case_batch_fits_the_trace`).
    /// @param clock Chess-clock budget per party, in seconds.
    /// @param challengerBond Challenger bond, in wei.
    constructor(
        IOutputOracle oracle,
        IBatchInbox inbox,
        IOneStepVM vm,
        bytes32 codeRoot,
        uint32 codeSize,
        uint8 maxDepth,
        uint64 clock,
        uint256 challengerBond
    ) {
        require(
            address(oracle) != address(0) && address(inbox) != address(0) && address(vm) != address(0)
                && codeRoot != bytes32(0) && codeSize != 0 && maxDepth != 0 && maxDepth <= 40 && clock != 0
                && challengerBond != 0 && challengerBond <= type(uint128).max,
            InvalidParameter()
        );
        ORACLE = oracle;
        INBOX = inbox;
        VM = vm;
        CODE_ROOT = codeRoot;
        CODE_SIZE = codeSize;
        MAX_DEPTH = maxDepth;
        CLOCK = clock;
        CHALLENGER_BOND = challengerBond;
    }

    /// @inheritdoc IDisputeGame
    function challenge(uint64 epoch) external payable returns (uint256 gameId) {
        require(msg.value == CHALLENGER_BOND, IncorrectBond(CHALLENGER_BOND, msg.value));
        // Trusted call into the oracle (immutable, protocol-owned, never calls back): it validates the proposal and
        // locks the bond. The game is written and announced afterwards because it needs the proposal id.
        // slither-disable-next-line reentrancy-benign,reentrancy-events
        (uint256 proposalId, bytes32 preStateRoot) = ORACLE.openChallenge{value: msg.value}(epoch, msg.sender);
        address defender = ORACLE.getProposal(proposalId).proposer;
        bytes32 initialHash = VmSpec.hash(initialMachine(epoch, preStateRoot));

        gameId = ++gameCount;
        Game storage g = _games[gameId];
        g.proposalId = proposalId;
        g.epoch = epoch;
        g.defender = defender;
        g.challenger = msg.sender;
        // Bounded by the constructor check `challengerBond <= type(uint128).max`.
        // forge-lint: disable-next-line(unsafe-typecast)
        g.bond = uint128(msg.value);
        // Timestamps fit in 64 bits for billions of years.
        // forge-lint: disable-next-line(unsafe-typecast)
        g.createdAt = uint64(block.timestamp);
        // forge-lint: disable-next-line(unsafe-typecast)
        g.lastMoveAt = uint64(block.timestamp);
        g.defenderClock = CLOCK;
        g.challengerClock = CLOCK;
        g.hi = uint64(1) << MAX_DEPTH;
        g.loHash = initialHash;
        g.phase = Phase.AwaitingEnd;
        // The only earlier external calls go to the protocol's own immutable oracle.
        // forge-lint: disable-next-line(reentrancy-events)
        emit GameCreated(gameId, proposalId, epoch, defender, msg.sender, initialHash);
    }

    /// @inheritdoc IDisputeGame
    function commitEnd(uint256 gameId, Machine calldata end) external {
        Game storage g = _move(gameId, Phase.AwaitingEnd);
        bytes32 claimed = ORACLE.getProposal(g.proposalId).stateRoot;
        require(
            end.status == VmSpec.STATUS_HALTED && end.stateRoot == claimed, InvalidEndState(end.status, end.stateRoot)
        );
        bytes32 endHash = VmSpec.hash(end);
        g.hiHash = endHash;
        g.phase = Phase.AwaitingMid;
        emit EndCommitted(gameId, endHash);
    }

    /// @inheritdoc IDisputeGame
    function bisect(uint256 gameId, bytes32 midHash) external {
        Game storage g = _move(gameId, Phase.AwaitingMid);
        g.midHash = midHash;
        g.phase = Phase.AwaitingChoice;
        emit Bisected(gameId, _mid(g), midHash);
    }

    /// @inheritdoc IDisputeGame
    function choose(uint256 gameId, bool agree) external {
        Game storage g = _move(gameId, Phase.AwaitingChoice);
        uint64 mid = _mid(g);
        if (agree) {
            g.lo = mid;
            g.loHash = g.midHash;
        } else {
            g.hi = mid;
            g.hiHash = g.midHash;
        }
        g.midHash = bytes32(0);
        g.phase = g.hi - g.lo == 1 ? Phase.AwaitingStep : Phase.AwaitingMid;
        emit Chosen(gameId, agree, g.lo, g.hi);
    }

    /// @inheritdoc IDisputeGame
    function step(uint256 gameId, Machine calldata pre, StepProof calldata proof) external {
        Game storage g = _load(gameId);
        require(g.phase == Phase.AwaitingStep, WrongPhase(gameId, g.phase));
        // slither-disable-start timestamp
        // Chess clocks are measured in seconds; block producers can only shift them by seconds.
        // forge-lint: disable-next-line(block-timestamp)
        require(block.timestamp - g.lastMoveAt <= g.challengerClock, ClockExpired(gameId));
        // slither-disable-end timestamp
        bytes32 preHash = VmSpec.hash(pre);
        require(preHash == g.loHash, PreStateMismatch(g.loHash, preHash));

        bytes32 postHash = VM.stepHash(pre, proof);
        bool defenderCorrect = postHash == g.hiHash;
        g.moves += 1;
        emit StepExecuted(gameId, g.lo, postHash, defenderCorrect);
        _resolve(gameId, g, defenderCorrect ? IOutputOracle.Outcome.DefenderWins : IOutputOracle.Outcome.ChallengerWins);
    }

    /// @inheritdoc IDisputeGame
    function claimTimeout(uint256 gameId) external {
        Game storage g = _load(gameId);
        Phase phase = g.phase;
        require(phase != Phase.Resolved, WrongPhase(gameId, phase));
        bool defenderToMove = _defenderToMove(phase);
        uint256 expiresAt = uint256(g.lastMoveAt) + (defenderToMove ? g.defenderClock : g.challengerClock);
        // slither-disable-start timestamp
        // Clocks are minutes to days; a producer's seconds of timestamp leeway cannot decide a timeout (T6).
        // forge-lint: disable-next-line(block-timestamp)
        require(block.timestamp > expiresAt, ClockNotExpired(gameId, expiresAt));
        // slither-disable-end timestamp
        _resolve(gameId, g, defenderToMove ? IOutputOracle.Outcome.ChallengerWins : IOutputOracle.Outcome.DefenderWins);
    }

    /// @inheritdoc IDisputeGame
    function cancel(uint256 gameId) external {
        Game storage g = _load(gameId);
        require(g.phase != Phase.Resolved, WrongPhase(gameId, g.phase));
        require(!ORACLE.isLive(g.proposalId), ProposalStillLive(g.proposalId));
        _resolve(gameId, g, IOutputOracle.Outcome.Cancelled);
    }

    /// @inheritdoc IDisputeGame
    function getGame(uint256 gameId) external view returns (Game memory) {
        return _games[gameId];
    }

    /// @inheritdoc IDisputeGame
    function initialMachine(uint64 epoch, bytes32 preStateRoot) public view returns (Machine memory) {
        IBatchInbox.Batch memory b = INBOX.batch(epoch);
        return Machine({
            status: VmSpec.STATUS_RUNNING,
            pc: 0,
            stackDepth: 0,
            stackHash: bytes32(0),
            stateRoot: preStateRoot,
            codeRoot: CODE_ROOT,
            codeSize: CODE_SIZE,
            inputRoot: b.tapeHash,
            inputSize: b.tapeSize
        });
    }

    /// @inheritdoc IDisputeGame
    function toMove(uint256 gameId) external view returns (address) {
        Game storage g = _load(gameId);
        if (g.phase == Phase.Resolved) return address(0);
        return _defenderToMove(g.phase) ? g.defender : g.challenger;
    }

    /// @inheritdoc IDisputeGame
    function deadline(uint256 gameId) external view returns (uint256) {
        Game storage g = _load(gameId);
        return uint256(g.lastMoveAt) + (_defenderToMove(g.phase) ? g.defenderClock : g.challengerClock);
    }

    /// @dev Loads a game, checks the phase and the caller, and charges the elapsed time to the mover's clock.
    function _move(uint256 gameId, Phase expected) private returns (Game storage g) {
        g = _load(gameId);
        // Slither's taint reaches the game struct, whose clocks hold timestamps; this line compares the phase. The
        // clock checks below are the T6 case: seconds of producer leeway against clocks of minutes to days.
        // slither-disable-next-line timestamp
        require(g.phase == expected, WrongPhase(gameId, g.phase));
        bool defender = _defenderToMove(expected);
        address mover = defender ? g.defender : g.challenger;
        require(msg.sender == mover, NotYourTurn(msg.sender, mover));
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 elapsed = uint64(block.timestamp) - g.lastMoveAt;
        if (defender) {
            require(elapsed <= g.defenderClock, ClockExpired(gameId));
            g.defenderClock -= elapsed;
        } else {
            require(elapsed <= g.challengerClock, ClockExpired(gameId));
            g.challengerClock -= elapsed;
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        g.lastMoveAt = uint64(block.timestamp);
        g.moves += 1;
    }

    function _resolve(uint256 gameId, Game storage g, IOutputOracle.Outcome outcome) private {
        g.phase = Phase.Resolved;
        // Trusted call into the protocol's own oracle; it moves no ETH out (payouts are pull-based credits) and never
        // calls back. The event reports the oracle's effective outcome, so it follows the call.
        // slither-disable-next-line reentrancy-events
        IOutputOracle.Outcome effective = ORACLE.settleChallenge(g.proposalId, g.challenger, g.bond, outcome);
        g.outcome = effective;
        // forge-lint: disable-next-line(reentrancy-events)
        emit GameResolved(gameId, effective);
    }

    function _load(uint256 gameId) private view returns (Game storage g) {
        g = _games[gameId];
        // A phase comparison (Slither's taint reaches the struct through its timestamp fields).
        // slither-disable-next-line timestamp
        require(g.phase != Phase.None, UnknownGame(gameId));
    }

    function _mid(Game storage g) private view returns (uint64) {
        return g.lo + (g.hi - g.lo) / 2;
    }

    function _defenderToMove(Phase phase) private pure returns (bool) {
        return phase == Phase.AwaitingEnd || phase == Phase.AwaitingMid;
    }
}
