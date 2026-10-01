// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {Hashes} from "@openzeppelin-contracts/utils/cryptography/Hashes.sol";

/// @dev Both ways of committing an epoch's tape, run on calldata exactly as `BatchInbox` receives it.
contract TapeCommitments {
    /// @dev What `BatchInbox` does: one keccak256 over the whole tape.
    function flat(bytes calldata tape) external pure returns (bytes32) {
        return keccak256(tape);
    }

    /// @dev The alternative: a binary Merkle root over the tape's 32-byte words (the words are the leaves, padded
    ///      with zero leaves to a power of two), which would let an INPUT proof carry `log2(words)` siblings instead of
    ///      the whole tape. Written in assembly, hashing each level in place, so the baseline is a tight lower bound
    ///      rather than a strawman.
    function merkle(bytes calldata tape) external pure returns (bytes32 root) {
        // Copies the tape to fresh memory past the free pointer (never written before in this call, so the padding
        // leaves are zero) and folds it in place: pair i of a level is read before slot i is overwritten, since i <= 2i.
        assembly ("memory-safe") {
            let words := shr(5, tape.length)
            let width := 1
            for {} lt(width, words) {} { width := shl(1, width) }
            let buf := mload(0x40)
            calldatacopy(buf, tape.offset, tape.length)
            for {} gt(width, 1) { width := shr(1, width) } {
                let half := shr(1, width)
                for { let i := 0 } lt(i, half) { i := add(i, 1) } {
                    mstore(add(buf, shl(5, i)), keccak256(add(buf, shl(6, i)), 64))
                }
            }
            root := mload(buf)
        }
    }

    /// @dev What the flat design's INPUT verification recomputes: the hash of the whole tape shipped in the witness.
    function verifyFlat(bytes calldata tape, bytes32 root) external pure returns (bool) {
        return keccak256(tape) == root;
    }

    /// @dev What a Merkle-tape INPUT verification would compute: one hash per level.
    function verifyMerkle(bytes32 word, uint256 index, bytes32[] calldata siblings, bytes32 root)
        external
        pure
        returns (bool)
    {
        bytes32 node = word;
        for (uint256 i = 0; i < siblings.length; ++i) {
            node = (index >> i) & 1 == 0
                ? Hashes.efficientKeccak256(node, siblings[i])
                : Hashes.efficientKeccak256(siblings[i], node);
        }
        return node == root;
    }
}

/// @notice Gas baseline for the "flat keccak tape commitment" design decision (README, Gas): the commitment is paid on
///         every batch, the INPUT proof only in disputes. Measured on the largest tape the inbox accepts
///         (1 + 96 * 8 = 769 words, 24,608 bytes). Run with `-vv` to print the figures quoted in the README.
contract TapeCommitmentBaselineTest is Test {
    uint256 internal constant WORDS = 1 + 96 * 8;

    TapeCommitments internal c;

    function setUp() public {
        c = new TapeCommitments();
        c.flat(""); // warm the account, so neither measurement pays the cold-access surcharge
    }

    /// @dev A maximum-size tape of pseudo-random words, built in memory.
    function _tape() internal pure returns (bytes memory) {
        bytes32[] memory words = new bytes32[](WORDS);
        for (uint256 i = 0; i < WORDS; ++i) {
            words[i] = keccak256(abi.encode(i));
        }
        return abi.encodePacked(words);
    }

    function test_baseline_commitmentOnTheHotPath() public view {
        bytes memory tape = _tape();
        assertEq(tape.length, 24_608);
        uint256 g = gasleft();
        c.flat(tape);
        uint256 flatGas = g - gasleft();
        g = gasleft();
        c.merkle(tape);
        uint256 merkleGas = g - gasleft();
        console2.log("tape commitment per batch, flat keccak256 (gas):", flatGas);
        console2.log("tape commitment per batch, Merkle root      (gas):", merkleGas);
        assertGt(merkleGas, 2 * flatGas, "the Merkle commitment costs a multiple of the flat hash on every batch");
    }

    /// @dev The baseline computes a real Merkle root (checked on small tapes), so its cost is the real one.
    function test_baseline_merkleRootIsCorrect() public view {
        (bytes32 a, bytes32 b, bytes32 d) = (keccak256("a"), keccak256("b"), keccak256("d"));
        assertEq(c.merkle(abi.encodePacked(a)), a);
        assertEq(c.merkle(abi.encodePacked(a, b)), keccak256(abi.encodePacked(a, b)));
        bytes32 right = keccak256(abi.encodePacked(d, bytes32(0)));
        assertEq(
            c.merkle(abi.encodePacked(a, b, d)), keccak256(abi.encodePacked(keccak256(abi.encodePacked(a, b)), right))
        );
    }

    function test_baseline_verificationInADispute() public view {
        bytes memory tape = _tape();
        bytes32 flatRoot = keccak256(tape);
        uint256 g = gasleft();
        assertTrue(c.verifyFlat(tape, flatRoot));
        uint256 flatGas = g - gasleft();

        // A 10-level proof for word 0 of a 1,024-leaf tree (siblings are arbitrary: only the cost is measured, so the
        // root is recomputed with the same siblings).
        bytes32[] memory siblings = new bytes32[](10);
        bytes32 node = bytes32(tape.length);
        for (uint256 i = 0; i < siblings.length; ++i) {
            siblings[i] = keccak256(abi.encode("sibling", i));
            node = Hashes.efficientKeccak256(node, siblings[i]);
        }
        g = gasleft();
        assertTrue(c.verifyMerkle(bytes32(tape.length), 0, siblings, node));
        uint256 merkleGas = g - gasleft();
        console2.log("INPUT witness check, flat tape (24,608 B of calldata)  (gas):", flatGas);
        console2.log("INPUT witness check, Merkle tape (320 B of calldata)   (gas):", merkleGas);
        assertGt(flatGas, merkleGas);
    }
}
