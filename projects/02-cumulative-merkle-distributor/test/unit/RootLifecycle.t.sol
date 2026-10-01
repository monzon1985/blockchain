// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {CumulativeMerkleDistributor} from "../../src/CumulativeMerkleDistributor.sol";
import {ICumulativeMerkleDistributor} from "../../src/interfaces/ICumulativeMerkleDistributor.sol";
import {DistributorBase} from "../utils/DistributorBase.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract RootLifecycleTest is DistributorBase {
    bytes32 internal constant ROOT_1 = keccak256("root 1");
    bytes32 internal constant ROOT_2 = keccak256("root 2");
    bytes32 internal constant META_1 = keccak256("meta 1");
    bytes32 internal constant META_2 = keccak256("meta 2");

    // ------------------------------------------------------------------------------------------------ deployment

    function test_constructor_setsRolesAndEmptyState() public view {
        assertEq(distributor.owner(), owner);
        assertEq(distributor.updater(), updater);
        assertEq(distributor.guardian(), guardian);
        assertEq(distributor.root(), bytes32(0));
        assertEq(distributor.metadataHash(), bytes32(0));
        assertEq(distributor.epoch(), 0);
        (bytes32 pending, bytes32 meta, uint64 validAt) = distributor.pendingRoot();
        assertEq(pending, bytes32(0));
        assertEq(meta, bytes32(0));
        assertEq(validAt, 0);
        assertEq(distributor.ROOT_TIMELOCK(), 24 hours);
    }

    function test_constructor_emitsRoleEvents() public {
        vm.expectEmit(true, true, true, true);
        emit ICumulativeMerkleDistributor.UpdaterSet(address(0), updater);
        vm.expectEmit(true, true, true, true);
        emit ICumulativeMerkleDistributor.GuardianSet(address(0), guardian);
        new CumulativeMerkleDistributor(owner, updater, guardian);
    }

    function test_constructor_revertsOnZeroOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new CumulativeMerkleDistributor(address(0), updater, guardian);
    }

    function test_claimAuthorizationTypehash_matchesTypeString() public view {
        assertEq(
            distributor.CLAIM_AUTHORIZATION_TYPEHASH(),
            keccak256(
                "ClaimAuthorization(address account,address token,uint256 cumulativeAmount,address recipient,uint256 nonce,uint256 deadline)"
            )
        );
    }

    // ------------------------------------------------------------------------------------------------ proposeRoot

    function test_proposeRoot_storesPendingAndEmits() public {
        vm.expectEmit(true, true, true, true, address(distributor));
        emit ICumulativeMerkleDistributor.RootProposed(ROOT_1, META_1, START + 24 hours);
        vm.prank(updater);
        distributor.proposeRoot(ROOT_1, META_1);

        (bytes32 pending, bytes32 meta, uint64 validAt) = distributor.pendingRoot();
        assertEq(pending, ROOT_1);
        assertEq(meta, META_1);
        assertEq(validAt, START + 24 hours);
        assertEq(distributor.root(), bytes32(0), "active root untouched");
    }

    function test_proposeRoot_revertsForNonUpdater() public {
        address[3] memory callers = [owner, guardian, stranger];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(abi.encodeWithSelector(ICumulativeMerkleDistributor.NotUpdater.selector, callers[i]));
            distributor.proposeRoot(ROOT_1, META_1);
        }
    }

    function test_proposeRoot_revertsOnZeroRoot() public {
        vm.prank(updater);
        vm.expectRevert(ICumulativeMerkleDistributor.ZeroRoot.selector);
        distributor.proposeRoot(bytes32(0), META_1);
    }

    function test_proposeRoot_displacesPendingAndRestartsTimelock() public {
        _propose(ROOT_1);
        vm.warp(START + 23 hours);

        vm.expectEmit(true, true, true, true, address(distributor));
        emit ICumulativeMerkleDistributor.RootRevoked(ROOT_1, updater);
        vm.expectEmit(true, true, true, true, address(distributor));
        emit ICumulativeMerkleDistributor.RootProposed(ROOT_2, META_2, START + 23 hours + 24 hours);
        vm.prank(updater);
        distributor.proposeRoot(ROOT_2, META_2);

        // The old deadline no longer applies: a correction never shortens the veto window.
        vm.warp(START + 24 hours);
        vm.expectRevert(
            abi.encodeWithSelector(
                ICumulativeMerkleDistributor.RootTimelocked.selector, START + 47 hours, START + 24 hours
            )
        );
        distributor.acceptRoot();
    }

    function test_proposeRoot_canReproposeActiveRoot() public {
        _proposeAndAccept(ROOT_1);
        _proposeAndAccept(ROOT_1);
        assertEq(distributor.root(), ROOT_1);
        assertEq(distributor.epoch(), 2);
    }

    // ------------------------------------------------------------------------------------------------ revokePendingRoot

    function test_revokePendingRoot_clearsPendingAndEmits() public {
        _propose(ROOT_1);
        vm.expectEmit(true, true, true, true, address(distributor));
        emit ICumulativeMerkleDistributor.RootRevoked(ROOT_1, guardian);
        vm.prank(guardian);
        distributor.revokePendingRoot();

        (bytes32 pending,, uint64 validAt) = distributor.pendingRoot();
        assertEq(pending, bytes32(0));
        assertEq(validAt, 0);

        vm.warp(START + 30 days);
        vm.expectRevert(ICumulativeMerkleDistributor.NoPendingRoot.selector);
        distributor.acceptRoot();
    }

    function test_revokePendingRoot_allowedAfterTimelockUntilAccepted() public {
        _propose(ROOT_1);
        vm.warp(START + 48 hours);
        vm.prank(guardian);
        distributor.revokePendingRoot();
        assertEq(distributor.root(), bytes32(0));
    }

    function test_revokePendingRoot_keepsActiveRoot() public {
        _proposeAndAccept(ROOT_1);
        _propose(ROOT_2);
        vm.prank(guardian);
        distributor.revokePendingRoot();
        assertEq(distributor.root(), ROOT_1);
        assertEq(distributor.metadataHash(), MANIFEST);
    }

    function test_revokePendingRoot_revertsForNonGuardian() public {
        _propose(ROOT_1);
        address[3] memory callers = [owner, updater, stranger];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(abi.encodeWithSelector(ICumulativeMerkleDistributor.NotGuardian.selector, callers[i]));
            distributor.revokePendingRoot();
        }
    }

    function test_revokePendingRoot_revertsWithNothingPending() public {
        vm.prank(guardian);
        vm.expectRevert(ICumulativeMerkleDistributor.NoPendingRoot.selector);
        distributor.revokePendingRoot();
    }

    // ------------------------------------------------------------------------------------------------ acceptRoot

    function test_acceptRoot_activatesAfterTimelock() public {
        vm.prank(updater);
        distributor.proposeRoot(ROOT_1, META_1);
        vm.warp(START + 24 hours);

        vm.expectEmit(true, true, true, true, address(distributor));
        emit ICumulativeMerkleDistributor.RootAccepted(ROOT_1, META_1, 1);
        vm.prank(stranger); // permissionless
        distributor.acceptRoot();

        assertEq(distributor.root(), ROOT_1);
        assertEq(distributor.metadataHash(), META_1);
        assertEq(distributor.epoch(), 1);
        (bytes32 pending, bytes32 meta, uint64 validAt) = distributor.pendingRoot();
        assertEq(pending, bytes32(0));
        assertEq(meta, bytes32(0));
        assertEq(validAt, 0);
    }

    function test_acceptRoot_revertsOneSecondEarly() public {
        _propose(ROOT_1);
        vm.warp(START + 24 hours - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                ICumulativeMerkleDistributor.RootTimelocked.selector, START + 24 hours, START + 24 hours - 1
            )
        );
        distributor.acceptRoot();
    }

    function test_acceptRoot_revertsWithNothingPending() public {
        vm.expectRevert(ICumulativeMerkleDistributor.NoPendingRoot.selector);
        distributor.acceptRoot();
    }

    function test_acceptRoot_cannotBeReplayed() public {
        _proposeAndAccept(ROOT_1);
        vm.expectRevert(ICumulativeMerkleDistributor.NoPendingRoot.selector);
        distributor.acceptRoot();
    }

    function test_acceptRoot_rotatesRootsAndCountsEpochs() public {
        _proposeAndAccept(ROOT_1);
        vm.prank(updater);
        distributor.proposeRoot(ROOT_2, META_2);
        assertEq(distributor.root(), ROOT_1, "old root stays active during the veto window");
        vm.warp(block.timestamp + 24 hours);
        distributor.acceptRoot();
        assertEq(distributor.root(), ROOT_2);
        assertEq(distributor.metadataHash(), META_2);
        assertEq(distributor.epoch(), 2);
    }

    function testFuzz_acceptRoot_respectsTimelock(uint256 elapsed) public {
        elapsed = bound(elapsed, 0, 60 days);
        _propose(ROOT_1);
        vm.warp(START + elapsed);
        if (elapsed < 24 hours) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    ICumulativeMerkleDistributor.RootTimelocked.selector, START + 24 hours, START + elapsed
                )
            );
            distributor.acceptRoot();
            assertEq(distributor.root(), bytes32(0));
        } else {
            distributor.acceptRoot();
            assertEq(distributor.root(), ROOT_1);
        }
    }

    // ------------------------------------------------------------------------------------------------ admin

    function test_setUpdater_onlyOwnerAndEmits() public {
        address newUpdater = makeAddr("new updater");
        vm.expectEmit(true, true, true, true, address(distributor));
        emit ICumulativeMerkleDistributor.UpdaterSet(updater, newUpdater);
        vm.prank(owner);
        distributor.setUpdater(newUpdater);
        assertEq(distributor.updater(), newUpdater);

        vm.prank(updater);
        vm.expectRevert(abi.encodeWithSelector(ICumulativeMerkleDistributor.NotUpdater.selector, updater));
        distributor.proposeRoot(ROOT_1, META_1);

        vm.prank(newUpdater);
        distributor.proposeRoot(ROOT_1, META_1);
    }

    function test_setUpdater_zeroDisablesProposals() public {
        vm.prank(owner);
        distributor.setUpdater(address(0));
        vm.prank(updater);
        vm.expectRevert(abi.encodeWithSelector(ICumulativeMerkleDistributor.NotUpdater.selector, updater));
        distributor.proposeRoot(ROOT_1, META_1);
    }

    function test_setUpdater_revertsForNonOwner() public {
        vm.prank(updater);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, updater));
        distributor.setUpdater(stranger);
    }

    function test_setGuardian_onlyOwnerAndEmits() public {
        address newGuardian = makeAddr("new guardian");
        vm.expectEmit(true, true, true, true, address(distributor));
        emit ICumulativeMerkleDistributor.GuardianSet(guardian, newGuardian);
        vm.prank(owner);
        distributor.setGuardian(newGuardian);
        assertEq(distributor.guardian(), newGuardian);

        _propose(ROOT_1);
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(ICumulativeMerkleDistributor.NotGuardian.selector, guardian));
        distributor.revokePendingRoot();
        vm.prank(newGuardian);
        distributor.revokePendingRoot();
    }

    function test_setGuardian_revertsForNonOwner() public {
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        distributor.setGuardian(stranger);
    }

    function test_ownership_isTwoStep() public {
        address newOwner = makeAddr("new owner");
        vm.prank(owner);
        distributor.transferOwnership(newOwner);
        assertEq(distributor.owner(), owner, "not transferred until accepted");
        assertEq(distributor.pendingOwner(), newOwner);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        distributor.acceptOwnership();

        vm.prank(newOwner);
        distributor.acceptOwnership();
        assertEq(distributor.owner(), newOwner);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        distributor.setGuardian(stranger);
    }
}
