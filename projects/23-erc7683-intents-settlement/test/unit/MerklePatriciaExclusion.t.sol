// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {RLP} from "@openzeppelin-contracts/utils/RLP.sol";
import {TrieProof} from "@openzeppelin-contracts/utils/cryptography/TrieProof.sol";

import {FillProofLib} from "../../src/libraries/FillProofLib.sol";
import {MerklePatriciaExclusion} from "../../src/libraries/MerklePatriciaExclusion.sol";
import {MerklePatriciaBuilder} from "../utils/MerklePatriciaBuilder.sol";

/// @dev External entry points so reverts inside the libraries can be observed.
contract TrieHarness {
    function isAbsent(bytes32 root, bytes32 key, bytes[] memory proof) external pure returns (bool) {
        return MerklePatriciaExclusion.isAbsent(root, abi.encodePacked(key), proof);
    }

    function isAbsentRawKey(bytes32 root, bytes memory key, bytes[] memory proof) external pure returns (bool) {
        return MerklePatriciaExclusion.isAbsent(root, key, proof);
    }

    function include(bytes32 root, bytes32 key, bytes[] memory proof) external pure returns (bytes memory) {
        return TrieProof.traverse(root, abi.encodePacked(key), proof);
    }

    function slotValue(bytes32 root, bytes32 slot, bytes[] memory proof) external pure returns (uint256) {
        return FillProofLib.slotValue(root, slot, proof);
    }
}

contract MerklePatriciaExclusionTest is Test {
    TrieHarness internal h = new TrieHarness();

    function _trie(uint256 seed, uint256 n) internal pure returns (bytes32[] memory keys, bytes[] memory values) {
        keys = new bytes32[](n);
        values = new bytes[](n);
        for (uint256 i = 0; i < n; ++i) {
            keys[i] = keccak256(abi.encode(seed, i));
            values[i] = MerklePatriciaBuilder.storageLeaf(uint256(keccak256(abi.encode("v", seed, i))) >> (i * 8));
        }
    }

    function _included(bytes32 root, bytes32 key, bytes[] memory proof)
        internal
        view
        returns (bool ok, bytes memory v)
    {
        try h.include(root, key, proof) returns (bytes memory value) {
            return (true, value);
        } catch {
            return (false, "");
        }
    }

    function _absent(bytes32 root, bytes32 key, bytes[] memory proof) internal view returns (bool) {
        try h.isAbsent(root, key, proof) returns (bool absent) {
            return absent;
        } catch {
            return false;
        }
    }

    /// @dev For every key of a random trie: OpenZeppelin proves inclusion and exclusion is refused. For a random key
    ///      outside the trie: exclusion is proven and OpenZeppelin refuses inclusion.
    function testFuzz_differentialAgainstOpenZeppelin(uint256 seed, uint8 size, bytes32 outsider) public view {
        uint256 n = bound(size, 1, 24);
        (bytes32[] memory keys, bytes[] memory values) = _trie(seed, n);
        for (uint256 i = 0; i < n; ++i) {
            vm.assume(keys[i] != outsider);
        }

        for (uint256 i = 0; i < n; ++i) {
            (bytes32 root, bytes[] memory proof) = MerklePatriciaBuilder.prove(keys, values, keys[i]);
            (bool ok, bytes memory value) = _included(root, keys[i], proof);
            assertTrue(ok, "inclusion");
            assertEq(value, values[i]);
            assertFalse(_absent(root, keys[i], proof), "present key reported absent");
        }
        (bytes32 root2, bytes[] memory exclusion) = MerklePatriciaBuilder.prove(keys, values, outsider);
        assertTrue(_absent(root2, outsider, exclusion), "absent key not proven absent");
        (bool included,) = _included(root2, outsider, exclusion);
        assertFalse(included);
    }

    /// @dev An exclusion proof for one key never proves the absence of a key that is present.
    function testFuzz_exclusionProofCannotBeReusedForPresentKey(uint256 seed, uint8 size, bytes32 outsider, uint8 pick)
        public
        view
    {
        uint256 n = bound(size, 1, 24);
        (bytes32[] memory keys, bytes[] memory values) = _trie(seed, n);
        for (uint256 i = 0; i < n; ++i) {
            vm.assume(keys[i] != outsider);
        }
        (bytes32 root, bytes[] memory exclusion) = MerklePatriciaBuilder.prove(keys, values, outsider);
        bytes32 present = keys[bound(pick, 0, n - 1)];
        assertFalse(_absent(root, present, exclusion));
    }

    /// @dev Flipping any byte of any node, or dropping the last node, invalidates the exclusion proof.
    function testFuzz_tamperedExclusionProofRejected(uint256 seed, uint8 size, bytes32 outsider, uint256 where)
        public
        view
    {
        uint256 n = bound(size, 2, 24);
        (bytes32[] memory keys, bytes[] memory values) = _trie(seed, n);
        for (uint256 i = 0; i < n; ++i) {
            vm.assume(keys[i] != outsider);
        }
        (bytes32 root, bytes[] memory proof) = MerklePatriciaBuilder.prove(keys, values, outsider);

        uint256 node = bound(where, 0, proof.length - 1);
        uint256 offset = bound(where >> 128, 0, proof[node].length - 1);
        bytes[] memory tampered = _copy(proof);
        tampered[node][offset] = bytes1(uint8(tampered[node][offset]) ^ 0x01);
        assertFalse(_absent(root, outsider, tampered), "tampered node accepted");

        if (proof.length > 1) {
            bytes[] memory truncated = new bytes[](proof.length - 1);
            for (uint256 i = 0; i < truncated.length; ++i) {
                truncated[i] = proof[i];
            }
            assertFalse(_absent(root, outsider, truncated), "truncated proof accepted");
        }
        bytes[] memory extended = new bytes[](proof.length + 1);
        for (uint256 i = 0; i < proof.length; ++i) {
            extended[i] = proof[i];
        }
        extended[proof.length] = proof[proof.length - 1];
        assertFalse(_absent(root, outsider, extended), "proof with trailing node accepted");
    }

    /// @dev Keys sharing 63 nibbles produce leaves and branches shorter than 32 bytes, which are embedded in their
    ///      parent instead of referenced by hash: both verifiers must walk them in place.
    function test_embeddedNodes() public view {
        bytes32 base = keccak256("base");
        bytes32[] memory keys = new bytes32[](3);
        bytes[] memory values = new bytes[](3);
        for (uint256 i = 0; i < 3; ++i) {
            keys[i] = bytes32((uint256(base) & ~uint256(0xf)) | (i * 3));
            values[i] = MerklePatriciaBuilder.storageLeaf(i + 1);
        }
        for (uint256 i = 0; i < 3; ++i) {
            (bytes32 root, bytes[] memory proof) = MerklePatriciaBuilder.prove(keys, values, keys[i]);
            assertEq(proof.length, 1, "whole path embedded in the root");
            (bool ok, bytes memory value) = _included(root, keys[i], proof);
            assertTrue(ok);
            assertEq(value, values[i]);
            assertFalse(_absent(root, keys[i], proof));
        }
        bytes32 sibling = bytes32((uint256(base) & ~uint256(0xf)) | 1);
        (bytes32 root2, bytes[] memory exclusion) = MerklePatriciaBuilder.prove(keys, values, sibling);
        assertTrue(_absent(root2, sibling, exclusion), "empty slot inside an embedded branch");
    }

    function test_singleLeafTrie() public view {
        bytes32[] memory keys = new bytes32[](1);
        bytes[] memory values = new bytes[](1);
        keys[0] = keccak256("only");
        values[0] = MerklePatriciaBuilder.storageLeaf(5);
        (bytes32 root, bytes[] memory proof) = MerklePatriciaBuilder.prove(keys, values, keccak256("other"));
        assertEq(proof.length, 1);
        assertTrue(_absent(root, keccak256("other"), proof), "divergent leaf");
        assertFalse(_absent(root, keys[0], proof), "matching leaf");
    }

    function test_emptyTrieProvesEverythingAbsent() public view {
        assertTrue(h.isAbsent(MerklePatriciaExclusion.EMPTY_TRIE_ROOT, keccak256("x"), new bytes[](0)));
        assertEq(MerklePatriciaBuilder.root(new bytes32[](0), new bytes[](0)), MerklePatriciaExclusion.EMPTY_TRIE_ROOT);
    }

    function test_rejectsEmptyKeyAndEmptyProof() public view {
        (bytes32[] memory keys, bytes[] memory values) = _trie(1, 4);
        bytes32 root = MerklePatriciaBuilder.root(keys, values);
        assertFalse(h.isAbsentRawKey(root, "", new bytes[](0)));
        assertFalse(h.isAbsent(root, keccak256("x"), new bytes[](0)));
    }

    function test_rejectsProofForAnotherRoot() public view {
        (bytes32[] memory keys, bytes[] memory values) = _trie(1, 6);
        (, bytes[] memory proof) = MerklePatriciaBuilder.prove(keys, values, keccak256("absent"));
        assertFalse(h.isAbsent(keccak256("some other root"), keccak256("absent"), proof));
    }

    /// @dev FillProofLib.slotValue returns 0 for a proven-absent slot and the value for a proven-present one.
    function testFuzz_slotValue(uint256 seed, uint8 size) public view {
        uint256 n = bound(size, 1, 16);
        bytes32[] memory keys = new bytes32[](n);
        bytes[] memory values = new bytes[](n);
        for (uint256 i = 0; i < n; ++i) {
            bytes32 slot = keccak256(abi.encode(seed, i));
            keys[i] = keccak256(abi.encode(slot));
            values[i] = MerklePatriciaBuilder.storageLeaf(i + 1);
        }
        bytes32 presentSlot = keccak256(abi.encode(seed, n - 1));
        (bytes32 root, bytes[] memory proof) =
            MerklePatriciaBuilder.prove(keys, values, keccak256(abi.encode(presentSlot)));
        assertEq(h.slotValue(root, presentSlot, proof), n);

        bytes32 absentSlot = keccak256(abi.encode(seed, n));
        (root, proof) = MerklePatriciaBuilder.prove(keys, values, keccak256(abi.encode(absentSlot)));
        assertEq(h.slotValue(root, absentSlot, proof), 0);
    }

    function test_slotValue_revertsOnGarbage() public {
        (bytes32[] memory keys, bytes[] memory values) = _trie(3, 5);
        bytes32 root = MerklePatriciaBuilder.root(keys, values);
        bytes[] memory proof = new bytes[](1);
        proof[0] = hex"c0";
        vm.expectRevert(abi.encodeWithSelector(FillProofLib.InvalidSlotProof.selector, bytes32(uint256(1))));
        h.slotValue(root, bytes32(uint256(1)), proof);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Crafted nodes: malformed but hash-linked structures must never read as "absent"
    // ------------------------------------------------------------------------------------------------------------

    function _single(bytes memory node) internal pure returns (bytes32 root, bytes[] memory proof) {
        proof = new bytes[](1);
        proof[0] = node;
        root = keccak256(node);
    }

    function _list(bytes memory a, bytes memory b) internal pure returns (bytes memory) {
        bytes[] memory items = new bytes[](2);
        items[0] = a;
        items[1] = b;
        return RLP.encode(items);
    }

    function test_crafted_nodeWithWrongArity() public view {
        bytes[] memory items = new bytes[](3);
        items[0] = RLP.encode(bytes(hex"20"));
        items[1] = RLP.encode(bytes(hex"01"));
        items[2] = RLP.encode(bytes(hex"02"));
        (bytes32 root, bytes[] memory proof) = _single(RLP.encode(items));
        assertFalse(h.isAbsent(root, keccak256("k"), proof));
    }

    function test_crafted_unknownHexPrefixFlag() public view {
        (bytes32 root, bytes[] memory proof) = _single(_list(RLP.encode(bytes(hex"4a")), RLP.encode(bytes(hex"01"))));
        assertFalse(h.isAbsent(root, keccak256("k"), proof));
    }

    function test_crafted_emptyPath() public view {
        (bytes32 root, bytes[] memory proof) = _single(_list(RLP.encode(bytes("")), RLP.encode(bytes(hex"01"))));
        assertFalse(h.isAbsent(root, keccak256("k"), proof));
    }

    function test_crafted_extensionWithEmptyPathOrBadChild() public view {
        bytes32 key = keccak256("k");
        uint8 first = uint8(key[0]) >> 4;
        // Extension with an empty path (flag byte only).
        (bytes32 root, bytes[] memory proof) =
            _single(_list(RLP.encode(bytes(hex"00")), RLP.encode(keccak256("child"))));
        assertFalse(h.isAbsent(root, key, proof));
        // Extension matching the first nibble whose child is empty, or not a valid reference.
        bytes memory path = abi.encodePacked(bytes1(uint8(0x10 | first)));
        (root, proof) = _single(_list(RLP.encode(path), hex"80"));
        assertFalse(h.isAbsent(root, key, proof));
        (root, proof) = _single(_list(RLP.encode(path), RLP.encode(bytes(hex"0102030405"))));
        assertFalse(h.isAbsent(root, key, proof));
    }

    function test_crafted_branchWithInvalidChild() public view {
        bytes32 key = keccak256("k");
        bytes[] memory items = new bytes[](17);
        for (uint256 i = 0; i < 17; ++i) {
            items[i] = hex"80";
        }
        items[uint8(key[0]) >> 4] = RLP.encode(bytes(hex"0102030405")); // neither empty, a hash, nor an embedded node
        (bytes32 root, bytes[] memory proof) = _single(RLP.encode(items));
        assertFalse(h.isAbsent(root, key, proof));
    }

    /// @dev A key that ends exactly on a branch (impossible in secure tries, possible for raw keys): absence is
    ///      read from the branch's value slot.
    function test_crafted_keyEndingOnBranch() public view {
        bytes memory key = hex"ab";
        bytes[] memory items = new bytes[](17);
        for (uint256 i = 0; i < 17; ++i) {
            items[i] = hex"80";
        }
        bytes memory emptyBranch = RLP.encode(items);
        items[16] = RLP.encode(bytes(hex"05"));
        bytes memory valuedBranch = RLP.encode(items);
        // Extension consuming both nibbles of the key, pointing at the branch by hash.
        bytes memory ext = _list(RLP.encode(bytes(hex"00ab")), RLP.encode(keccak256(emptyBranch)));
        bytes[] memory proof = new bytes[](2);
        proof[0] = ext;
        proof[1] = emptyBranch;
        assertTrue(h.isAbsentRawKey(keccak256(ext), key, proof), "empty value slot");
        ext = _list(RLP.encode(bytes(hex"00ab")), RLP.encode(keccak256(valuedBranch)));
        proof[0] = ext;
        proof[1] = valuedBranch;
        assertFalse(h.isAbsentRawKey(keccak256(ext), key, proof), "value present");
    }

    function _copy(bytes[] memory proof) internal pure returns (bytes[] memory out) {
        out = new bytes[](proof.length);
        for (uint256 i = 0; i < proof.length; ++i) {
            out[i] = bytes.concat(proof[i]);
        }
    }
}
