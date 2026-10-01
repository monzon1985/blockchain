// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {SubscriptionRegistryV3} from "../src/uups/v3/SubscriptionRegistryV3.sol";
import {IUUPS, LabScript} from "./LabScript.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Payment token for the local demo only (fixed supply minted to the deployer).
contract DemoUSD is ERC20 {
    constructor(address holder) ERC20("Demo USD", "dUSD") {
        _mint(holder, 1_000_000e18);
    }
}

/// @notice Step 3a: deploys the V3 implementation and schedules the upgrade on the AccessManager (2-day delay).
contract ScheduleV3Upgrade is LabScript {
    function run() external {
        address proxy = _address("v1", "proxy");
        AccessManager manager = AccessManager(_address("v2", "manager"));

        vm.startBroadcast();
        SubscriptionRegistryV3 v3 = new SubscriptionRegistryV3();
        bytes memory data = abi.encodeCall(IUUPS.upgradeToAndCall, (address(v3), ""));
        (bytes32 operationId,) = manager.schedule(proxy, data, 0);
        vm.stopBroadcast();

        string memory obj = "v3schedule";
        vm.serializeAddress(obj, "implementation", address(v3));
        vm.serializeBytes32(obj, "operationId", operationId);
        string memory json = vm.serializeUint(obj, "readyAt", manager.getSchedule(operationId));
        vm.writeJson(json, _file("v3-schedule"));
    }
}

/// @notice The cancel path: the guardian withdraws a scheduled upgrade before it becomes executable.
contract CancelV3Upgrade is LabScript {
    error StillScheduled(bytes32 operationId, uint48 timepoint);

    function run() external {
        address proxy = _address("v1", "proxy");
        AccessManager manager = AccessManager(_address("v2", "manager"));
        address v3 = _address("v3-schedule", "implementation");
        bytes memory data = abi.encodeCall(IUUPS.upgradeToAndCall, (v3, ""));
        bytes32 operationId = manager.hashOperation(msg.sender, proxy, data);

        vm.startBroadcast();
        manager.cancel(msg.sender, proxy, data);
        vm.stopBroadcast();

        uint48 timepoint = manager.getSchedule(operationId);
        if (timepoint != 0) revert StillScheduled(operationId, timepoint);
    }
}

/// @notice Step 3b: once the delay has elapsed, executes the scheduled upgrade and enables paid tiers.
contract ExecuteV3Upgrade is LabScript {
    function run() external {
        address deployer = msg.sender;
        address proxy = _address("v1", "proxy");
        AccessManager manager = AccessManager(_address("v2", "manager"));
        address v3 = _address("v3-schedule", "implementation");

        vm.startBroadcast();
        manager.execute(proxy, abi.encodeCall(IUUPS.upgradeToAndCall, (v3, "")));
        DemoUSD token = new DemoUSD(deployer);
        SubscriptionRegistryV3(proxy).initializeV3(token, deployer);
        vm.stopBroadcast();

        string memory obj = "v3";
        vm.serializeAddress(obj, "implementation", v3);
        string memory json = vm.serializeAddress(obj, "paymentToken", address(token));
        vm.writeJson(json, _file("v3"));
    }
}
