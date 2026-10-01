// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @notice Commitment-level view of the rollup VM. Its `keccak256(abi.encode(machine))` is the per-step
///         state commitment that the bisection game narrows down. The Rust interpreter emits the same hash after
///         every instruction (see `crates/vm/src/machine.rs`).
/// @param status 0 = running, 1 = halted (program executed HALT), 2 = errored (invalid instruction or operand).
/// @param pc Index of the next instruction in the program.
/// @param stackDepth Number of words on the stack.
/// @param stackHash Hash chain over the stack: empty = 0, push(x) = keccak256(abi.encode(x, previousHash)).
/// @param stateRoot Root of the 256-level keccak sparse Merkle tree holding the L2 state.
/// @param codeRoot OpenZeppelin-compatible (sorted-pair) Merkle root over the program's instruction leaves.
/// @param codeSize Number of instructions in the program; fetching at or beyond it errors the machine.
/// @param inputRoot keccak256 of the input tape (the epoch's L1-derived records).
/// @param inputSize Length of the input tape in 32-byte words.
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

/// @notice Witness for executing exactly one instruction from a committed machine state.
/// @param opcode Opcode of the instruction at `pc` (proven by `codeProof`).
/// @param imm Immediate operand of that instruction.
/// @param codeProof Sorted-pair Merkle proof of the instruction leaf against `codeRoot`.
/// @param stack Revealed top-of-stack words, top first. Must contain exactly the words the opcode reads.
/// @param stackRest Stack hash of everything below the revealed words.
/// @param leafValue For SLOAD/SSTORE: the current value stored at the key (0 when absent).
/// @param siblingBitmap Bit `i` set means the sibling at tree level `i` (0 = leaf level) is non-zero.
/// @param siblings The non-zero siblings, ordered from the leaf level upwards.
/// @param tape For INPUT: the full input tape whose keccak256 must equal `inputRoot`.
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

/// @notice One 8-word record of the input tape. L1 queue messages and sequenced L2 transactions share this layout.
/// @param kind 1 deposit, 2 forced transfer, 3 forced withdrawal (L1 queue only); 4 transfer, 5 withdrawal (signed).
/// @param from Sender word (L1 `msg.sender` for queue messages, the signer for sequenced transactions).
/// @param to Recipient word (L2 account for deposits/transfers, L1 recipient for withdrawals).
/// @param amount Amount in wei.
/// @param nonce Sender nonce (sequenced transactions only).
/// @param v Signature recovery byte as a word (27 or 28), sequenced transactions only.
/// @param r Signature `r`, sequenced transactions only.
/// @param s Signature `s`, sequenced transactions only.
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

/// @notice Compressed sparse-Merkle proof (see `SparseMerkle`).
/// @param bitmap Bit `i` set means the sibling at level `i` is non-zero and taken from `siblings`.
/// @param siblings Non-zero siblings from the leaf level upwards.
struct SmtProof {
    uint256 bitmap;
    bytes32[] siblings;
}
