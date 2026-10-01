// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {UpgradeGovernance} from "../../script/UpgradeGovernance.sol";
import {SubscriptionRegistryV2} from "../../src/uups/v2/SubscriptionRegistryV2.sol";
import {SubscriptionRegistryV3} from "../../src/uups/v3/SubscriptionRegistryV3.sol";
import {IUUPS, LabBase} from "../utils/LabBase.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";

/// @notice A V2 proxy reached through the safe migration, gated by an AccessManager configured as the scripts
///         configure it (`UpgradeGovernance`), with `_admin()` holding the manager's ADMIN role.
abstract contract TimelockFixture is LabBase {
    address internal proxy;
    AccessManager internal manager;
    address internal v3;
    bytes internal upgradeCall;
    address internal stranger = makeAddr("stranger");

    function _admin() internal view virtual returns (address);

    function setUp() public {
        vm.warp(1_700_000_000);
        proxy = _deployV1(owner);
        manager = _deployManager(_admin(), proxy);
        _migrateToV2(proxy, manager);
        v3 = address(new SubscriptionRegistryV3());
        upgradeCall = abi.encodeCall(IUUPS.upgradeToAndCall, (v3, ""));
    }

    /// @dev The revert an ADMIN operation hits when it was not scheduled `UPGRADE_DELAY` ahead.
    function _expectNotScheduled(address caller, address target, bytes memory data) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessManager.AccessManagerNotScheduled.selector, manager.hashOperation(caller, target, data)
            )
        );
    }
}

/// @notice From V2 on, `upgradeToAndCall` is `restricted`: only the UPGRADER role may upgrade, only after a
///         2-day delay, and a GUARDIAN can cancel a scheduled upgrade before it executes.
contract TimelockUpgradeTest is TimelockFixture {
    function _admin() internal view override returns (address) {
        return governance;
    }

    function _opId() internal view returns (bytes32) {
        return manager.hashOperation(upgrader, proxy, upgradeCall);
    }

    function test_scheduleWaitExecute() public {
        vm.prank(upgrader);
        (bytes32 id,) = manager.schedule(proxy, upgradeCall, 0);
        assertEq(id, _opId());
        assertEq(manager.getSchedule(id), vm.getBlockTimestamp() + UPGRADE_DELAY);

        vm.warp(vm.getBlockTimestamp() + UPGRADE_DELAY - 1);
        vm.expectRevert(abi.encodeWithSelector(IAccessManager.AccessManagerNotReady.selector, id));
        vm.prank(upgrader);
        manager.execute(proxy, upgradeCall);

        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(upgrader);
        manager.execute(proxy, upgradeCall);
        assertEq(_implementation(proxy), v3);
        assertEq(SubscriptionRegistryV3(proxy).version(), "3.0.0");
    }

    function test_upgraderMayAlsoCallTheProxyDirectlyOnceReady() public {
        vm.prank(upgrader);
        manager.schedule(proxy, upgradeCall, 0);
        vm.warp(vm.getBlockTimestamp() + UPGRADE_DELAY);
        // The proxy consumes the schedule through `consumeScheduledOp`.
        vm.prank(upgrader);
        IUUPS(proxy).upgradeToAndCall(v3, "");
        assertEq(_implementation(proxy), v3);
    }

    function test_unscheduledUpgradeReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IAccessManager.AccessManagerNotScheduled.selector, _opId()));
        vm.prank(upgrader);
        IUUPS(proxy).upgradeToAndCall(v3, "");
    }

    function test_guardianCancels() public {
        vm.prank(upgrader);
        (bytes32 id,) = manager.schedule(proxy, upgradeCall, 0);
        vm.prank(guardian);
        manager.cancel(upgrader, proxy, upgradeCall);
        assertEq(manager.getSchedule(id), 0);

        vm.warp(vm.getBlockTimestamp() + UPGRADE_DELAY);
        vm.expectRevert(abi.encodeWithSelector(IAccessManager.AccessManagerNotScheduled.selector, id));
        vm.prank(upgrader);
        manager.execute(proxy, upgradeCall);
        assertEq(SubscriptionRegistryV2(proxy).version(), "2.0.0");
    }

    function test_strangerCannotCancel() public {
        vm.prank(upgrader);
        manager.schedule(proxy, upgradeCall, 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessManager.AccessManagerUnauthorizedCancel.selector,
                stranger,
                upgrader,
                proxy,
                IUUPS.upgradeToAndCall.selector
            )
        );
        vm.prank(stranger);
        manager.cancel(upgrader, proxy, upgradeCall);
    }

    function test_scheduleExpiresAfterOneWeek() public {
        vm.prank(upgrader);
        (bytes32 id,) = manager.schedule(proxy, upgradeCall, 0);
        vm.warp(vm.getBlockTimestamp() + UPGRADE_DELAY + manager.expiration());
        vm.expectRevert(abi.encodeWithSelector(IAccessManager.AccessManagerExpired.selector, id));
        vm.prank(upgrader);
        manager.execute(proxy, upgradeCall);
    }

    function test_ownerAndStrangersCannotUpgrade() public {
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, owner));
        vm.prank(owner);
        IUUPS(proxy).upgradeToAndCall(v3, "");

        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        vm.prank(stranger);
        IUUPS(proxy).upgradeToAndCall(v3, "");

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessManager.AccessManagerUnauthorizedCall.selector, stranger, proxy, IUUPS.upgradeToAndCall.selector
            )
        );
        vm.prank(stranger);
        manager.schedule(proxy, upgradeCall, 0);
    }

    function test_v3StaysUpgradeableThroughTheManager() public {
        vm.prank(upgrader);
        manager.schedule(proxy, upgradeCall, 0);
        vm.warp(vm.getBlockTimestamp() + UPGRADE_DELAY);
        vm.prank(upgrader);
        manager.execute(proxy, upgradeCall);

        // V3 -> V3' (a patch release) goes through the same delay; a direct call by the plan owner is rejected
        // (the ADMIN paths are covered by `AdminDelayTest`).
        address patch = address(new SubscriptionRegistryV3());
        bytes memory patchCall = abi.encodeCall(IUUPS.upgradeToAndCall, (patch, ""));
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, owner));
        vm.prank(owner);
        IUUPS(proxy).upgradeToAndCall(patch, "");
        vm.prank(upgrader);
        manager.schedule(proxy, patchCall, 0);
        vm.warp(vm.getBlockTimestamp() + UPGRADE_DELAY);
        vm.prank(upgrader);
        manager.execute(proxy, patchCall);
        assertEq(_implementation(proxy), patch);
    }

    function test_setAuthority_onlyThroughTheCurrentManagerAfterTheDelay() public {
        AccessManager other = new AccessManager(governance);
        // The proxy itself only listens to its current authority.
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, governance));
        vm.prank(governance);
        SubscriptionRegistryV2(proxy).setAuthority(address(other));

        // The manager's ADMIN can move it, but only as a scheduled operation.
        bytes memory move = abi.encodeCall(AccessManager.updateAuthority, (proxy, address(other)));
        vm.prank(governance);
        manager.schedule(address(manager), move, 0);
        vm.warp(vm.getBlockTimestamp() + UPGRADE_DELAY);
        vm.prank(governance);
        manager.execute(address(manager), move);
        assertEq(SubscriptionRegistryV2(proxy).authority(), address(other));
    }
}

/// @notice The AccessManager's ADMIN could otherwise bypass the UPGRADER delay: grant itself (or anyone) an
///         undelayed UPGRADER role, re-point the proxy at a manager it controls, or open the upgrade function to
///         everyone, and upgrade in the same block. `UpgradeGovernance` puts ADMIN behind the same delay and lets the
///         guardian cancel every ADMIN operation, so each of those paths has the same public, vetoable window.
contract AdminDelayTest is TimelockFixture {
    function _admin() internal view override returns (address) {
        return governance;
    }

    function test_configurationMatchesTheDeploymentScripts() public {
        (bool isAdmin, uint32 adminDelay) = manager.hasRole(ADMIN_ROLE, governance);
        assertTrue(isAdmin);
        assertEq(adminDelay, UPGRADE_DELAY, "ADMIN is delayed");
        (bool isUpgrader, uint32 upgraderDelay) = manager.hasRole(UPGRADER_ROLE, upgrader);
        assertTrue(isUpgrader);
        assertEq(upgraderDelay, UPGRADE_DELAY);
        assertEq(manager.getRoleGuardian(UPGRADER_ROLE), GUARDIAN_ROLE);
        assertEq(manager.getRoleGuardian(ADMIN_OPERATIONS_ROLE), GUARDIAN_ROLE);
        bytes4[] memory ops = UpgradeGovernance.adminOperations();
        for (uint256 i; i < ops.length; ++i) {
            assertEq(manager.getTargetFunctionRole(address(manager), ops[i]), ADMIN_OPERATIONS_ROLE);
        }
        // Defence in depth: the grant delay and the target admin delay take effect after the manager's setback.
        assertEq(manager.getRoleGrantDelay(UPGRADER_ROLE), 0);
        vm.warp(vm.getBlockTimestamp() + manager.minSetback());
        assertEq(manager.getRoleGrantDelay(UPGRADER_ROLE), UPGRADE_DELAY);
        assertEq(manager.getTargetAdminDelay(proxy), UPGRADE_DELAY);
    }

    /// @notice Regression test for the review finding: ADMIN grants itself UPGRADER with no execution delay.
    function test_adminCannotGrantItselfAnUndelayedUpgraderRole() public {
        bytes memory grant = abi.encodeCall(AccessManager.grantRole, (UPGRADER_ROLE, governance, 0));
        _expectNotScheduled(governance, address(manager), grant);
        vm.prank(governance);
        manager.grantRole(UPGRADER_ROLE, governance, 0);

        _expectNotScheduled(governance, address(manager), grant);
        vm.prank(governance);
        manager.execute(address(manager), grant);

        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, governance));
        vm.prank(governance);
        IUUPS(proxy).upgradeToAndCall(v3, "");
    }

    /// @notice The ADMIN path to an upgrade exists, but it is announced, waits the full delay and can be vetoed.
    function test_adminPathToAnUpgradeTakesTheFullDelayAndCanBeVetoed() public {
        bytes memory grant = abi.encodeCall(AccessManager.grantRole, (UPGRADER_ROLE, governance, 0));
        uint256 announced = vm.getBlockTimestamp();
        vm.prank(governance);
        (bytes32 id,) = manager.schedule(address(manager), grant, 0);
        assertEq(manager.getSchedule(id), announced + UPGRADE_DELAY);

        vm.prank(guardian);
        manager.cancel(governance, address(manager), grant);
        assertEq(manager.getSchedule(id), 0, "vetoed by the guardian");

        vm.prank(governance);
        manager.schedule(address(manager), grant, 0);
        vm.warp(announced + UPGRADE_DELAY - 1);
        vm.expectRevert(abi.encodeWithSelector(IAccessManager.AccessManagerNotReady.selector, id));
        vm.prank(governance);
        manager.execute(address(manager), grant);

        vm.warp(announced + UPGRADE_DELAY);
        vm.prank(governance);
        manager.execute(address(manager), grant);
        vm.prank(governance);
        IUUPS(proxy).upgradeToAndCall(v3, "");
        assertEq(_implementation(proxy), v3);
        assertGe(vm.getBlockTimestamp(), announced + UPGRADE_DELAY, "never earlier than the public window");
    }

    function test_onceInForce_aNewUpgraderAlsoWaitsTheGrantDelay() public {
        vm.warp(vm.getBlockTimestamp() + manager.minSetback());
        bytes memory grant = abi.encodeCall(AccessManager.grantRole, (UPGRADER_ROLE, stranger, 0));
        vm.prank(governance);
        manager.schedule(address(manager), grant, 0);
        vm.warp(vm.getBlockTimestamp() + UPGRADE_DELAY);
        vm.prank(governance);
        manager.execute(address(manager), grant);

        (bool member,) = manager.hasRole(UPGRADER_ROLE, stranger);
        assertFalse(member, "membership waits the grant delay");
        vm.warp(vm.getBlockTimestamp() + UPGRADE_DELAY);
        (member,) = manager.hasRole(UPGRADER_ROLE, stranger);
        assertTrue(member);
    }

    function test_adminCannotRepointTheAuthorityInstantly() public {
        AccessManager rogue = new AccessManager(governance);
        bytes memory move = abi.encodeCall(AccessManager.updateAuthority, (proxy, address(rogue)));
        _expectNotScheduled(governance, address(manager), move);
        vm.prank(governance);
        manager.updateAuthority(proxy, address(rogue));

        vm.prank(governance);
        (bytes32 id,) = manager.schedule(address(manager), move, 0);
        vm.prank(guardian);
        manager.cancel(governance, address(manager), move);
        assertEq(manager.getSchedule(id), 0);
        assertEq(SubscriptionRegistryV2(proxy).authority(), address(manager));
    }

    function test_adminCannotOpenTheUpgradeFunctionInstantly() public {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = IUUPS.upgradeToAndCall.selector;
        uint64 publicRole = manager.PUBLIC_ROLE();
        bytes memory open = abi.encodeCall(AccessManager.setTargetFunctionRole, (proxy, selectors, publicRole));
        _expectNotScheduled(governance, address(manager), open);
        vm.prank(governance);
        manager.setTargetFunctionRole(proxy, selectors, publicRole);

        // Executing the proxy's upgrade directly as ADMIN does not work either: ADMIN does not hold UPGRADER.
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessManager.AccessManagerUnauthorizedCall.selector,
                governance,
                proxy,
                IUUPS.upgradeToAndCall.selector
            )
        );
        vm.prank(governance);
        manager.execute(proxy, upgradeCall);
    }

    function test_guardianCanCancelEveryKindOfAdminOperation() public {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = IUUPS.upgradeToAndCall.selector;
        bytes[] memory ops = new bytes[](4);
        ops[0] = abi.encodeCall(AccessManager.grantRole, (UPGRADER_ROLE, stranger, 0));
        ops[1] = abi.encodeCall(AccessManager.revokeRole, (GUARDIAN_ROLE, guardian));
        ops[2] = abi.encodeCall(AccessManager.setTargetFunctionRole, (proxy, selectors, manager.PUBLIC_ROLE()));
        ops[3] = abi.encodeCall(AccessManager.setRoleGuardian, (UPGRADER_ROLE, UPGRADER_ROLE));
        for (uint256 i; i < ops.length; ++i) {
            vm.prank(governance);
            (bytes32 id,) = manager.schedule(address(manager), ops[i], 0);
            vm.prank(guardian);
            manager.cancel(governance, address(manager), ops[i]);
            assertEq(manager.getSchedule(id), 0);
        }
        // Somebody without a role cannot.
        vm.prank(governance);
        manager.schedule(address(manager), ops[0], 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessManager.AccessManagerUnauthorizedCancel.selector,
                stranger,
                governance,
                address(manager),
                AccessManager.grantRole.selector
            )
        );
        vm.prank(stranger);
        manager.cancel(governance, address(manager), ops[0]);
    }
}

/// @notice The configuration of the local demo, where one account is both the plan owner and the manager's ADMIN.
///         The owner still cannot upgrade faster than the delay.
contract OwnerIsAdminTimelockTest is TimelockFixture {
    function _admin() internal view override returns (address) {
        return owner;
    }

    /// @notice Regression test for the review's proof of concept: `grantRole(UPGRADER_ROLE, owner, 0)` followed by
    ///         `upgradeToAndCall` in the same block.
    function test_ownerAsAdminCannotUpgradeInstantly() public {
        bytes memory grant = abi.encodeCall(AccessManager.grantRole, (UPGRADER_ROLE, owner, 0));
        _expectNotScheduled(owner, address(manager), grant);
        vm.prank(owner);
        manager.grantRole(UPGRADER_ROLE, owner, 0);

        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, owner));
        vm.prank(owner);
        IUUPS(proxy).upgradeToAndCall(v3, "");
        assertEq(SubscriptionRegistryV2(proxy).version(), "2.0.0");
    }

    function test_ownerAsAdminCannotRepointTheAuthorityInstantly() public {
        AccessManager mine = new AccessManager(owner);
        bytes memory move = abi.encodeCall(AccessManager.updateAuthority, (proxy, address(mine)));
        _expectNotScheduled(owner, address(manager), move);
        vm.prank(owner);
        manager.updateAuthority(proxy, address(mine));
        assertEq(SubscriptionRegistryV2(proxy).authority(), address(manager));
    }
}
