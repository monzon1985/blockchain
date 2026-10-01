// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ICumulativeMerkleDistributor} from "../../src/interfaces/ICumulativeMerkleDistributor.sol";
import {ReentrantToken} from "../mocks/ReentrantToken.sol";
import {DistributorBase} from "../utils/DistributorBase.sol";
import {MerkleBuilder} from "../utils/MerkleBuilder.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/// @notice Every claim entry point holds the reentrancy guard for the whole payout. A hostile token calls back into
///         `claim`, `claimFor` or `claimMany` from inside the transfer made by each of the three (nine combinations),
///         and every re-entry fails with `ReentrancyGuardReentrantCall`. Each case then sends the very same call from
///         outside a payout, where it succeeds: the guard, and nothing else, is what stopped it.
contract ReentrancyTest is DistributorBase {
    enum EntryPoint {
        Claim,
        ClaimFor,
        ClaimMany
    }

    uint256 internal constant AMOUNT = 10e18;
    address internal treasury = makeAddr("treasury");

    function test_reentrancy_duringClaimPayout() public {
        _reenterFromEveryEntryPoint(EntryPoint.Claim);
    }

    function test_reentrancy_duringClaimForPayout() public {
        _reenterFromEveryEntryPoint(EntryPoint.ClaimFor);
    }

    function test_reentrancy_duringClaimManyPayout() public {
        _reenterFromEveryEntryPoint(EntryPoint.ClaimMany);
    }

    function _reenterFromEveryEntryPoint(EntryPoint outer) internal {
        for (uint256 i; i < 3; ++i) {
            _reenter(outer, EntryPoint(i));
        }
    }

    /// @dev A fresh hostile token and root per case: alice and bob are each owed AMOUNT. During the payout of alice's
    ///      leaf through `outer`, the token tries to pay bob's leaf through `inner`.
    function _reenter(EntryPoint outer, EntryPoint inner) internal {
        ReentrantToken evil = new ReentrantToken();
        Allocation[] memory allocs = new Allocation[](2);
        allocs[0] = Allocation(alice, address(evil), AMOUNT);
        allocs[1] = Allocation(bob, address(evil), AMOUNT);
        bytes32[] memory tree = _tree(allocs);
        _proposeAndAccept(tree[0]);
        evil.mint(address(distributor), 2 * AMOUNT);

        bytes memory reentry = _calldata(inner, tree, allocs, 1, bobKey);
        bytes memory outerCall = _calldata(outer, tree, allocs, 0, aliceKey);
        evil.arm(address(distributor), reentry);
        vm.prank(relayer);
        (bool ok,) = address(distributor).call(outerCall);
        assertTrue(ok, "the outer claim itself succeeds");

        assertFalse(evil.reentered(), "the re-entrant claim must fail");
        assertEq(
            evil.reentryError(),
            abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector),
            "rejected by the guard, not by anything else"
        );
        assertEq(evil.balanceOf(outer == EntryPoint.ClaimFor ? treasury : alice), AMOUNT, "alice's leaf was paid");
        assertEq(distributor.claimed(bob, address(evil)), 0, "bob's leaf was not");
        assertEq(evil.balanceOf(address(distributor)), AMOUNT);

        // Control: the token is disarmed now, and the same calldata goes through from outside a payout.
        (ok,) = address(distributor).call(reentry);
        assertTrue(ok, "the re-entrant call is a valid claim on its own");
        assertEq(distributor.claimed(bob, address(evil)), AMOUNT);
        assertEq(evil.balanceOf(address(distributor)), 0);
    }

    /// @dev Calldata that claims leaf `index` of the two-leaf `tree` through `entry`. `claimFor` pays the treasury
    ///      with a fresh authorization signed by `key`.
    function _calldata(EntryPoint entry, bytes32[] memory tree, Allocation[] memory allocs, uint256 index, uint256 key)
        internal
        view
        returns (bytes memory)
    {
        Allocation memory a = allocs[index];
        if (entry == EntryPoint.Claim) {
            return abi.encodeCall(distributor.claim, (a.account, a.token, a.cumulativeAmount, _proof(tree, 2, index)));
        }
        if (entry == EntryPoint.ClaimFor) {
            uint256 deadline = block.timestamp + 1 hours;
            bytes memory sig = _authorization(key, a.account, a.token, a.cumulativeAmount, treasury, deadline);
            return abi.encodeCall(
                distributor.claimFor,
                (a.account, a.token, a.cumulativeAmount, _proof(tree, 2, index), treasury, deadline, sig)
            );
        }
        uint256[] memory treeIndices = new uint256[](1);
        treeIndices[0] = MerkleBuilder.treeIndexOf(2, index);
        MerkleBuilder.MultiProof memory mp = MerkleBuilder.multiProof(tree, treeIndices);
        ICumulativeMerkleDistributor.ClaimLeaf[] memory claims = new ICumulativeMerkleDistributor.ClaimLeaf[](1);
        claims[0] = ICumulativeMerkleDistributor.ClaimLeaf(a.account, a.token, a.cumulativeAmount);
        return abi.encodeCall(distributor.claimMany, (claims, mp.proof, mp.proofFlags));
    }
}
