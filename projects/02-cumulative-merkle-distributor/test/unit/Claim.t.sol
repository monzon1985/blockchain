// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ICumulativeMerkleDistributor} from "../../src/interfaces/ICumulativeMerkleDistributor.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {ReentrantToken} from "../mocks/ReentrantToken.sol";
import {DistributorBase} from "../utils/DistributorBase.sol";
import {MerkleBuilder} from "../utils/MerkleBuilder.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/// @notice A deliberately naive distributor whose leaf is `keccak256(abi.encodePacked(a, b))` over two 32-byte words:
///         the textbook second-preimage bug that the double-hashed, 96-byte leaf of the real contract rules out.
contract NaiveSingleHashVerifier {
    bytes32 public immutable root;

    constructor(bytes32 root_) {
        root = root_;
    }

    function verify(bytes32 a, bytes32 b, bytes32[] calldata proof) external view returns (bool) {
        return MerkleProof.verifyCalldata(proof, root, keccak256(abi.encodePacked(a, b)));
    }
}

contract ClaimTest is DistributorBase {
    // ------------------------------------------------------------------------------------------------ happy paths

    function test_claim_paysAccountAndRecords() public {
        Allocation[] memory allocs = _allocs(100e18, 50e18, 20e18);
        bytes32[] memory tree = _publish(allocs);

        vm.expectEmit(true, true, true, true, address(distributor));
        emit ICumulativeMerkleDistributor.Claimed(alice, address(tokenA), alice, 100e18, 100e18);
        vm.prank(alice);
        uint256 paid = distributor.claim(alice, address(tokenA), 100e18, _proof(tree, 4, 0));

        assertEq(paid, 100e18);
        assertEq(tokenA.balanceOf(alice), 100e18);
        assertEq(distributor.claimed(alice, address(tokenA)), 100e18);
        assertEq(distributor.claimed(alice, address(tokenB)), 0, "other token untouched");
    }

    function test_claim_isPermissionlessButAlwaysPaysAccount() public {
        Allocation[] memory allocs = _allocs(100e18, 50e18, 20e18);
        bytes32[] memory tree = _publish(allocs);

        vm.prank(stranger);
        distributor.claim(bob, address(tokenA), 50e18, _proof(tree, 4, 1));
        assertEq(tokenA.balanceOf(bob), 50e18);
        assertEq(tokenA.balanceOf(stranger), 0);
    }

    function test_claim_multiTokenLeavesAreIndependent() public {
        Allocation[] memory allocs = _allocs(100e18, 50e18, 20e18);
        bytes32[] memory tree = _publish(allocs);

        distributor.claim(alice, address(tokenA), 100e18, _proof(tree, 4, 0));
        distributor.claim(alice, address(tokenB), 10e18 + 1, _proof(tree, 4, 3));
        assertEq(tokenA.balanceOf(alice), 100e18);
        assertEq(tokenB.balanceOf(alice), 10e18 + 1);
    }

    function test_claim_topUpAfterNewRootPaysOnlyTheDelta() public {
        bytes32[] memory tree1 = _publish(_allocs(100e18, 50e18, 20e18));
        distributor.claim(alice, address(tokenA), 100e18, _proof(tree1, 4, 0));

        bytes32[] memory tree2 = _publish(_allocs(160e18, 70e18, 30e18));
        vm.expectEmit(true, true, true, true, address(distributor));
        emit ICumulativeMerkleDistributor.Claimed(alice, address(tokenA), alice, 60e18, 160e18);
        uint256 paid = distributor.claim(alice, address(tokenA), 160e18, _proof(tree2, 4, 0));

        assertEq(paid, 60e18);
        assertEq(tokenA.balanceOf(alice), 160e18);
        assertEq(distributor.claimed(alice, address(tokenA)), 160e18);
    }

    function test_claim_skippedEpochsAreClaimedAtOnce() public {
        _publish(_allocs(100e18, 50e18, 20e18));
        _publish(_allocs(160e18, 70e18, 30e18));
        bytes32[] memory tree3 = _publish(_allocs(250e18, 90e18, 40e18));

        uint256 paid = distributor.claim(bob, address(tokenA), 90e18, _proof(tree3, 4, 1));
        assertEq(paid, 90e18, "three epochs, one proof");
        assertEq(distributor.epoch(), 3);
    }

    function test_claim_leafHashMatchesStandardMerkleTreeEncoding() public view {
        bytes32 expected = keccak256(bytes.concat(keccak256(abi.encode(alice, address(tokenA), uint256(7)))));
        assertEq(distributor.leafHash(alice, address(tokenA), 7), expected);
        assertEq(MerkleBuilder.leaf(alice, address(tokenA), 7), expected);
    }

    function test_claim_singleLeafTree() public {
        Allocation[] memory allocs = new Allocation[](1);
        allocs[0] = Allocation(carol, address(tokenB), 5e18);
        _publish(allocs);
        distributor.claim(carol, address(tokenB), 5e18, new bytes32[](0));
        assertEq(tokenB.balanceOf(carol), 5e18);
    }

    // ------------------------------------------------------------------------------------------------ revert paths

    function test_claim_revertsWithoutActiveRoot() public {
        vm.expectRevert(ICumulativeMerkleDistributor.NoActiveRoot.selector);
        distributor.claim(alice, address(tokenA), 1, new bytes32[](0));
    }

    function test_claim_revertsWhenPendingRootNotYetAccepted() public {
        bytes32[] memory tree = _tree(_allocs(100e18, 50e18, 20e18));
        _propose(tree[0]);
        vm.expectRevert(ICumulativeMerkleDistributor.NoActiveRoot.selector);
        distributor.claim(alice, address(tokenA), 100e18, _proof(tree, 4, 0));
    }

    function test_claim_revertsOnInflatedAmount() public {
        bytes32[] memory tree = _publish(_allocs(100e18, 50e18, 20e18));
        bytes32[] memory proof = _proof(tree, 4, 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                ICumulativeMerkleDistributor.InvalidProof.selector, alice, address(tokenA), 100e18 + 1
            )
        );
        distributor.claim(alice, address(tokenA), 100e18 + 1, proof);
    }

    function test_claim_revertsOnWrongAccountOrToken() public {
        bytes32[] memory tree = _publish(_allocs(100e18, 50e18, 20e18));
        bytes32[] memory proof = _proof(tree, 4, 0);

        vm.expectRevert(
            abi.encodeWithSelector(ICumulativeMerkleDistributor.InvalidProof.selector, bob, address(tokenA), 100e18)
        );
        distributor.claim(bob, address(tokenA), 100e18, proof);

        vm.expectRevert(
            abi.encodeWithSelector(ICumulativeMerkleDistributor.InvalidProof.selector, alice, address(tokenB), 100e18)
        );
        distributor.claim(alice, address(tokenB), 100e18, proof);
    }

    function test_claim_revertsOnTamperedProof() public {
        bytes32[] memory tree = _publish(_allocs(100e18, 50e18, 20e18));
        bytes32[] memory proof = _proof(tree, 4, 0);
        proof[proof.length - 1] ^= bytes32(uint256(1));
        vm.expectRevert(
            abi.encodeWithSelector(ICumulativeMerkleDistributor.InvalidProof.selector, alice, address(tokenA), 100e18)
        );
        distributor.claim(alice, address(tokenA), 100e18, proof);
    }

    function test_claim_revertsWhenNothingLeft() public {
        bytes32[] memory tree = _publish(_allocs(100e18, 50e18, 20e18));
        bytes32[] memory proof = _proof(tree, 4, 0);
        distributor.claim(alice, address(tokenA), 100e18, proof);

        vm.expectRevert(
            abi.encodeWithSelector(
                ICumulativeMerkleDistributor.NothingToClaim.selector, alice, address(tokenA), 100e18, 100e18
            )
        );
        distributor.claim(alice, address(tokenA), 100e18, proof);
    }

    function test_claim_revertsForZeroAllocationLeaf() public {
        Allocation[] memory allocs = new Allocation[](2);
        allocs[0] = Allocation(alice, address(tokenA), 0);
        allocs[1] = Allocation(bob, address(tokenA), 1);
        bytes32[] memory tree = _publish(allocs);
        vm.expectRevert(
            abi.encodeWithSelector(ICumulativeMerkleDistributor.NothingToClaim.selector, alice, address(tokenA), 0, 0)
        );
        distributor.claim(alice, address(tokenA), 0, _proof(tree, 2, 0));
    }

    function test_claim_oldRootProofsDieOnRotation() public {
        bytes32[] memory tree1 = _publish(_allocs(100e18, 50e18, 20e18));
        _publish(_allocs(160e18, 70e18, 30e18));

        // The epoch-1 leaf and proof are no longer part of the active root.
        vm.expectRevert(
            abi.encodeWithSelector(ICumulativeMerkleDistributor.InvalidProof.selector, alice, address(tokenA), 100e18)
        );
        distributor.claim(alice, address(tokenA), 100e18, _proof(tree1, 4, 0));
    }

    function test_claim_clawbackRootCannotReduceClaimed() public {
        bytes32[] memory tree1 = _publish(_allocs(100e18, 50e18, 20e18));
        distributor.claim(alice, address(tokenA), 100e18, _proof(tree1, 4, 0));

        // A (buggy or corrective) root that lowers alice's allocation cannot claw back what was paid, and the recorded
        // cumulative amount never decreases.
        bytes32[] memory tree2 = _publish(_allocs(40e18, 50e18, 20e18));
        vm.expectRevert(
            abi.encodeWithSelector(
                ICumulativeMerkleDistributor.NothingToClaim.selector, alice, address(tokenA), 40e18, 100e18
            )
        );
        distributor.claim(alice, address(tokenA), 40e18, _proof(tree2, 4, 0));
        assertEq(distributor.claimed(alice, address(tokenA)), 100e18);
    }

    function test_claim_revertsWhenUnderfunded() public {
        Allocation[] memory allocs = _allocs(100e18, 50e18, 20e18);
        bytes32[] memory tree = _tree(allocs);
        _proposeAndAccept(tree[0]);
        tokenA.mint(address(distributor), 99e18);

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(distributor), 99e18, 100e18)
        );
        distributor.claim(alice, address(tokenA), 100e18, _proof(tree, 4, 0));
        assertEq(distributor.claimed(alice, address(tokenA)), 0, "state rolled back");
    }

    // ------------------------------------------------------------------------------------------------ second preimage

    /// @notice Pins the encoding the second-preimage argument rests on, for any input: the leaf is the double keccak256
    ///         of the 96-byte ABI encoding of (account, token, cumulativeAmount). Inner nodes hash exactly 64 bytes, so
    ///         no leaf preimage can be an inner node's, and the double hash keeps the StandardMerkleTree format. Fails
    ///         under mutant M01 (single-hashed leaf), as does `test_claim_leafHashMatchesStandardMerkleTreeEncoding`.
    function testFuzz_leafHash_isDoubleHashOf96ByteEncoding(address account, address token, uint256 amount)
        public
        view
    {
        bytes memory preimage = abi.encode(account, token, amount);
        assertEq(preimage.length, 96, "three words, never the 64 bytes of an inner node");
        assertEq(distributor.leafHash(account, token, amount), keccak256(bytes.concat(keccak256(preimage))));
        assertEq(distributor.leafHash(account, token, amount), MerkleBuilder.leaf(account, token, amount));
    }

    /// @notice Illustration of the attack class, not evidence for the encoding. An inner node verifies against the root
    ///         as if it were a leaf: a naive verifier whose leaf is the single hash of two 32-byte words accepts it. The
    ///         distributor only takes `(address, address, uint256)`, a 96-byte preimage, so it rejects every attempt
    ///         below; it would also reject them with a single-hashed 96-byte leaf (mutant M01), which is why the
    ///         encoding is pinned by `testFuzz_leafHash_isDoubleHashOf96ByteEncoding` instead.
    function test_secondPreimage_innerNodeCannotBeClaimedAsLeaf() public {
        Allocation[] memory allocs = new Allocation[](8);
        for (uint256 i; i < 8; ++i) {
            allocs[i] = Allocation(address(uint160(0x1000 + i)), address(tokenA), (i + 1) * 1e18);
        }
        bytes32[] memory tree = _publish(allocs);

        // Node 1 is the left child of the root; its preimage is its two children, sorted.
        (bytes32 lo, bytes32 hi) = tree[3] < tree[4] ? (tree[3], tree[4]) : (tree[4], tree[3]);
        assertEq(keccak256(abi.encodePacked(lo, hi)), tree[1]);
        bytes32[] memory innerProof = new bytes32[](1);
        innerProof[0] = tree[2];
        assertTrue(MerkleProof.verify(innerProof, tree[0], tree[1]), "inner node + sibling reach the root");

        NaiveSingleHashVerifier naive = new NaiveSingleHashVerifier(tree[0]);
        assertTrue(naive.verify(lo, hi, innerProof), "naive leaf encoding accepts the forged leaf");

        // The closest the distributor's ABI allows: the preimage words truncated to addresses. Rejected.
        address[2] memory asAddress = [address(uint160(uint256(lo))), address(uint160(uint256(hi)))];
        for (uint256 i; i < 2; ++i) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    ICumulativeMerkleDistributor.InvalidProof.selector, asAddress[i], address(tokenA), uint256(hi)
                )
            );
            distributor.claim(asAddress[i], address(tokenA), uint256(hi), innerProof);
        }
        assertTrue(distributor.leafHash(asAddress[0], asAddress[1], uint256(hi)) != tree[1]);
        assertEq(tokenA.balanceOf(address(distributor)), _total(allocs, address(tokenA)), "nothing left the vault");
    }

    // ------------------------------------------------------------------------------------------------ reentrancy

    function test_claim_reentrantTokenIsBlocked() public {
        ReentrantToken evil = new ReentrantToken();
        Allocation[] memory allocs = new Allocation[](2);
        allocs[0] = Allocation(alice, address(evil), 10e18);
        allocs[1] = Allocation(bob, address(evil), 10e18);
        bytes32[] memory tree = _tree(allocs);
        _proposeAndAccept(tree[0]);
        evil.mint(address(distributor), 20e18);

        // During alice's payout the token tries to claim bob's leaf through the distributor.
        evil.arm(
            address(distributor), abi.encodeCall(distributor.claim, (bob, address(evil), 10e18, _proof(tree, 2, 1)))
        );
        distributor.claim(alice, address(evil), 10e18, _proof(tree, 2, 0));

        assertFalse(evil.reentered(), "re-entry must fail");
        assertEq(
            evil.reentryError(), abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector)
        );
        assertEq(evil.balanceOf(alice), 10e18);
        assertEq(evil.balanceOf(bob), 0);
        assertEq(distributor.claimed(bob, address(evil)), 0);
    }

    // ------------------------------------------------------------------------------------------------ fuzz

    function testFuzz_claim_cumulativeTopUps(uint256[4] memory increments) public {
        uint256 cumulative;
        uint256 paidTotal;
        for (uint256 epoch_; epoch_ < increments.length; ++epoch_) {
            cumulative += bound(increments[epoch_], 0, 1e30);
            Allocation[] memory allocs = new Allocation[](2);
            allocs[0] = Allocation(alice, address(tokenA), cumulative);
            allocs[1] = Allocation(bob, address(tokenA), epoch_ + 1);
            bytes32[] memory tree = _publish(allocs);

            uint256 before = distributor.claimed(alice, address(tokenA));
            if (cumulative > before) {
                paidTotal += distributor.claim(alice, address(tokenA), cumulative, _proof(tree, 2, 0));
            } else {
                vm.expectRevert(
                    abi.encodeWithSelector(
                        ICumulativeMerkleDistributor.NothingToClaim.selector, alice, address(tokenA), cumulative, before
                    )
                );
                distributor.claim(alice, address(tokenA), cumulative, _proof(tree, 2, 0));
            }
            assertEq(distributor.claimed(alice, address(tokenA)), cumulative);
        }
        assertEq(paidTotal, cumulative);
        assertEq(tokenA.balanceOf(alice), cumulative);
    }

    function testFuzz_claim_anyLeafOfAnyTree(uint256 seed, uint16 rawCount, uint16 rawIndex) public {
        uint256 count = bound(rawCount, 1, 300);
        uint256 index = bound(rawIndex, 0, count - 1);
        Allocation[] memory allocs = new Allocation[](count);
        for (uint256 i; i < count; ++i) {
            allocs[i] = Allocation(
                address(uint160(uint256(keccak256(abi.encode(seed, i))) | 1)),
                i % 3 == 0 ? address(tokenB) : address(tokenA),
                bound(uint256(keccak256(abi.encode(i, seed))), 1, 1e36)
            );
        }
        bytes32[] memory tree = _publish(allocs);
        Allocation memory a = allocs[index];
        uint256 paid = distributor.claim(a.account, a.token, a.cumulativeAmount, _proof(tree, count, index));
        assertEq(paid, a.cumulativeAmount);
        assertEq(MockERC20(a.token).balanceOf(a.account), a.cumulativeAmount);
    }

    function testFuzz_claim_wrongAmountNeverVerifies(uint256 claimedAmount) public {
        Allocation[] memory allocs = _allocs(100e18, 50e18, 20e18);
        bytes32[] memory tree = _publish(allocs);
        vm.assume(claimedAmount != 100e18);
        vm.expectRevert(
            abi.encodeWithSelector(
                ICumulativeMerkleDistributor.InvalidProof.selector, alice, address(tokenA), claimedAmount
            )
        );
        distributor.claim(alice, address(tokenA), claimedAmount, _proof(tree, 4, 0));
    }
}
