// SPDX-License-Identifier: MIT
//! `sol!` interfaces of the L1 contracts, written against `contracts/src/interfaces`.
//!
//! The bytecode is loaded at runtime from `contracts/out` (see [`crate::artifacts`]), so building the Rust workspace
//! never requires a Solidity toolchain. `tests::bindings_match_artifacts` checks every function and error selector
//! and every event topic declared here (all of them, through the `SELECTORS` tables `sol!` generates) against the
//! compiled ABI, so the two cannot drift silently; derivation depends on the event signatures matching exactly.
#![allow(missing_docs, clippy::too_many_arguments)]

use alloy::sol;

sol! {
    #[derive(Debug, Default, PartialEq, Eq)]
    struct Record {
        uint256 kind;
        uint256 from;
        uint256 to;
        uint256 amount;
        uint256 nonce;
        uint256 v;
        uint256 r;
        uint256 s;
    }

    #[derive(Debug, Default, PartialEq, Eq)]
    struct Machine {
        uint8 status;
        uint32 pc;
        uint32 stackDepth;
        bytes32 stackHash;
        bytes32 stateRoot;
        bytes32 codeRoot;
        uint32 codeSize;
        bytes32 inputRoot;
        uint32 inputSize;
    }

    #[derive(Debug, Default, PartialEq, Eq)]
    struct StepProof {
        uint8 opcode;
        uint256 imm;
        bytes32[] codeProof;
        bytes32[] stack;
        bytes32 stackRest;
        bytes32 leafValue;
        uint256 siblingBitmap;
        bytes32[] siblings;
        bytes tape;
    }

    #[derive(Debug, Default, PartialEq, Eq)]
    struct SmtProof {
        uint256 bitmap;
        bytes32[] siblings;
    }

    #[sol(rpc)]
    interface IForcedInclusionQueue {
        event MessageEnqueued(uint256 indexed index, Record record, uint64 enqueuedAt, bytes32 accumulator);
        error OnlyBridge(address caller);
        error IndexOutOfRange(uint256 index, uint256 length);
        error ZeroParameter();
        function enqueueDeposit(address from, address to, uint256 amount) external returns (uint256 index);
        function forceTransfer(address to, uint256 amount) external returns (uint256 index);
        function forceWithdrawal(address recipient, uint256 amount) external returns (uint256 index);
        function length() external view returns (uint256);
        function accumulatorBefore(uint256 index) external view returns (bytes32);
        function enqueuedAt(uint256 index) external view returns (uint64);
        function deadline(uint256 index) external view returns (uint256);
        function isOverdue(uint256 index) external view returns (bool);
        function recordHash(Record calldata record) external pure returns (bytes32);
        function INCLUSION_WINDOW() external view returns (uint64);
        function BRIDGE() external view returns (address);
    }

    #[sol(rpc)]
    interface IBatchInbox {
        #[derive(Debug, Default, PartialEq, Eq)]
        struct Batch {
            bytes32 tapeHash;
            uint32 tapeSize;
            uint64 queueStart;
            uint64 queueEnd;
            uint64 l1Block;
            bool forced;
        }
        event BatchAppended(uint256 indexed epoch, bytes32 tapeHash, uint32 tapeSize, uint64 queueStart, uint64 queueEnd, bool forced, bytes txData);
        event SequencerUpdated(address indexed previous, address indexed current);
        error OnlySequencer(address caller);
        error InvalidTxData(uint256 length);
        error TooManyQueueRecords(uint256 count, uint256 max);
        error QueueRangeOutOfBounds(uint256 end, uint256 length);
        error QueueRecordsMismatch(bytes32 expected, bytes32 computed);
        error ForcedInclusionViolated(uint256 index, uint256 deadline);
        error NothingOverdue();
        error UnknownEpoch(uint256 epoch);
        error ZeroParameter();
        function submitBatch(bytes calldata txData, Record[] calldata queueRecords) external returns (uint256 epoch);
        function forceBatch(Record[] calldata queueRecords) external returns (uint256 epoch);
        function setSequencer(address newSequencer) external;
        function sequencer() external view returns (address);
        function batchCount() external view returns (uint256);
        function queueCursor() external view returns (uint256);
        function batch(uint256 epoch) external view returns (Batch memory);
        function QUEUE() external view returns (address);
        function MAX_SEQUENCED_TXS() external view returns (uint256);
        function MAX_QUEUE_PER_BATCH() external view returns (uint256);
    }

    #[sol(rpc)]
    interface IOutputOracle {
        #[derive(Debug, Default, PartialEq, Eq)]
        struct Proposal {
            bytes32 stateRoot;
            address proposer;
            uint64 epoch;
            uint64 proposedAt;
            uint32 activeGames;
            uint8 status;
        }
        event OutputProposed(uint256 indexed proposalId, uint64 indexed epoch, bytes32 stateRoot, bytes32 outputRoot, address indexed proposer);
        event OutputFinalized(uint256 indexed proposalId, uint64 indexed epoch);
        event OutputInvalidated(uint256 indexed proposalId, uint64 indexed epoch, address indexed challenger);
        event OrphanedBondReclaimed(uint256 indexed proposalId, address indexed proposer);
        event ChallengeOpened(uint256 indexed proposalId, address indexed challenger, uint256 bond);
        event ChallengeSettled(uint256 indexed proposalId, address indexed challenger, uint8 outcome);
        event Credited(address indexed account, uint256 amount);
        event Burned(uint256 amount);
        event CreditClaimed(address indexed account, uint256 amount);
        error IncorrectBond(uint256 expected, uint256 supplied);
        error NotNextEpoch(uint64 expected, uint64 supplied);
        error EpochNotPosted(uint64 epoch, uint256 batchCount);
        error OnlyDisputeGame(address caller);
        error ProposalNotLive(uint256 proposalId);
        error ChallengeWindowClosed(uint256 proposalId, uint256 closedAt);
        error CannotFinalize(uint64 epoch);
        error NotOrphaned(uint256 proposalId);
        error NoCredit();
        error NotFinalized(uint64 epoch);
        error UnknownEpoch(uint64 epoch);
        error ZeroParameter();
        function propose(uint64 epoch, bytes32 stateRoot) external payable returns (uint256 proposalId);
        function finalize(uint64 epoch) external;
        function reclaimOrphanedBond(uint256 proposalId) external;
        function claimCredit() external;
        function isLive(uint256 proposalId) external view returns (bool);
        function getProposal(uint256 proposalId) external view returns (Proposal memory);
        function proposalIdAt(uint64 epoch) external view returns (uint256);
        function nextEpoch() external view returns (uint64);
        function lastFinalizedEpoch() external view returns (uint64);
        function finalizedStateRoot(uint64 epoch) external view returns (bytes32);
        function outputRootAt(uint64 epoch) external view returns (bytes32);
        function credit(address account) external view returns (uint256);
        function lockedBonds() external view returns (uint256);
        function totalCredit() external view returns (uint256);
        function totalBurned() external view returns (uint256);
        function proposalCount() external view returns (uint256);
        function PROPOSER_BOND() external view returns (uint256);
        function CHALLENGE_WINDOW() external view returns (uint64);
        function GENESIS_STATE_ROOT() external view returns (bytes32);
    }

    #[sol(rpc)]
    interface IDisputeGame {
        #[derive(Debug, Default, PartialEq, Eq)]
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
            uint8 phase;
            uint8 outcome;
        }
        event GameCreated(uint256 indexed gameId, uint256 indexed proposalId, uint64 epoch, address defender, address indexed challenger, bytes32 initialHash);
        event EndCommitted(uint256 indexed gameId, bytes32 endHash);
        event Bisected(uint256 indexed gameId, uint64 mid, bytes32 midHash);
        event Chosen(uint256 indexed gameId, bool agree, uint64 lo, uint64 hi);
        event StepExecuted(uint256 indexed gameId, uint64 stepIndex, bytes32 postHash, bool defenderCorrect);
        event GameResolved(uint256 indexed gameId, uint8 outcome);
        error IncorrectBond(uint256 expected, uint256 supplied);
        error UnknownGame(uint256 gameId);
        error WrongPhase(uint256 gameId, uint8 phase);
        error NotYourTurn(address caller, address expected);
        error ClockExpired(uint256 gameId);
        error ClockNotExpired(uint256 gameId, uint256 expiresAt);
        error InvalidEndState(uint8 status, bytes32 stateRoot);
        error PreStateMismatch(bytes32 expected, bytes32 supplied);
        error ProposalStillLive(uint256 proposalId);
        error InvalidParameter();
        function challenge(uint64 epoch) external payable returns (uint256 gameId);
        function commitEnd(uint256 gameId, Machine calldata end) external;
        function bisect(uint256 gameId, bytes32 midHash) external;
        function choose(uint256 gameId, bool agree) external;
        function step(uint256 gameId, Machine calldata pre, StepProof calldata proof) external;
        function claimTimeout(uint256 gameId) external;
        function cancel(uint256 gameId) external;
        function getGame(uint256 gameId) external view returns (Game memory);
        function initialMachine(uint64 epoch, bytes32 preStateRoot) external view returns (Machine memory);
        function toMove(uint256 gameId) external view returns (address);
        function deadline(uint256 gameId) external view returns (uint256);
        function gameCount() external view returns (uint256);
        function CODE_ROOT() external view returns (bytes32);
        function CODE_SIZE() external view returns (uint32);
        function MAX_DEPTH() external view returns (uint8);
        function CLOCK() external view returns (uint64);
        function CHALLENGER_BOND() external view returns (uint256);
    }

    #[sol(rpc)]
    interface IBridge {
        event DepositInitiated(address indexed from, address indexed to, uint256 amount, uint256 queueIndex);
        event WithdrawalFinalized(uint256 indexed withdrawalId, address indexed recipient, uint256 amount, uint64 epoch);
        error ZeroDeposit();
        error AlreadyFinalized(uint256 withdrawalId);
        error InvalidWithdrawalProof(bytes32 stateRoot, bytes32 computed);
        error ZeroParameter();
        function deposit(address to) external payable returns (uint256 queueIndex);
        function finalizeWithdrawal(uint64 epoch, uint256 withdrawalId, address recipient, uint256 amount, SmtProof calldata proof) external;
        function finalized(uint256 withdrawalId) external view returns (bool);
    }

    #[sol(rpc)]
    interface IOneStepVM {
        error InvalidInstructionProof(uint32 pc, uint8 opcode, uint256 imm);
        error StackRevealLength(uint256 expected, uint256 supplied);
        error InvalidStackProof(bytes32 expected, bytes32 computed);
        error InvalidTape(bytes32 expected, bytes32 computed);
        error InvalidStateProof(bytes32 expected, bytes32 computed);
        function step(Machine calldata pre, StepProof calldata proof) external pure returns (Machine memory post);
        function stepHash(Machine calldata pre, StepProof calldata proof) external pure returns (bytes32);
    }

    /// Constructor signatures, used to ABI-encode deployment arguments.
    interface Constructors {
        function forcedInclusionQueue(address bridge, uint64 inclusionWindow) external;
        function batchInbox(address queue, address initialOwner, address initialSequencer) external;
        function outputOracle(address inbox, address disputeGame, bytes32 genesisStateRoot, uint256 proposerBond, uint64 challengeWindow) external;
        function disputeGame(address oracle, address inbox, address vm, bytes32 codeRoot, uint32 codeSize, uint8 maxDepth, uint64 clock, uint256 challengerBond) external;
        function bridge(address queue, address oracle) external;
    }
}

/// Game phases (mirrors `IDisputeGame.Phase`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum Phase {
    /// Unused slot.
    None = 0,
    /// Defender must reveal its final state.
    AwaitingEnd = 1,
    /// Defender must post a midpoint.
    AwaitingMid = 2,
    /// Challenger must choose a half.
    AwaitingChoice = 3,
    /// The one-step proof decides.
    AwaitingStep = 4,
    /// Over.
    Resolved = 5,
}

impl Phase {
    /// Decodes the on-chain phase byte.
    pub fn from_u8(x: u8) -> Self {
        match x {
            1 => Self::AwaitingEnd,
            2 => Self::AwaitingMid,
            3 => Self::AwaitingChoice,
            4 => Self::AwaitingStep,
            5 => Self::Resolved,
            _ => Self::None,
        }
    }
}

/// Dispute outcomes (mirrors `IOutputOracle.Outcome`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum Outcome {
    /// Not resolved.
    None = 0,
    /// The output was proven wrong.
    ChallengerWins = 1,
    /// The challenge failed.
    DefenderWins = 2,
    /// The proposal left the canonical chain; bond refunded.
    Cancelled = 3,
}

impl Outcome {
    /// Decodes the on-chain outcome byte.
    pub fn from_u8(x: u8) -> Self {
        match x {
            1 => Self::ChallengerWins,
            2 => Self::DefenderWins,
            3 => Self::Cancelled,
            _ => Self::None,
        }
    }
}

/// Proposal statuses (mirrors `IOutputOracle.ProposalStatus`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum ProposalStatus {
    /// No proposal.
    None = 0,
    /// Pending.
    Proposed = 1,
    /// Final.
    Finalized = 2,
    /// Proven wrong.
    Invalidated = 3,
    /// Truncated away by an earlier invalidation; bond refunded.
    Orphaned = 4,
}

impl ProposalStatus {
    /// Decodes the on-chain status byte.
    pub fn from_u8(x: u8) -> Self {
        match x {
            1 => Self::Proposed,
            2 => Self::Finalized,
            3 => Self::Invalidated,
            4 => Self::Orphaned,
            _ => Self::None,
        }
    }
}

impl From<rollup_vm::MachineCommitment> for Machine {
    fn from(m: rollup_vm::MachineCommitment) -> Self {
        Self {
            status: m.status,
            pc: m.pc,
            stackDepth: m.stackDepth,
            stackHash: m.stackHash,
            stateRoot: m.stateRoot,
            codeRoot: m.codeRoot,
            codeSize: m.codeSize,
            inputRoot: m.inputRoot,
            inputSize: m.inputSize,
        }
    }
}

impl From<Machine> for rollup_vm::MachineCommitment {
    fn from(m: Machine) -> Self {
        Self {
            status: m.status,
            pc: m.pc,
            stackDepth: m.stackDepth,
            stackHash: m.stackHash,
            stateRoot: m.stateRoot,
            codeRoot: m.codeRoot,
            codeSize: m.codeSize,
            inputRoot: m.inputRoot,
            inputSize: m.inputSize,
        }
    }
}

impl From<rollup_vm::StepProof> for StepProof {
    fn from(p: rollup_vm::StepProof) -> Self {
        Self {
            opcode: p.opcode,
            imm: p.imm,
            codeProof: p.codeProof,
            stack: p.stack,
            stackRest: p.stackRest,
            leafValue: p.leafValue,
            siblingBitmap: p.siblingBitmap,
            siblings: p.siblings,
            tape: p.tape,
        }
    }
}

impl From<rollup_stf::Record> for Record {
    fn from(r: rollup_stf::Record) -> Self {
        Self { kind: r.kind, from: r.from, to: r.to, amount: r.amount, nonce: r.nonce, v: r.v, r: r.r, s: r.s }
    }
}

impl From<Record> for rollup_stf::Record {
    fn from(r: Record) -> Self {
        Self { kind: r.kind, from: r.from, to: r.to, amount: r.amount, nonce: r.nonce, v: r.v, r: r.r, s: r.s }
    }
}

impl From<rollup_vm::SmtProof> for SmtProof {
    fn from(p: rollup_vm::SmtProof) -> Self {
        Self { bitmap: p.bitmap, siblings: p.siblings }
    }
}
