// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Machine} from "./Types.sol";

/// @title VmSpec
/// @notice Constants of the rollup VM and the machine-state commitment. The Rust interpreter
///         (`crates/vm`) mirrors every value here; the differential test suite fails if they drift.
library VmSpec {
    /// @notice Machine is executing.
    uint8 internal constant STATUS_RUNNING = 0;
    /// @notice Machine executed HALT; further steps are no-ops.
    uint8 internal constant STATUS_HALTED = 1;
    /// @notice Machine hit an invalid instruction or operand; further steps are no-ops.
    uint8 internal constant STATUS_ERRORED = 2;

    /// @notice Maximum number of stack words. Exceeding it errors the machine.
    uint256 internal constant MAX_STACK = 1024;
    /// @notice Deepest stack slot reachable by DUP/SWAP (immediate operand upper bound).
    uint256 internal constant MAX_STACK_REACH = 15;

    uint8 internal constant OP_HALT = 0x00;
    uint8 internal constant OP_PUSH = 0x01;
    uint8 internal constant OP_POP = 0x02;
    uint8 internal constant OP_DUP = 0x03;
    uint8 internal constant OP_SWAP = 0x04;
    uint8 internal constant OP_ADD = 0x05;
    uint8 internal constant OP_SUB = 0x06;
    uint8 internal constant OP_MUL = 0x07;
    uint8 internal constant OP_DIV = 0x08;
    uint8 internal constant OP_LT = 0x09;
    uint8 internal constant OP_GT = 0x0a;
    uint8 internal constant OP_EQ = 0x0b;
    uint8 internal constant OP_ISZERO = 0x0c;
    uint8 internal constant OP_AND = 0x0d;
    uint8 internal constant OP_OR = 0x0e;
    uint8 internal constant OP_HASH = 0x0f;
    uint8 internal constant OP_JUMP = 0x10;
    uint8 internal constant OP_JUMPI = 0x11;
    uint8 internal constant OP_INPUT = 0x12;
    uint8 internal constant OP_INPUTSIZE = 0x13;
    uint8 internal constant OP_SLOAD = 0x14;
    uint8 internal constant OP_SSTORE = 0x15;
    uint8 internal constant OP_ECRECOVER = 0x16;
    uint8 internal constant OP_FAIL = 0x17;
    /// @notice Highest defined opcode; anything above errors the machine.
    uint8 internal constant MAX_OPCODE = OP_FAIL;

    /// @notice Commitment to a machine state: keccak256 over its nine ABI-encoded words.
    /// @param m The machine state.
    /// @return The state hash compared by the bisection game.
    function hash(Machine memory m) internal pure returns (bytes32) {
        return keccak256(abi.encode(m));
    }

    /// @notice Leaf of the program Merkle tree for the instruction at `pc`.
    /// @dev Double-hashed (OpenZeppelin convention) so a 64-byte internal node can never be passed off as a leaf.
    /// @param pc Instruction index.
    /// @param opcode Instruction opcode.
    /// @param imm Instruction immediate.
    /// @return The leaf hash.
    function instructionLeaf(uint256 pc, uint256 opcode, uint256 imm) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(pc, opcode, imm))));
    }
}
