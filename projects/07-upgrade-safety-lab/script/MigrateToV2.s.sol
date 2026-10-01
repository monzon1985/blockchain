// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {SubscriptionRegistryBridge} from "../src/uups/bridge/SubscriptionRegistryBridge.sol";
import {SubscriptionRegistryV1} from "../src/uups/v1/SubscriptionRegistryV1.sol";
import {SubscriptionRegistryV2} from "../src/uups/v2/SubscriptionRegistryV2.sol";
import {IUUPS, LabScript} from "./LabScript.sol";
import {UpgradeGovernance} from "./UpgradeGovernance.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";

/// @notice Step 2a of the safe OZ 4.x -> 5.x migration: V1 -> bridge, with `migrateFromV4` in the same transaction.
/// @dev In production steps 2a and 2b are one multisig batch (no maintenance window). The demo broadcasts them
///      separately so that the intermediate bridge state is verified on-chain (`VerifyDeployment`, stage "bridge").
contract MigrateToBridge is LabScript {
    function run() external {
        address proxy = _address("v1", "proxy");

        vm.startBroadcast();
        SubscriptionRegistryBridge bridge = new SubscriptionRegistryBridge();
        SubscriptionRegistryV1(proxy)
            .upgradeToAndCall(address(bridge), abi.encodeCall(SubscriptionRegistryBridge.migrateFromV4, ()));
        vm.stopBroadcast();

        string memory json = vm.serializeAddress("bridge", "implementation", address(bridge));
        vm.writeJson(json, _file("bridge"));
    }
}

/// @notice Step 2b: deploys the AccessManager that gates every upgrade from V2 on (`UpgradeGovernance`: delayed
///         UPGRADER, guardian cancel path, ADMIN itself delayed), then bridge -> V2 with `initializeV2(manager)`.
/// @dev In this local demo one keystore holds every role. In production the ADMIN, UPGRADER and GUARDIAN roles
///      belong to different multisigs (see the README, "Roles and trust assumptions").
contract MigrateToV2 is LabScript {
    function run() external {
        address deployer = msg.sender;
        address proxy = _address("v1", "proxy");

        vm.startBroadcast();
        AccessManager manager = new AccessManager(deployer);
        bytes4[] memory upgradeSelectors = new bytes4[](1);
        upgradeSelectors[0] = IUUPS.upgradeToAndCall.selector;
        UpgradeGovernance.configure(manager, proxy, upgradeSelectors, deployer, deployer, deployer);

        SubscriptionRegistryV2 v2 = new SubscriptionRegistryV2();
        IUUPS(proxy)
            .upgradeToAndCall(address(v2), abi.encodeCall(SubscriptionRegistryV2.initializeV2, (address(manager))));
        vm.stopBroadcast();

        string memory obj = "v2";
        vm.serializeAddress(obj, "manager", address(manager));
        string memory json = vm.serializeAddress(obj, "implementation", address(v2));
        vm.writeJson(json, _file("v2"));
    }
}
