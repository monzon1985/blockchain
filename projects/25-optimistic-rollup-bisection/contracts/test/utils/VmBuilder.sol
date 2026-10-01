// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Hashes} from "@openzeppelin-contracts/utils/cryptography/Hashes.sol";
import {Machine, StepProof} from "../../src/lib/Types.sol";
import {VmSpec} from "../../src/lib/VmSpec.sol";
import {SparseMerkle} from "../../src/lib/SparseMerkle.sol";

/// @notice Test-side builders for VM witnesses, written independently of the Rust prover: program Merkle trees
///         (sorted-pair, odd node promoted), hash-chained stacks and small sparse-Merkle trees.
library VmBuilder {
    struct Program {
        uint8[] ops;
        uint256[] imms;
    }

    function leaf(Program memory p, uint256 pc) internal pure returns (bytes32) {
        return VmSpec.instructionLeaf(pc, p.ops[pc], p.imms[pc]);
    }

    function _layer(bytes32[] memory prev) private pure returns (bytes32[] memory next) {
        next = new bytes32[]((prev.length + 1) / 2);
        for (uint256 i = 0; i < next.length; ++i) {
            next[i] = 2 * i + 1 < prev.length ? Hashes.commutativeKeccak256(prev[2 * i], prev[2 * i + 1]) : prev[2 * i];
        }
    }

    function _leaves(Program memory p) private pure returns (bytes32[] memory leaves) {
        leaves = new bytes32[](p.ops.length);
        for (uint256 i = 0; i < leaves.length; ++i) {
            leaves[i] = leaf(p, i);
        }
    }

    function root(Program memory p) internal pure returns (bytes32) {
        bytes32[] memory layer = _leaves(p);
        while (layer.length > 1) {
            layer = _layer(layer);
        }
        return layer.length == 0 ? bytes32(0) : layer[0];
    }

    function proof(Program memory p, uint256 pc) internal pure returns (bytes32[] memory out) {
        bytes32[] memory layer = _leaves(p);
        bytes32[] memory tmp = new bytes32[](64);
        uint256 n = 0;
        uint256 idx = pc;
        while (layer.length > 1) {
            uint256 sib = idx ^ 1;
            if (sib < layer.length) tmp[n++] = layer[sib];
            layer = _layer(layer);
            idx /= 2;
        }
        out = new bytes32[](n);
        for (uint256 i = 0; i < n; ++i) {
            out[i] = tmp[i];
        }
    }

    /// @dev Stack hash of `bottomFirst`.
    function stackHash(bytes32[] memory bottomFirst) internal pure returns (bytes32 h) {
        for (uint256 i = 0; i < bottomFirst.length; ++i) {
            h = Hashes.efficientKeccak256(bottomFirst[i], h);
        }
    }

    /// @dev Top `k` words (top first) and the hash below them.
    function reveal(bytes32[] memory bottomFirst, uint256 k)
        internal
        pure
        returns (bytes32[] memory top, bytes32 rest)
    {
        uint256 n = bottomFirst.length;
        top = new bytes32[](k);
        for (uint256 i = 0; i < k; ++i) {
            top[i] = bottomFirst[n - 1 - i];
        }
        bytes32[] memory below = new bytes32[](n - k);
        for (uint256 i = 0; i < n - k; ++i) {
            below[i] = bottomFirst[i];
        }
        rest = stackHash(below);
    }

    /// @dev Root of a subtree of height `height` holding one leaf (all siblings empty).
    function singleLeafSubtree(bytes32 key, bytes32 value, uint256 height) internal pure returns (bytes32 node) {
        node = SparseMerkle.leafHash(key, value);
        uint256 path = uint256(key);
        for (uint256 level = 0; level < height; ++level) {
            node = (path >> level) & 1 == 1
                ? SparseMerkle.nodeHash(bytes32(0), node)
                : SparseMerkle.nodeHash(node, bytes32(0));
        }
    }

    /// @dev Root of a tree holding a single leaf.
    function singleLeafRoot(bytes32 key, bytes32 value) internal pure returns (bytes32) {
        return singleLeafSubtree(key, value, SparseMerkle.DEPTH);
    }

    /// @dev Highest bit at which two distinct keys differ.
    function splitHeight(bytes32 a, bytes32 b) internal pure returns (uint256 h) {
        uint256 x = uint256(a) ^ uint256(b);
        h = 255;
        while ((x >> h) & 1 == 0) {
            --h;
        }
    }

    /// @dev Root of a two-leaf tree, and the compressed proof of `a` in it.
    function twoLeaves(bytes32 a, bytes32 va, bytes32 b, bytes32 vb)
        internal
        pure
        returns (bytes32 treeRoot, uint256 bitmapA, bytes32[] memory siblingsA)
    {
        uint256 h = splitHeight(a, b);
        bytes32 subA = singleLeafSubtree(a, va, h);
        bytes32 subB = singleLeafSubtree(b, vb, h);
        bytes32 node =
            (uint256(a) >> h) & 1 == 1 ? SparseMerkle.nodeHash(subB, subA) : SparseMerkle.nodeHash(subA, subB);
        for (uint256 level = h + 1; level < SparseMerkle.DEPTH; ++level) {
            node = (uint256(a) >> level) & 1 == 1
                ? SparseMerkle.nodeHash(bytes32(0), node)
                : SparseMerkle.nodeHash(node, bytes32(0));
        }
        treeRoot = node;
        bitmapA = 1 << h;
        siblingsA = new bytes32[](1);
        siblingsA[0] = subB;
    }

    function machine(Program memory p, bytes32[] memory stackBottomFirst, bytes32 stateRoot, bytes memory tape)
        internal
        pure
        returns (Machine memory m)
    {
        m = Machine({
            status: VmSpec.STATUS_RUNNING,
            pc: 0,
            // forge-lint: disable-next-line(unsafe-typecast)
            stackDepth: uint32(stackBottomFirst.length),
            stackHash: stackHash(stackBottomFirst),
            stateRoot: stateRoot,
            codeRoot: root(p),
            // forge-lint: disable-next-line(unsafe-typecast)
            codeSize: uint32(p.ops.length),
            inputRoot: keccak256(tape),
            // forge-lint: disable-next-line(unsafe-typecast)
            inputSize: uint32(tape.length / 32)
        });
    }

    /// @dev Witness for the instruction at `m.pc`, revealing the top `k` stack words.
    function witness(Program memory p, uint256 pc, bytes32[] memory stackBottomFirst, uint256 k)
        internal
        pure
        returns (StepProof memory w)
    {
        w.opcode = p.ops[pc];
        w.imm = p.imms[pc];
        w.codeProof = proof(p, pc);
        (w.stack, w.stackRest) = reveal(stackBottomFirst, k);
    }
}
