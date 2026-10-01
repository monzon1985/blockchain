// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ICumulativeMerkleDistributor} from "../../src/interfaces/ICumulativeMerkleDistributor.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {DistributorBase} from "../utils/DistributorBase.sol";
import {MerkleBuilder} from "../utils/MerkleBuilder.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {Vm} from "forge-std/Vm.sol";

contract ClaimManyTest is DistributorBase {
    uint256 internal constant N = 12;
    Allocation[] internal book;

    function setUp() public override {
        super.setUp();
        for (uint256 i; i < N; ++i) {
            book.push(
                Allocation(address(uint160(0xA000 + i)), i % 2 == 0 ? address(tokenA) : address(tokenB), (i + 1) * 1e18)
            );
        }
    }

    function _book() internal view returns (Allocation[] memory allocs) {
        allocs = new Allocation[](book.length);
        for (uint256 i; i < book.length; ++i) {
            allocs[i] = book[i];
        }
    }

    /// @dev Builds the multiproof for `leafIndices` (positions in `allocs`) and the matching ordered claim list.
    function _batch(bytes32[] memory tree, Allocation[] memory allocs, uint256[] memory leafIndices)
        internal
        pure
        returns (ICumulativeMerkleDistributor.ClaimLeaf[] memory claims, MerkleBuilder.MultiProof memory mp)
    {
        uint256[] memory treeIndices = new uint256[](leafIndices.length);
        for (uint256 i; i < leafIndices.length; ++i) {
            treeIndices[i] = MerkleBuilder.treeIndexOf(allocs.length, leafIndices[i]);
        }
        mp = MerkleBuilder.multiProof(tree, treeIndices);
        claims = new ICumulativeMerkleDistributor.ClaimLeaf[](leafIndices.length);
        for (uint256 i; i < leafIndices.length; ++i) {
            // Tree index t holds the leaf that was at position 2n-2-t.
            Allocation memory a = allocs[2 * allocs.length - 2 - mp.treeIndices[i]];
            claims[i] = ICumulativeMerkleDistributor.ClaimLeaf(a.account, a.token, a.cumulativeAmount);
        }
    }

    function _indices(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory idx) {
        idx = new uint256[](3);
        (idx[0], idx[1], idx[2]) = (a, b, c);
    }

    // ------------------------------------------------------------------------------------------------ happy paths

    function test_claimMany_paysEveryLeafToItsAccount() public {
        Allocation[] memory allocs = _book();
        bytes32[] memory tree = _publish(allocs);
        (ICumulativeMerkleDistributor.ClaimLeaf[] memory claims, MerkleBuilder.MultiProof memory mp) =
            _batch(tree, allocs, _indices(0, 5, 11));

        vm.prank(stranger);
        uint256[] memory amounts = distributor.claimMany(claims, mp.proof, mp.proofFlags);

        assertEq(amounts.length, 3);
        for (uint256 i; i < claims.length; ++i) {
            assertEq(amounts[i], claims[i].cumulativeAmount);
            assertEq(MockERC20(claims[i].token).balanceOf(claims[i].account), claims[i].cumulativeAmount);
            assertEq(distributor.claimed(claims[i].account, claims[i].token), claims[i].cumulativeAmount);
        }
    }

    function test_claimMany_wholeTree() public {
        Allocation[] memory allocs = _book();
        bytes32[] memory tree = _publish(allocs);
        uint256[] memory all = new uint256[](N);
        for (uint256 i; i < N; ++i) {
            all[i] = i;
        }
        (ICumulativeMerkleDistributor.ClaimLeaf[] memory claims, MerkleBuilder.MultiProof memory mp) =
            _batch(tree, allocs, all);
        assertEq(mp.proof.length, 0, "the whole tree needs no sibling hashes");

        distributor.claimMany(claims, mp.proof, mp.proofFlags);
        assertEq(tokenA.balanceOf(address(distributor)), 0);
        assertEq(tokenB.balanceOf(address(distributor)), 0);
    }

    function test_claimMany_emitsClaimedPerLeaf() public {
        Allocation[] memory allocs = _book();
        bytes32[] memory tree = _publish(allocs);
        (ICumulativeMerkleDistributor.ClaimLeaf[] memory claims, MerkleBuilder.MultiProof memory mp) =
            _batch(tree, allocs, _indices(1, 2, 3));
        for (uint256 i; i < claims.length; ++i) {
            vm.expectEmit(true, true, true, true, address(distributor));
            emit ICumulativeMerkleDistributor.Claimed(
                claims[i].account,
                claims[i].token,
                claims[i].account,
                claims[i].cumulativeAmount,
                claims[i].cumulativeAmount
            );
        }
        distributor.claimMany(claims, mp.proof, mp.proofFlags);
    }

    function test_claimMany_skipsAlreadyClaimedLeaves() public {
        Allocation[] memory allocs = _book();
        bytes32[] memory tree = _publish(allocs);
        (ICumulativeMerkleDistributor.ClaimLeaf[] memory claims, MerkleBuilder.MultiProof memory mp) =
            _batch(tree, allocs, _indices(0, 5, 11));

        // A front-runner claims one leaf of the batch first; the batch still goes through.
        distributor.claim(allocs[5].account, allocs[5].token, allocs[5].cumulativeAmount, _proof(tree, N, 5));
        uint256[] memory amounts = distributor.claimMany(claims, mp.proof, mp.proofFlags);

        for (uint256 i; i < claims.length; ++i) {
            if (claims[i].account == allocs[5].account) assertEq(amounts[i], 0);
            else assertEq(amounts[i], claims[i].cumulativeAmount);
            assertEq(MockERC20(claims[i].token).balanceOf(claims[i].account), claims[i].cumulativeAmount);
        }
    }

    /// @notice Leaves with nothing left are skipped silently: a leaf already claimed in full and a leaf that a corrective
    ///         root lowered below what was paid produce no transfer, no `Claimed` event and no revert, and the rest of
    ///         the batch is paid.
    function test_claimMany_skipsClaimedAndLoweredLeavesWithoutSideEffects() public {
        Allocation[] memory allocs = _book();
        bytes32[] memory tree = _publish(allocs);
        distributor.claim(allocs[5].account, allocs[5].token, allocs[5].cumulativeAmount, _proof(tree, N, 5));
        distributor.claim(allocs[11].account, allocs[11].token, allocs[11].cumulativeAmount, _proof(tree, N, 11));
        uint256 paid5 = allocs[5].cumulativeAmount;

        // The next root lowers leaf 5 below what it was already paid (a correction); leaf 11 is unchanged.
        allocs[5].cumulativeAmount = paid5 - 1e18;
        tree = _publish(allocs);
        (ICumulativeMerkleDistributor.ClaimLeaf[] memory claims, MerkleBuilder.MultiProof memory mp) =
            _batch(tree, allocs, _indices(0, 5, 11));

        vm.recordLogs();
        uint256[] memory amounts = distributor.claimMany(claims, mp.proof, mp.proofFlags);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 claimedEvents;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(distributor)
                    && logs[i].topics[0] == ICumulativeMerkleDistributor.Claimed.selector
            ) {
                ++claimedEvents;
                assertEq(logs[i].topics[1], bytes32(uint256(uint160(allocs[0].account))), "only leaf 0 is paid");
            }
        }
        assertEq(claimedEvents, 1);
        assertEq(logs.length, 2, "one Claimed and one Transfer, nothing for the skipped leaves");
        for (uint256 i; i < claims.length; ++i) {
            if (claims[i].account == allocs[0].account) assertEq(amounts[i], allocs[0].cumulativeAmount);
            else assertEq(amounts[i], 0);
        }
        assertEq(distributor.claimed(allocs[5].account, allocs[5].token), paid5, "never lowered");
        assertEq(MockERC20(allocs[5].token).balanceOf(allocs[5].account), paid5);
    }

    function test_claimMany_topUpsAcrossRoots() public {
        Allocation[] memory allocs = _book();
        bytes32[] memory tree = _publish(allocs);
        (ICumulativeMerkleDistributor.ClaimLeaf[] memory claims, MerkleBuilder.MultiProof memory mp) =
            _batch(tree, allocs, _indices(2, 3, 4));
        distributor.claimMany(claims, mp.proof, mp.proofFlags);

        for (uint256 i; i < N; ++i) {
            allocs[i].cumulativeAmount += 7e18;
        }
        tree = _publish(allocs);
        (claims, mp) = _batch(tree, allocs, _indices(2, 3, 4));
        uint256[] memory amounts = distributor.claimMany(claims, mp.proof, mp.proofFlags);
        for (uint256 i; i < amounts.length; ++i) {
            assertEq(amounts[i], 7e18);
        }
    }

    // ------------------------------------------------------------------------------------------------ revert paths

    function test_claimMany_revertsOnEmptyBatch() public {
        bytes32[] memory tree = _publish(_book());
        // MerkleProof would accept "no leaves + proof = [root]"; the distributor refuses empty batches outright.
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = tree[0];
        assertTrue(MerkleProof.multiProofVerify(proof, new bool[](0), tree[0], new bytes32[](0)));
        vm.expectRevert(ICumulativeMerkleDistributor.EmptyClaimBatch.selector);
        distributor.claimMany(new ICumulativeMerkleDistributor.ClaimLeaf[](0), proof, new bool[](0));
    }

    function test_claimMany_revertsWithoutActiveRoot() public {
        ICumulativeMerkleDistributor.ClaimLeaf[] memory claims = new ICumulativeMerkleDistributor.ClaimLeaf[](1);
        claims[0] = ICumulativeMerkleDistributor.ClaimLeaf(alice, address(tokenA), 1);
        vm.expectRevert(ICumulativeMerkleDistributor.NoActiveRoot.selector);
        distributor.claimMany(claims, new bytes32[](0), new bool[](0));
    }

    function test_claimMany_revertsOnTamperedAmount() public {
        Allocation[] memory allocs = _book();
        bytes32[] memory tree = _publish(allocs);
        (ICumulativeMerkleDistributor.ClaimLeaf[] memory claims, MerkleBuilder.MultiProof memory mp) =
            _batch(tree, allocs, _indices(0, 5, 11));
        claims[1].cumulativeAmount += 1;
        vm.expectRevert(abi.encodeWithSelector(ICumulativeMerkleDistributor.InvalidMultiProof.selector, 3));
        distributor.claimMany(claims, mp.proof, mp.proofFlags);
    }

    function test_claimMany_revertsOnReorderedLeaves() public {
        Allocation[] memory allocs = _book();
        bytes32[] memory tree = _publish(allocs);
        (ICumulativeMerkleDistributor.ClaimLeaf[] memory claims, MerkleBuilder.MultiProof memory mp) =
            _batch(tree, allocs, _indices(0, 5, 11));
        (claims[0], claims[2]) = (claims[2], claims[0]);
        vm.expectRevert(abi.encodeWithSelector(ICumulativeMerkleDistributor.InvalidMultiProof.selector, 3));
        distributor.claimMany(claims, mp.proof, mp.proofFlags);
    }

    function test_claimMany_revertsOnMalformedMultiproof() public {
        Allocation[] memory allocs = _book();
        bytes32[] memory tree = _publish(allocs);
        (ICumulativeMerkleDistributor.ClaimLeaf[] memory claims, MerkleBuilder.MultiProof memory mp) =
            _batch(tree, allocs, _indices(0, 5, 11));
        bool[] memory shortFlags = new bool[](mp.proofFlags.length - 1);
        for (uint256 i; i < shortFlags.length; ++i) {
            shortFlags[i] = mp.proofFlags[i];
        }
        vm.expectRevert(MerkleProof.MerkleProofInvalidMultiproof.selector);
        distributor.claimMany(claims, mp.proof, shortFlags);
    }

    function test_claimMany_revertsWhenALeafIsForeign() public {
        Allocation[] memory allocs = _book();
        bytes32[] memory tree = _publish(allocs);
        (ICumulativeMerkleDistributor.ClaimLeaf[] memory claims, MerkleBuilder.MultiProof memory mp) =
            _batch(tree, allocs, _indices(0, 5, 11));
        claims[2].account = stranger;
        vm.expectRevert(abi.encodeWithSelector(ICumulativeMerkleDistributor.InvalidMultiProof.selector, 3));
        distributor.claimMany(claims, mp.proof, mp.proofFlags);
        assertEq(tokenA.balanceOf(stranger) + tokenB.balanceOf(stranger), 0);
    }

    // ------------------------------------------------------------------------------------------------ fuzz

    /// @notice Any non-empty subset of any tree claims exactly the subset's allocations, and every leaf of the subset
    ///         can no longer be claimed individually afterwards.
    function testFuzz_claimMany_anySubset(uint256 seed, uint16 rawCount, uint256 mask) public {
        uint256 count = bound(rawCount, 1, 64);
        Allocation[] memory allocs = new Allocation[](count);
        for (uint256 i; i < count; ++i) {
            allocs[i] = Allocation(
                address(uint160(uint256(keccak256(abi.encode(seed, i))) | 1)),
                i % 2 == 0 ? address(tokenA) : address(tokenB),
                bound(uint256(keccak256(abi.encode(i, seed))), 1, 1e36)
            );
        }
        bytes32[] memory tree = _publish(allocs);

        uint256 picked;
        uint256[] memory subset = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            if ((mask >> i) & 1 == 1) subset[picked++] = i;
        }
        if (picked == 0) subset[picked++] = mask % count;
        assembly ("memory-safe") {
            // Shrink `subset` to the picked entries. Memory-safe: lowers the length of an array allocated above.
            mstore(subset, picked)
        }

        (ICumulativeMerkleDistributor.ClaimLeaf[] memory claims, MerkleBuilder.MultiProof memory mp) =
            _batch(tree, allocs, subset);
        uint256[] memory amounts = distributor.claimMany(claims, mp.proof, mp.proofFlags);
        for (uint256 i; i < claims.length; ++i) {
            assertEq(amounts[i], claims[i].cumulativeAmount);
            assertEq(distributor.claimed(claims[i].account, claims[i].token), claims[i].cumulativeAmount);
        }
        uint256 j = subset[0];
        vm.expectRevert(
            abi.encodeWithSelector(
                ICumulativeMerkleDistributor.NothingToClaim.selector,
                allocs[j].account,
                allocs[j].token,
                allocs[j].cumulativeAmount,
                allocs[j].cumulativeAmount
            )
        );
        distributor.claim(allocs[j].account, allocs[j].token, allocs[j].cumulativeAmount, _proof(tree, count, j));
    }
}
