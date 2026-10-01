// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {console2} from "forge-std/Script.sol";

import {TestPaymentDollarV2} from "../src/TestPaymentDollarV2.sol";
import {DeploymentIO} from "./DeploymentIO.sol";
import {StablecoinDeployment} from "./StablecoinDeployment.sol";

/**
 * @title UpgradeToV2
 * @notice The v1 -> v2 procedure in four keystore-signed steps, split by role and separated by the 2-day delay:
 *
 *      1. upgrader:   forge script script/UpgradeToV2.s.sol --sig "schedule()"        --broadcast ...
 *      2. governance: forge script script/UpgradeToV2.s.sol --sig "scheduleWiring()"  --broadcast ...
 *         (wait Roles.GOVERNANCE_DELAY; the pauser can cancel the upgrade in the meantime)
 *      3. upgrader:   forge script script/UpgradeToV2.s.sol --sig "execute()"         --broadcast ...
 *      4. governance: forge script script/UpgradeToV2.s.sol --sig "executeWiring()"   --broadcast ...
 *
 *      The v2 implementation address is kept in `upgradeFile()` (default `demo-out/upgrade.json`) between the steps;
 *      `VerifyRoles.s.sol` also reads it to recognise the upgraded proxy.
 */
contract UpgradeToV2 is DeploymentIO {
    /// @notice Step 1 (UPGRADER): deploys the v2 implementation and schedules `upgradeToAndCall(v2, initializeV2())`
    ///         on the AccessManager, executable after the UPGRADER execution delay.
    /// @dev Records the implementation address in `upgradeFile()` and logs the operation id and its execution time.
    function schedule() external {
        Recorded memory r = readDeployment();
        vm.startBroadcast();
        address implementation = address(new TestPaymentDollarV2());
        (bytes32 id,) = r.manager.schedule(address(r.token), StablecoinDeployment.v2UpgradeCalldata(implementation), 0);
        vm.stopBroadcast();
        vm.writeJson(vm.serializeAddress("upgrade", "implementationV2", implementation), upgradeFile());
        console2.log("v2 implementation ", implementation);
        console2.log("operation id");
        console2.logBytes32(id);
        console2.log("executable at     ", r.manager.getSchedule(id));
    }

    /// @notice Step 2 (governance, ADMIN): schedules the v2 selector wiring (`setTransferCapFlag` ->
    ///         COMPLIANCE_OFFICER) on the AccessManager, executable after the ADMIN execution delay.
    function scheduleWiring() external {
        Recorded memory r = readDeployment();
        vm.startBroadcast();
        r.manager.schedule(address(r.manager), StablecoinDeployment.v2WiringCalldata(address(r.token)), 0);
        vm.stopBroadcast();
    }

    /// @notice Step 3 (UPGRADER): executes the scheduled upgrade once the delay has passed.
    /// @dev Reverts with `AccessManagerNotReady` before the delay and `AccessManagerNotScheduled` if the pauser
    ///      cancelled the operation.
    function execute() external {
        Recorded memory r = readDeployment();
        address implementation = recordedImplementationV2();
        vm.startBroadcast();
        r.manager.execute(address(r.token), StablecoinDeployment.v2UpgradeCalldata(implementation));
        vm.stopBroadcast();
        console2.log("implementation version now ", r.token.implementationVersion());
    }

    /// @notice Step 4 (governance, ADMIN): executes the scheduled v2 selector wiring once the delay has passed.
    function executeWiring() external {
        Recorded memory r = readDeployment();
        vm.startBroadcast();
        r.manager.execute(address(r.manager), StablecoinDeployment.v2WiringCalldata(address(r.token)));
        vm.stopBroadcast();
    }
}
