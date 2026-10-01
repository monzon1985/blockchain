// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Deploy} from "../../script/Deploy.s.sol";
import {CumulativeMerkleDistributor} from "../../src/CumulativeMerkleDistributor.sol";
import {Test} from "forge-std/Test.sol";

/// @notice The deployment script wires the three roles as given and refuses configurations that would silently break the
///         separation of duties.
contract DeployScriptTest is Test {
    Deploy internal script;
    address internal owner = makeAddr("owner");
    address internal updater = makeAddr("updater");
    address internal guardian = makeAddr("guardian");

    function setUp() public {
        script = new Deploy();
    }

    /// @dev The only test that touches the process environment (tests run in parallel, `vm.setEnv` is global).
    function test_run_readsRolesFromEnvironment() public {
        vm.setEnv("DISTRIBUTOR_OWNER", vm.toString(owner));
        vm.setEnv("DISTRIBUTOR_UPDATER", vm.toString(updater));
        vm.setEnv("DISTRIBUTOR_GUARDIAN", vm.toString(guardian));
        CumulativeMerkleDistributor distributor = script.run();

        assertEq(distributor.owner(), owner);
        assertEq(distributor.updater(), updater);
        assertEq(distributor.guardian(), guardian);
        assertEq(distributor.root(), bytes32(0));
        assertEq(distributor.epoch(), 0);
        assertEq(distributor.ROOT_TIMELOCK(), 24 hours);
    }

    function test_deploy_rejectsZeroRoles() public {
        vm.expectRevert(abi.encodeWithSelector(Deploy.ZeroRoleAddress.selector, "owner"));
        script.deploy(address(0), updater, guardian);
        vm.expectRevert(abi.encodeWithSelector(Deploy.ZeroRoleAddress.selector, "updater"));
        script.deploy(owner, address(0), guardian);
        vm.expectRevert(abi.encodeWithSelector(Deploy.ZeroRoleAddress.selector, "guardian"));
        script.deploy(owner, updater, address(0));
    }

    function test_deploy_rejectsSharedRoles() public {
        vm.expectRevert(abi.encodeWithSelector(Deploy.SharedRole.selector, owner));
        script.deploy(owner, owner, guardian);
        vm.expectRevert(abi.encodeWithSelector(Deploy.SharedRole.selector, owner));
        script.deploy(owner, updater, owner);
        vm.expectRevert(abi.encodeWithSelector(Deploy.SharedRole.selector, updater));
        script.deploy(owner, updater, updater);
    }
}
