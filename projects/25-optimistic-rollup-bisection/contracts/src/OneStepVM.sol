// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {MerkleProof} from "@openzeppelin-contracts/utils/cryptography/MerkleProof.sol";
import {Hashes} from "@openzeppelin-contracts/utils/cryptography/Hashes.sol";
import {IOneStepVM} from "./interfaces/IOneStepVM.sol";
import {Machine, StepProof} from "./lib/Types.sol";
import {VmSpec} from "./lib/VmSpec.sol";
import {SparseMerkle} from "./lib/SparseMerkle.sol";

/// @title OneStepVM
/// @notice On-chain reference semantics of the rollup's stack VM: executes exactly one instruction from a committed
///         pre-state. The bisection game calls it once, at the single step two parties disagree on.
/// @dev Stateless and `pure`: everything the instruction needs is either in the committed `Machine` or proven by the
///      `StepProof` witness against one of its roots. The Rust interpreter in `crates/vm` implements the same
///      transition function; `crates/diff` runs both side by side on random programs inside revm.
///
///      Evaluation order (identical in Rust, and it matters because it decides which condition wins):
///       1. a halted or errored machine is a fixed point;
///       2. `pc >= codeSize` errors;
///       3. the instruction leaf must verify against `codeRoot` (revert otherwise);
///       4. undefined opcode, FAIL, or an out-of-range DUP/SWAP operand errors; HALT halts;
///       5. stack underflow or overflow errors;
///       6. revealed stack words must hash to `stackHash` (revert otherwise);
///       7. the opcode executes; an invalid jump target errors. Erroring changes nothing but `status`.
contract OneStepVM is IOneStepVM {
    /// @dev Sentinel returned by `_shape` for instructions that error the machine.
    uint256 private constant INVALID = type(uint256).max;

    /// @notice The instruction witness does not verify against the code root.
    /// @param pc Program counter being executed.
    /// @param opcode Claimed opcode.
    /// @param imm Claimed immediate.
    error InvalidInstructionProof(uint32 pc, uint8 opcode, uint256 imm);

    /// @notice The number of revealed stack words is not what the opcode reads.
    /// @param expected Words the opcode reads.
    /// @param supplied Words in the witness.
    error StackRevealLength(uint256 expected, uint256 supplied);

    /// @notice The revealed stack words do not hash to the committed stack hash.
    /// @param expected Committed stack hash.
    /// @param computed Hash implied by the witness.
    error InvalidStackProof(bytes32 expected, bytes32 computed);

    /// @notice The supplied input tape does not hash to the committed input root.
    /// @param expected Committed input root.
    /// @param computed keccak256 of the supplied tape.
    error InvalidTape(bytes32 expected, bytes32 computed);

    /// @notice The state witness does not verify against the committed state root.
    /// @param expected Committed state root.
    /// @param computed Root implied by the witness.
    error InvalidStateProof(bytes32 expected, bytes32 computed);

    /// @inheritdoc IOneStepVM
    function step(Machine calldata pre, StepProof calldata proof) external pure returns (Machine memory post) {
        return _step(pre, proof);
    }

    /// @inheritdoc IOneStepVM
    function stepHash(Machine calldata pre, StepProof calldata proof) external pure returns (bytes32) {
        return VmSpec.hash(_step(pre, proof));
    }

    function _step(Machine calldata pre, StepProof calldata proof) private pure returns (Machine memory post) {
        post = pre;
        if (pre.status != VmSpec.STATUS_RUNNING) return post;
        if (pre.pc >= pre.codeSize) {
            post.status = VmSpec.STATUS_ERRORED;
            return post;
        }

        bytes32 leaf = VmSpec.instructionLeaf(pre.pc, proof.opcode, proof.imm);
        if (!MerkleProof.verifyCalldata(proof.codeProof, pre.codeRoot, leaf)) {
            revert InvalidInstructionProof(pre.pc, proof.opcode, proof.imm);
        }

        uint8 op = proof.opcode;
        if (op == VmSpec.OP_HALT) {
            post.status = VmSpec.STATUS_HALTED;
            return post;
        }
        (uint256 reads, uint256 writes) = _shape(op, proof.imm);
        if (reads == INVALID || pre.stackDepth < reads || uint256(pre.stackDepth) - reads + writes > VmSpec.MAX_STACK) {
            post.status = VmSpec.STATUS_ERRORED;
            return post;
        }
        _checkStack(pre.stackHash, proof, reads);

        (bytes32[] memory out, bool errored) = _execute(pre, proof, post, op, writes);
        if (errored) {
            // Only the status changes on error; restore anything `_execute` touched.
            post = pre;
            post.status = VmSpec.STATUS_ERRORED;
            return post;
        }

        bytes32 h = proof.stackRest;
        for (uint256 i = out.length; i > 0; --i) {
            h = Hashes.efficientKeccak256(out[i - 1], h);
        }
        post.stackHash = h;
        // Bounded by MAX_STACK above, so the narrowing cannot truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        post.stackDepth = uint32(uint256(pre.stackDepth) - reads + writes);
    }

    /// @dev Stack words read and written back by `op`. `reads == INVALID` flags undefined opcodes, FAIL and
    ///      out-of-range DUP/SWAP operands.
    function _shape(uint8 op, uint256 imm) private pure returns (uint256 reads, uint256 writes) {
        if (op == VmSpec.OP_PUSH || op == VmSpec.OP_INPUTSIZE) return (0, 1);
        if (op == VmSpec.OP_POP || op == VmSpec.OP_JUMPI) return (1, 0);
        if (op == VmSpec.OP_JUMP) return (0, 0);
        if (op == VmSpec.OP_DUP) {
            if (imm > VmSpec.MAX_STACK_REACH) return (INVALID, 0);
            return (imm + 1, imm + 2);
        }
        if (op == VmSpec.OP_SWAP) {
            if (imm == 0 || imm > VmSpec.MAX_STACK_REACH) return (INVALID, 0);
            return (imm + 1, imm + 1);
        }
        if (op >= VmSpec.OP_ADD && op <= VmSpec.OP_OR && op != VmSpec.OP_ISZERO) return (2, 1);
        if (op == VmSpec.OP_ISZERO || op == VmSpec.OP_INPUT || op == VmSpec.OP_SLOAD) return (1, 1);
        if (op == VmSpec.OP_HASH || op == VmSpec.OP_SSTORE) return (2, op == VmSpec.OP_HASH ? 1 : 0);
        if (op == VmSpec.OP_ECRECOVER) return (4, 1);
        // FAIL and undefined opcodes.
        return (INVALID, 0);
    }

    function _checkStack(bytes32 committed, StepProof calldata proof, uint256 reads) private pure {
        if (proof.stack.length != reads) revert StackRevealLength(reads, proof.stack.length);
        bytes32 h = proof.stackRest;
        for (uint256 i = reads; i > 0; --i) {
            h = Hashes.efficientKeccak256(proof.stack[i - 1], h);
        }
        if (h != committed) revert InvalidStackProof(committed, h);
    }

    /// @dev Executes `op` over the revealed words. Returns the words to push back on top of `stackRest` (top first).
    ///      Writes `pc` and `stateRoot` into `post`; the caller discards `post` when `errored` is true.
    function _execute(Machine calldata pre, StepProof calldata proof, Machine memory post, uint8 op, uint256 writes)
        private
        pure
        returns (bytes32[] memory out, bool errored)
    {
        out = new bytes32[](writes);
        // pc < codeSize <= type(uint32).max, so pc + 1 fits in uint32.
        post.pc = pre.pc + 1;
        bytes32[] calldata s = proof.stack;

        if (op == VmSpec.OP_PUSH) {
            out[0] = bytes32(proof.imm);
        } else if (op == VmSpec.OP_POP) {
            // Nothing is written back.
        } else if (op == VmSpec.OP_DUP) {
            uint256 n = proof.imm;
            out[0] = s[n];
            for (uint256 i; i <= n; ++i) {
                out[i + 1] = s[i];
            }
        } else if (op == VmSpec.OP_SWAP) {
            uint256 n = proof.imm;
            for (uint256 i; i <= n; ++i) {
                out[i] = s[i];
            }
            (out[0], out[n]) = (s[n], s[0]);
        } else if (op >= VmSpec.OP_ADD && op <= VmSpec.OP_OR && op != VmSpec.OP_ISZERO) {
            out[0] = bytes32(_binary(op, uint256(s[0]), uint256(s[1])));
        } else if (op == VmSpec.OP_ISZERO) {
            out[0] = s[0] == bytes32(0) ? bytes32(uint256(1)) : bytes32(0);
        } else if (op == VmSpec.OP_HASH) {
            out[0] = Hashes.efficientKeccak256(s[0], s[1]);
        } else if (op == VmSpec.OP_JUMP || (op == VmSpec.OP_JUMPI && s[0] != bytes32(0))) {
            errored = proof.imm >= pre.codeSize;
            // imm < codeSize <= type(uint32).max when not errored, so the narrowing cannot truncate.
            // forge-lint: disable-next-line(unsafe-typecast)
            if (!errored) post.pc = uint32(proof.imm);
        } else if (op == VmSpec.OP_JUMPI) {
            // Condition is zero: fall through to pc + 1.
        } else if (op == VmSpec.OP_INPUT) {
            out[0] = _readTape(pre, proof.tape, uint256(s[0]));
        } else if (op == VmSpec.OP_INPUTSIZE) {
            out[0] = bytes32(uint256(pre.inputSize));
        } else if (op == VmSpec.OP_SLOAD) {
            _checkState(pre.stateRoot, s[0], proof);
            out[0] = proof.leafValue;
        } else if (op == VmSpec.OP_SSTORE) {
            _checkState(pre.stateRoot, s[0], proof);
            post.stateRoot = SparseMerkle.computeRoot(s[0], s[1], proof.siblingBitmap, proof.siblings);
        } else {
            // OP_ECRECOVER: the only remaining opcode `_shape` accepts.
            out[0] = bytes32(uint256(uint160(_ecrecover(s[0], uint256(s[1]), s[2], s[3]))));
        }
    }

    function _binary(uint8 op, uint256 a, uint256 b) private pure returns (uint256 r) {
        // VM arithmetic is modulo 2^256 by specification (like the EVM), so wrapping is the intended semantics.
        unchecked {
            if (op == VmSpec.OP_ADD) return a + b;
            if (op == VmSpec.OP_SUB) return a - b;
            if (op == VmSpec.OP_MUL) return a * b;
        }
        if (op == VmSpec.OP_DIV) return b == 0 ? 0 : a / b;
        if (op == VmSpec.OP_LT) return a < b ? 1 : 0;
        if (op == VmSpec.OP_GT) return a > b ? 1 : 0;
        if (op == VmSpec.OP_EQ) return a == b ? 1 : 0;
        if (op == VmSpec.OP_AND) return a & b;
        return a | b; // OP_OR
    }

    function _readTape(Machine calldata pre, bytes calldata tape, uint256 index) private pure returns (bytes32 word) {
        bytes32 computed = keccak256(tape);
        if (computed != pre.inputRoot) revert InvalidTape(pre.inputRoot, computed);
        uint256 words = tape.length / 32;
        if (index >= pre.inputSize || index >= words) return bytes32(0);
        word = bytes32(tape[index * 32:index * 32 + 32]);
    }

    function _checkState(bytes32 root, bytes32 key, StepProof calldata proof) private pure {
        bytes32 computed = SparseMerkle.computeRoot(key, proof.leafValue, proof.siblingBitmap, proof.siblings);
        if (computed != root) revert InvalidStateProof(root, computed);
    }

    /// @dev Mirrors the ecrecover precompile exactly: `v` must be the full word 27 or 28, otherwise the result is 0.
    ///      Solidity's `ecrecover` takes a `uint8`, so the word is range-checked before narrowing.
    function _ecrecover(bytes32 digest, uint256 v, bytes32 r, bytes32 s) private pure returns (address) {
        if (v != 27 && v != 28) return address(0);
        // v is 27 or 28 here, so the uint8 narrowing is exact. Malleable (high-s) signatures are accepted on purpose:
        // the VM must reproduce the precompile, and L2 replay protection comes from account nonces.
        // forge-lint: disable-next-line(unsafe-typecast,ecrecover)
        return ecrecover(digest, uint8(v), r, s);
    }
}
