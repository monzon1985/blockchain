// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";

import {Roles} from "../../src/access/Roles.sol";
import {ReserveGate} from "../../src/modules/ReserveGate.sol";
import {MintController} from "../../src/modules/MintController.sol";
import {TestPaymentDollarV2} from "../../src/TestPaymentDollarV2.sol";
import {StablecoinDeployment} from "../../script/StablecoinDeployment.sol";
import {StablecoinTestBase} from "../utils/StablecoinTestBase.sol";

/// @notice Role wiring and governance delays: every restricted selector rejects outsiders, the production role
///         holders are exactly the configured ones, and upgrades plus role-admin operations need a 2-day schedule.
contract AccessControlTest is StablecoinTestBase {
    address internal outsider = makeAddr("outsider");

    // ------------------------------------------------------------------------------------------------------------
    // Wiring
    // ------------------------------------------------------------------------------------------------------------

    function test_wiring_everySelectorMappedToItsRole() public view {
        StablecoinDeployment.SelectorRole[] memory table = StablecoinDeployment.v1SelectorRoles();
        for (uint256 i; i < table.length; ++i) {
            assertEq(manager.getTargetFunctionRole(address(token), table[i].selector), table[i].roleId, table[i].name);
        }
        bytes4[] memory adminOnly = StablecoinDeployment.v1AdminSelectors();
        for (uint256 i; i < adminOnly.length; ++i) {
            assertEq(manager.getTargetFunctionRole(address(token), adminOnly[i]), Roles.ADMIN);
        }
    }

    function test_wiring_roleHoldersAndDelays() public view {
        _assertMember(Roles.ADMIN, governance, Roles.GOVERNANCE_DELAY);
        _assertMember(Roles.UPGRADER, upgrader, Roles.GOVERNANCE_DELAY);
        _assertMember(Roles.MASTER_MINTER, masterMinter, 0);
        _assertMember(Roles.MINTER, minter, 0);
        _assertMember(Roles.MINTER, minter2, 0);
        _assertMember(Roles.PAUSER, pauser, 0);
        _assertMember(Roles.BLOCKLISTER, blocklister, 0);
        _assertMember(Roles.COMPLIANCE_OFFICER, compliance, 0);
        _assertMember(Roles.BRIDGE, bridge, 0);
        (bool deployerIsAdmin,) = manager.hasRole(Roles.ADMIN, address(this));
        assertFalse(deployerIsAdmin, "deployer renounced ADMIN");
        assertEq(manager.getRoleGuardian(Roles.UPGRADER), Roles.PAUSER);
    }

    function test_restrictedSelectors_rejectOutsiders() public {
        StablecoinDeployment.SelectorRole[] memory table = StablecoinDeployment.v1SelectorRoles();
        for (uint256 i; i < table.length; ++i) {
            _expectUnauthorized(outsider, _dummyCall(table[i].selector));
        }
        bytes4[] memory adminOnly = StablecoinDeployment.v1AdminSelectors();
        for (uint256 i; i < adminOnly.length; ++i) {
            _expectUnauthorized(outsider, _dummyCall(adminOnly[i]));
        }
    }

    function test_restrictedSelectors_rejectWrongRole() public {
        // A minter cannot pause, a pauser cannot mint, the master minter cannot freeze, the bridge cannot blocklist.
        _expectUnauthorized(minter, abi.encodeCall(token.pause, ()));
        _expectUnauthorized(pauser, abi.encodeCall(token.mint, (alice, 1)));
        _expectUnauthorized(masterMinter, abi.encodeCall(token.freeze, (alice, ORDER_REF)));
        _expectUnauthorized(bridge, abi.encodeCall(token.blocklist, (alice)));
        _expectUnauthorized(compliance, abi.encodeCall(token.configureMinter, (alice, 1, 1)));
        _expectUnauthorized(blocklister, abi.encodeCall(token.seize, (alice, bob, 1, ORDER_REF)));
    }

    // ------------------------------------------------------------------------------------------------------------
    // Governance delay (ADMIN)
    // ------------------------------------------------------------------------------------------------------------

    function test_admin_tokenSelectorsNeedSchedule() public {
        bytes memory data = abi.encodeCall(ReserveGate.setReserveAttestor, (alice));
        bytes32 id = manager.hashOperation(governance, address(token), data);
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IAccessManager.AccessManagerNotScheduled.selector, id));
        token.setReserveAttestor(alice);

        vm.prank(governance);
        manager.schedule(address(token), data, 0);
        vm.warp(block.timestamp + Roles.GOVERNANCE_DELAY - 1);
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IAccessManager.AccessManagerNotReady.selector, id));
        manager.execute(address(token), data);

        vm.warp(block.timestamp + 1);
        vm.prank(governance);
        manager.execute(address(token), data);
        assertEq(token.reserveAttestor(), alice);
    }

    function test_admin_scheduledOperationExpires() public {
        bytes memory data = abi.encodeCall(MintController.setMinterLimitCeiling, (1));
        bytes32 id = manager.hashOperation(governance, address(token), data);
        vm.prank(governance);
        manager.schedule(address(token), data, 0);
        vm.warp(block.timestamp + Roles.GOVERNANCE_DELAY + manager.expiration());
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IAccessManager.AccessManagerExpired.selector, id));
        manager.execute(address(token), data);
    }

    function test_admin_roleAdminSelectorsNeedSchedule() public {
        // grantRole, setTargetFunctionRole and setRoleAdmin are all behind the ADMIN execution delay.
        bytes[] memory calls = new bytes[](4);
        calls[0] = abi.encodeCall(AccessManager.grantRole, (Roles.MINTER, outsider, 0));
        calls[1] = abi.encodeCall(AccessManager.revokeRole, (Roles.MINTER, minter));
        calls[2] = abi.encodeCall(AccessManager.setRoleAdmin, (Roles.MINTER, Roles.MASTER_MINTER));
        bytes4[] memory sel = new bytes4[](1);
        sel[0] = token.mint.selector;
        calls[3] = abi.encodeCall(AccessManager.setTargetFunctionRole, (address(token), sel, type(uint64).max));
        for (uint256 i; i < calls.length; ++i) {
            bytes32 id = manager.hashOperation(governance, address(manager), calls[i]);
            vm.prank(governance);
            (bool ok, bytes memory ret) = address(manager).call(calls[i]);
            assertFalse(ok);
            assertEq(ret, abi.encodeWithSelector(IAccessManager.AccessManagerNotScheduled.selector, id));
        }
    }

    function test_admin_grantMinterRoleAfterDelay() public {
        _governance(address(manager), abi.encodeCall(AccessManager.grantRole, (Roles.MINTER, outsider, 0)));
        _assertMember(Roles.MINTER, outsider, 0);
        // The new role holder still needs a minter configuration from the master minter.
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(MinterNotConfigured.selector, outsider));
        token.mint(alice, 1);
    }

    function test_masterMinter_cannotGrantMinterRole() public {
        vm.prank(masterMinter);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManager.AccessManagerUnauthorizedAccount.selector, masterMinter, Roles.ADMIN)
        );
        manager.grantRole(Roles.MINTER, outsider, 0);
    }

    function test_outsider_cannotSchedule() public {
        bytes memory data = abi.encodeCall(ReserveGate.setReserveAttestor, (outsider));
        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessManager.AccessManagerUnauthorizedCall.selector,
                outsider,
                address(token),
                ReserveGate.setReserveAttestor.selector
            )
        );
        manager.schedule(address(token), data, 0);
    }

    function test_setAuthority_onlyThroughManager() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, governance));
        token.setAuthority(outsider);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Upgrade delay (UPGRADER) and guardian
    // ------------------------------------------------------------------------------------------------------------

    function test_upgrade_directCallNeedsSchedule() public {
        address v2 = address(new TestPaymentDollarV2());
        bytes memory data = StablecoinDeployment.v2UpgradeCalldata(v2);
        bytes32 id = manager.hashOperation(upgrader, address(token), data);
        vm.prank(upgrader);
        (bool ok, bytes memory ret) = address(token).call(data);
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(IAccessManager.AccessManagerNotScheduled.selector, id));
    }

    function test_upgrade_outsiderRejected() public {
        address v2 = address(new TestPaymentDollarV2());
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, outsider));
        token.upgradeToAndCall(v2, "");
    }

    function test_upgrade_executesOnlyAfterDelay() public {
        address v2 = address(new TestPaymentDollarV2());
        bytes memory data = StablecoinDeployment.v2UpgradeCalldata(v2);
        bytes32 id = manager.hashOperation(upgrader, address(token), data);
        vm.prank(upgrader);
        manager.schedule(address(token), data, 0);
        vm.warp(block.timestamp + Roles.GOVERNANCE_DELAY - 1);
        vm.prank(upgrader);
        vm.expectRevert(abi.encodeWithSelector(IAccessManager.AccessManagerNotReady.selector, id));
        manager.execute(address(token), data);
        vm.warp(block.timestamp + 1);
        vm.prank(upgrader);
        manager.execute(address(token), data);
        assertEq(token.implementationVersion(), "2");
    }

    function test_upgrade_pauserGuardianCancels() public {
        address v2 = address(new TestPaymentDollarV2());
        bytes memory data = StablecoinDeployment.v2UpgradeCalldata(v2);
        bytes32 id = manager.hashOperation(upgrader, address(token), data);
        vm.prank(upgrader);
        manager.schedule(address(token), data, 0);

        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessManager.AccessManagerUnauthorizedCancel.selector,
                outsider,
                upgrader,
                address(token),
                token.upgradeToAndCall.selector
            )
        );
        manager.cancel(upgrader, address(token), data);

        vm.prank(pauser);
        manager.cancel(upgrader, address(token), data);
        vm.warp(block.timestamp + Roles.GOVERNANCE_DELAY);
        vm.prank(upgrader);
        vm.expectRevert(abi.encodeWithSelector(IAccessManager.AccessManagerNotScheduled.selector, id));
        manager.execute(address(token), data);
        assertEq(token.implementationVersion(), "1");
    }

    function test_operationalRoles_actImmediately() public {
        vm.prank(pauser);
        token.pause();
        assertTrue(token.paused());
        vm.prank(pauser);
        token.unpause();
        vm.prank(blocklister);
        token.blocklist(outsider);
        assertTrue(token.isBlocklisted(outsider));
    }

    // ------------------------------------------------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------------------------------------------------

    function _assertMember(uint64 roleId, address account, uint32 expectedDelay) internal view {
        (bool isMember, uint32 delay) = manager.hasRole(roleId, account);
        assertTrue(isMember, "missing role");
        assertEq(delay, expectedDelay, "execution delay");
    }

    function _expectUnauthorized(address caller, bytes memory data) internal {
        vm.prank(caller);
        (bool ok, bytes memory ret) = address(token).call(data);
        assertFalse(ok, "restricted call succeeded");
        assertEq(ret, abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, caller));
    }

    /// @dev Well-formed calldata for any restricted selector; the arguments never matter because the access check
    ///      runs before anything else.
    function _dummyCall(bytes4 selector) internal view returns (bytes memory) {
        if (selector == token.configureMinter.selector) return abi.encodeWithSelector(selector, alice, 1, 1);
        if (selector == token.removeMinter.selector) return abi.encodeWithSelector(selector, minter);
        if (selector == token.mint.selector) return abi.encodeWithSelector(selector, alice, 1);
        if (selector == token.burn.selector) return abi.encodeWithSelector(selector, 1);
        if (selector == token.pause.selector || selector == token.unpause.selector) {
            return abi.encodeWithSelector(selector);
        }
        if (selector == token.blocklist.selector || selector == token.unBlocklist.selector) {
            return abi.encodeWithSelector(selector, alice);
        }
        if (selector == token.freeze.selector || selector == token.unfreeze.selector) {
            return abi.encodeWithSelector(selector, alice, ORDER_REF);
        }
        if (selector == token.seize.selector) return abi.encodeWithSelector(selector, alice, bob, 1, ORDER_REF);
        if (selector == token.burnFrozen.selector) return abi.encodeWithSelector(selector, alice, ORDER_REF);
        if (selector == token.crosschainMint.selector || selector == token.crosschainBurn.selector) {
            return abi.encodeWithSelector(selector, alice, 1);
        }
        if (selector == token.upgradeToAndCall.selector) return abi.encodeWithSelector(selector, implementationV1, "");
        if (selector == token.setReserveAttestor.selector) return abi.encodeWithSelector(selector, alice);
        if (selector == token.setMinterLimitCeiling.selector) return abi.encodeWithSelector(selector, 1);
        if (selector == token.setBridgeLimits.selector) return abi.encodeWithSelector(selector, 1, 1);
        revert("unknown selector");
    }
}
