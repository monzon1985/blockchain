// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {OneStepVM} from "../src/OneStepVM.sol";
import {Machine, StepProof} from "../src/lib/Types.sol";
import {VmSpec} from "../src/lib/VmSpec.sol";
import {SparseMerkle} from "../src/lib/SparseMerkle.sol";
import {VmBuilder} from "./utils/VmBuilder.sol";

contract OneStepVMTest is Test {
    using VmBuilder for VmBuilder.Program;

    OneStepVM internal osvm;

    function setUp() public {
        osvm = new OneStepVM();
    }

    // ---- helpers --------------------------------------------------------------------------------------------------

    function _prog(uint8 op, uint256 imm) internal pure returns (VmBuilder.Program memory p) {
        p.ops = new uint8[](2);
        p.imms = new uint256[](2);
        p.ops[0] = op;
        p.imms[0] = imm;
        p.ops[1] = VmSpec.OP_HALT;
    }

    function _words(uint256 a) internal pure returns (bytes32[] memory s) {
        s = new bytes32[](1);
        s[0] = bytes32(a);
    }

    function _words(uint256 a, uint256 b) internal pure returns (bytes32[] memory s) {
        s = new bytes32[](2);
        (s[0], s[1]) = (bytes32(a), bytes32(b));
    }

    function _words(uint256 a, uint256 b, uint256 c) internal pure returns (bytes32[] memory s) {
        s = new bytes32[](3);
        (s[0], s[1], s[2]) = (bytes32(a), bytes32(b), bytes32(c));
    }

    /// @dev Executes a one-instruction program over `stack` (bottom first), revealing `k` words.
    function _exec(uint8 op, uint256 imm, bytes32[] memory stack, uint256 k)
        internal
        view
        returns (Machine memory pre, Machine memory post)
    {
        VmBuilder.Program memory p = _prog(op, imm);
        pre = p.machine(stack, bytes32(0), "");
        post = osvm.step(pre, p.witness(0, stack, k));
    }

    /// @dev Asserts the post-state stack equals `expected` (bottom first) and pc advanced.
    function _assertStack(Machine memory post, bytes32[] memory expected) internal pure {
        assertEq(post.status, VmSpec.STATUS_RUNNING, "status");
        assertEq(post.stackDepth, expected.length, "depth");
        assertEq(post.stackHash, VmBuilder.stackHash(expected), "stack");
    }

    function _assertErroredOnly(Machine memory pre, Machine memory post) internal pure {
        Machine memory expected = pre;
        expected.status = VmSpec.STATUS_ERRORED;
        assertEq(VmSpec.hash(post), VmSpec.hash(expected), "only the status may change on error");
    }

    // ---- opcode semantics -----------------------------------------------------------------------------------------

    function test_push_pop() public view {
        (, Machine memory post) = _exec(VmSpec.OP_PUSH, 77, new bytes32[](0), 0);
        _assertStack(post, _words(77));
        assertEq(post.pc, 1);
        (, post) = _exec(VmSpec.OP_POP, 0, _words(1, 2), 1);
        _assertStack(post, _words(1));
    }

    function test_binaryOperatorsPopTopFirst() public view {
        // stack bottom-first [b, a]: a is the top operand
        uint8[9] memory ops = [
            VmSpec.OP_ADD,
            VmSpec.OP_SUB,
            VmSpec.OP_MUL,
            VmSpec.OP_DIV,
            VmSpec.OP_LT,
            VmSpec.OP_GT,
            VmSpec.OP_EQ,
            VmSpec.OP_AND,
            VmSpec.OP_OR
        ];
        uint256[9] memory expected = [uint256(13), 7, 30, 3, 0, 1, 0, 2, 11];
        for (uint256 i = 0; i < ops.length; ++i) {
            (, Machine memory post) = _exec(ops[i], 0, _words(3, 10), 2);
            _assertStack(post, _words(expected[i]));
        }
    }

    function test_arithmeticWraps() public view {
        (, Machine memory post) = _exec(VmSpec.OP_SUB, 0, _words(1, 0), 2);
        _assertStack(post, _words(type(uint256).max));
        (, post) = _exec(VmSpec.OP_ADD, 0, _words(1, type(uint256).max), 2);
        _assertStack(post, _words(0));
        (, post) = _exec(VmSpec.OP_DIV, 0, _words(0, 5), 2);
        _assertStack(post, _words(0));
    }

    function test_isZero_hash() public view {
        (, Machine memory post) = _exec(VmSpec.OP_ISZERO, 0, _words(0), 1);
        _assertStack(post, _words(1));
        (, post) = _exec(VmSpec.OP_HASH, 0, _words(2, 1), 2);
        _assertStack(post, _words(uint256(keccak256(abi.encode(uint256(1), uint256(2))))));
    }

    function test_dupAndSwap() public view {
        (, Machine memory post) = _exec(VmSpec.OP_DUP, 2, _words(1, 2, 3), 3);
        bytes32[] memory e = new bytes32[](4);
        (e[0], e[1], e[2], e[3]) = (bytes32(uint256(1)), bytes32(uint256(2)), bytes32(uint256(3)), bytes32(uint256(1)));
        _assertStack(post, e);
        (, post) = _exec(VmSpec.OP_SWAP, 2, _words(1, 2, 3), 3);
        _assertStack(post, _words(3, 2, 1));
    }

    function test_jumps() public view {
        VmBuilder.Program memory p = _prog(VmSpec.OP_JUMP, 1);
        Machine memory post = osvm.step(p.machine(new bytes32[](0), 0, ""), p.witness(0, new bytes32[](0), 0));
        assertEq(post.pc, 1);
        (, post) = _exec(VmSpec.OP_JUMPI, 0, _words(5), 1);
        assertEq(post.pc, 0, "taken");
        (, post) = _exec(VmSpec.OP_JUMPI, 0, _words(0), 1);
        assertEq(post.pc, 1, "not taken");
        // A not-taken JUMPI never inspects its target.
        (, post) = _exec(VmSpec.OP_JUMPI, 99, _words(0), 1);
        assertEq(post.status, VmSpec.STATUS_RUNNING);
    }

    function test_inputAndInputSize() public view {
        bytes memory tape = abi.encode(uint256(11), uint256(22));
        VmBuilder.Program memory p = _prog(VmSpec.OP_INPUT, 0);
        bytes32[] memory stack = _words(1);
        StepProof memory w = p.witness(0, stack, 1);
        w.tape = tape;
        Machine memory post = osvm.step(p.machine(stack, 0, tape), w);
        _assertStack(post, _words(22));

        stack = _words(7); // out of range reads zero
        w = p.witness(0, stack, 1);
        w.tape = tape;
        post = osvm.step(p.machine(stack, 0, tape), w);
        _assertStack(post, _words(0));

        p = _prog(VmSpec.OP_INPUTSIZE, 0);
        post = osvm.step(p.machine(new bytes32[](0), 0, tape), p.witness(0, new bytes32[](0), 0));
        _assertStack(post, _words(2));
    }

    function test_sloadAndSstoreAgainstTwoLeafTree() public view {
        bytes32 k1 = bytes32(uint256(5));
        bytes32 k2 = bytes32(uint256(6));
        (bytes32 root, uint256 bitmap, bytes32[] memory siblings) =
            VmBuilder.twoLeaves(k1, bytes32(uint256(50)), k2, bytes32(uint256(60)));

        VmBuilder.Program memory p = _prog(VmSpec.OP_SLOAD, 0);
        bytes32[] memory stack = _words(5);
        StepProof memory w = p.witness(0, stack, 1);
        (w.leafValue, w.siblingBitmap, w.siblings) = (bytes32(uint256(50)), bitmap, siblings);
        Machine memory post = osvm.step(p.machine(stack, root, ""), w);
        _assertStack(post, _words(50));

        p = _prog(VmSpec.OP_SSTORE, 0);
        stack = _words(99, 5); // value below, key on top
        w = p.witness(0, stack, 2);
        (w.leafValue, w.siblingBitmap, w.siblings) = (bytes32(uint256(50)), bitmap, siblings);
        post = osvm.step(p.machine(stack, root, ""), w);
        (bytes32 expected,,) = VmBuilder.twoLeaves(k1, bytes32(uint256(99)), k2, bytes32(uint256(60)));
        assertEq(post.stateRoot, expected);
        assertEq(post.stackDepth, 0);
    }

    function test_ecrecover() public {
        (address signer, uint256 pk) = makeAddrAndKey("signer");
        bytes32 digest = keccak256("rollup");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        bytes32[] memory stack = new bytes32[](4);
        (stack[0], stack[1], stack[2], stack[3]) = (s, r, bytes32(uint256(v)), digest);
        (, Machine memory post) = _exec(VmSpec.OP_ECRECOVER, 0, stack, 4);
        _assertStack(post, _words(uint256(uint160(signer))));

        // v must be exactly 27 or 28 as a full word, like the precompile.
        stack[2] = bytes32(uint256(v) + 256);
        (, post) = _exec(VmSpec.OP_ECRECOVER, 0, stack, 4);
        _assertStack(post, _words(0));
    }

    function test_haltAndFail() public view {
        (Machine memory pre, Machine memory post) = _exec(VmSpec.OP_HALT, 0, _words(1), 0);
        assertEq(post.status, VmSpec.STATUS_HALTED);
        assertEq(post.pc, pre.pc);
        (pre, post) = _exec(VmSpec.OP_FAIL, 0, _words(1), 0);
        _assertErroredOnly(pre, post);
    }

    // ---- error semantics ------------------------------------------------------------------------------------------

    function test_errors_leaveEverythingButStatus() public view {
        (Machine memory pre, Machine memory post) = _exec(VmSpec.OP_ADD, 0, _words(1), 0);
        _assertErroredOnly(pre, post); // underflow
        (pre, post) = _exec(VmSpec.OP_JUMP, 2, new bytes32[](0), 0);
        _assertErroredOnly(pre, post); // target == codeSize
        (pre, post) = _exec(VmSpec.OP_JUMPI, 7, _words(1), 1);
        _assertErroredOnly(pre, post); // taken jump outside the program
        (pre, post) = _exec(VmSpec.OP_DUP, 16, _words(1), 0);
        _assertErroredOnly(pre, post); // reach out of range
        (pre, post) = _exec(VmSpec.OP_SWAP, 0, _words(1), 0);
        _assertErroredOnly(pre, post); // SWAP 0 is invalid
        (pre, post) = _exec(0x42, 0, _words(1), 0);
        _assertErroredOnly(pre, post); // undefined opcode
    }

    function test_stackOverflowErrors() public view {
        VmBuilder.Program memory p = _prog(VmSpec.OP_PUSH, 1);
        Machine memory pre = p.machine(new bytes32[](0), 0, "");
        pre.stackDepth = uint32(VmSpec.MAX_STACK);
        Machine memory post = osvm.step(pre, p.witness(0, new bytes32[](0), 0));
        _assertErroredOnly(pre, post);
    }

    function test_pcOutOfRangeErrorsWithoutWitness() public view {
        VmBuilder.Program memory p = _prog(VmSpec.OP_PUSH, 1);
        Machine memory pre = p.machine(new bytes32[](0), 0, "");
        pre.pc = 2;
        StepProof memory empty;
        _assertErroredOnly(pre, osvm.step(pre, empty));
    }

    function test_stoppedMachinesAreFixedPoints() public view {
        VmBuilder.Program memory p = _prog(VmSpec.OP_PUSH, 1);
        Machine memory pre = p.machine(new bytes32[](0), 0, "");
        StepProof memory empty;
        pre.status = VmSpec.STATUS_HALTED;
        assertEq(VmSpec.hash(osvm.step(pre, empty)), VmSpec.hash(pre));
        pre.status = VmSpec.STATUS_ERRORED;
        assertEq(osvm.stepHash(pre, empty), VmSpec.hash(pre));
    }

    // ---- invalid witnesses revert -----------------------------------------------------------------------------------

    function test_revert_invalidInstructionProof() public {
        VmBuilder.Program memory p = _prog(VmSpec.OP_PUSH, 1);
        Machine memory pre = p.machine(new bytes32[](0), 0, "");
        StepProof memory w = p.witness(0, new bytes32[](0), 0);
        w.imm = 2;
        vm.expectRevert(
            abi.encodeWithSelector(OneStepVM.InvalidInstructionProof.selector, uint32(0), VmSpec.OP_PUSH, 2)
        );
        osvm.step(pre, w);
    }

    function test_revert_stackRevealLength() public {
        VmBuilder.Program memory p = _prog(VmSpec.OP_ADD, 0);
        bytes32[] memory stack = _words(1, 2);
        StepProof memory w = p.witness(0, stack, 1);
        vm.expectRevert(abi.encodeWithSelector(OneStepVM.StackRevealLength.selector, 2, 1));
        osvm.step(p.machine(stack, 0, ""), w);
    }

    function test_revert_invalidStackProof() public {
        VmBuilder.Program memory p = _prog(VmSpec.OP_ADD, 0);
        bytes32[] memory stack = _words(1, 2);
        StepProof memory w = p.witness(0, stack, 2);
        w.stack[0] = bytes32(uint256(3));
        vm.expectPartialRevert(OneStepVM.InvalidStackProof.selector);
        osvm.step(p.machine(stack, 0, ""), w);
    }

    function test_revert_invalidTape() public {
        VmBuilder.Program memory p = _prog(VmSpec.OP_INPUT, 0);
        bytes32[] memory stack = _words(0);
        StepProof memory w = p.witness(0, stack, 1);
        w.tape = abi.encode(uint256(1));
        vm.expectRevert(
            abi.encodeWithSelector(OneStepVM.InvalidTape.selector, keccak256(abi.encode(uint256(2))), keccak256(w.tape))
        );
        osvm.step(p.machine(stack, 0, abi.encode(uint256(2))), w);
    }

    function test_revert_invalidStateProof() public {
        VmBuilder.Program memory p = _prog(VmSpec.OP_SLOAD, 0);
        bytes32[] memory stack = _words(5);
        bytes32 root = VmBuilder.singleLeafRoot(bytes32(uint256(5)), bytes32(uint256(50)));
        StepProof memory w = p.witness(0, stack, 1);
        w.leafValue = bytes32(uint256(51)); // lie about the value
        vm.expectPartialRevert(OneStepVM.InvalidStateProof.selector);
        osvm.step(p.machine(stack, root, ""), w);
    }

    function test_revert_smtProofLengthMismatch() public {
        VmBuilder.Program memory p = _prog(VmSpec.OP_SLOAD, 0);
        bytes32[] memory stack = _words(5);
        StepProof memory w = p.witness(0, stack, 1);
        w.siblingBitmap = 3; // asks for two siblings, supplies none
        vm.expectRevert(abi.encodeWithSelector(SparseMerkle.SmtProofLengthMismatch.selector, 0, 2));
        osvm.step(p.machine(stack, 0, ""), w);
    }

    // ---- fuzz -----------------------------------------------------------------------------------------------------

    function testFuzz_arithmeticMatchesSolidity(uint256 a, uint256 b, uint8 which) public view {
        which = uint8(bound(which, 0, 3));
        uint8 op = [VmSpec.OP_ADD, VmSpec.OP_SUB, VmSpec.OP_MUL, VmSpec.OP_DIV][which];
        uint256 expected;
        unchecked {
            expected = which == 0 ? a + b : which == 1 ? a - b : which == 2 ? a * b : (b == 0 ? 0 : a / b);
        }
        (, Machine memory post) = _exec(op, 0, _words(b, a), 2);
        _assertStack(post, _words(expected));
    }

    function testFuzz_stepHashEqualsHashOfStep(uint256 imm, uint256 below) public view {
        VmBuilder.Program memory p = _prog(VmSpec.OP_PUSH, imm);
        bytes32[] memory stack = _words(below);
        Machine memory pre = p.machine(stack, 0, "");
        StepProof memory w = p.witness(0, stack, 0);
        assertEq(osvm.stepHash(pre, w), VmSpec.hash(osvm.step(pre, w)));
    }

    function testFuzz_singleLeafSstore(bytes32 key, bytes32 oldValue, bytes32 newValue) public view {
        bytes32 root = VmBuilder.singleLeafRoot(key, oldValue);
        VmBuilder.Program memory p = _prog(VmSpec.OP_SSTORE, 0);
        bytes32[] memory stack = new bytes32[](2);
        (stack[0], stack[1]) = (newValue, key);
        StepProof memory w = p.witness(0, stack, 2);
        w.leafValue = oldValue;
        Machine memory post = osvm.step(p.machine(stack, root, ""), w);
        assertEq(post.stateRoot, VmBuilder.singleLeafRoot(key, newValue));
    }
}
