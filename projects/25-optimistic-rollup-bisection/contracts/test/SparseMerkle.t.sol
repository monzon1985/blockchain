// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {SparseMerkle} from "../src/lib/SparseMerkle.sol";
import {VmBuilder} from "./utils/VmBuilder.sol";

/// @dev Exposes the calldata-based library for testing.
contract SparseMerkleHarness {
    function computeRoot(bytes32 key, bytes32 value, uint256 bitmap, bytes32[] calldata siblings)
        external
        pure
        returns (bytes32)
    {
        return SparseMerkle.computeRoot(key, value, bitmap, siblings);
    }
}

contract SparseMerkleTest is Test {
    SparseMerkleHarness internal h;

    function setUp() public {
        h = new SparseMerkleHarness();
    }

    function test_emptyTreeIsZero() public view {
        assertEq(h.computeRoot(keccak256("k"), bytes32(0), 0, new bytes32[](0)), bytes32(0));
        assertEq(SparseMerkle.nodeHash(0, 0), bytes32(0));
        assertEq(SparseMerkle.leafHash(keccak256("k"), 0), bytes32(0));
    }

    function test_revert_lengthMismatch() public {
        bytes32[] memory extra = new bytes32[](1);
        vm.expectRevert(abi.encodeWithSelector(SparseMerkle.SmtProofLengthMismatch.selector, 1, 0));
        h.computeRoot(bytes32(0), bytes32(uint256(1)), 0, extra);
        vm.expectRevert(abi.encodeWithSelector(SparseMerkle.SmtProofLengthMismatch.selector, 0, 1));
        h.computeRoot(bytes32(0), bytes32(uint256(1)), 1 << 200, new bytes32[](0));
    }

    function testFuzz_singleLeafMatchesReference(bytes32 key, bytes32 value) public view {
        assertEq(h.computeRoot(key, value, 0, new bytes32[](0)), VmBuilder.singleLeafRoot(key, value));
    }

    function testFuzz_absenceProofInSingleLeafTree(bytes32 key, bytes32 other, bytes32 value) public view {
        vm.assume(key != other && value != 0);
        // In a tree holding only `other`, `key` is absent: its proof has one sibling, the subtree holding `other`.
        uint256 split = VmBuilder.splitHeight(key, other);
        bytes32[] memory siblings = new bytes32[](1);
        siblings[0] = VmBuilder.singleLeafSubtree(other, value, split);
        assertEq(h.computeRoot(key, 0, 1 << split, siblings), VmBuilder.singleLeafRoot(other, value));
    }

    function testFuzz_proofBindsValueAndKey(bytes32 a, bytes32 b, bytes32 va, bytes32 vb, bytes32 forged) public view {
        vm.assume(a != b && va != 0 && vb != 0 && forged != va);
        (bytes32 root, uint256 bitmap, bytes32[] memory siblings) = VmBuilder.twoLeaves(a, va, b, vb);
        assertEq(h.computeRoot(a, va, bitmap, siblings), root);
        assertTrue(h.computeRoot(a, forged, bitmap, siblings) != root);
    }
}
