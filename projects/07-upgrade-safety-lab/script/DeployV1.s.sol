// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {SubscriptionRegistryV1} from "../src/uups/v1/SubscriptionRegistryV1.sol";
import {LabScript} from "./LabScript.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice Step 1: deploys the legacy V1 (OZ 4.9.6) behind an ERC-1967 proxy and writes the storage sentinels
///         through its API (two plans, one subscription). Records addresses in deployments/<chainId>/v1.json.
/// @dev forge script script/DeployV1.s.sol --rpc-url $RPC --broadcast \
///        --keystore $KEYSTORE --password-file $PASSWORD_FILE --sender $DEPLOYER
contract DeployV1 is LabScript {
    function run() external {
        address deployer = msg.sender;
        vm.startBroadcast();
        SubscriptionRegistryV1 impl = new SubscriptionRegistryV1();
        ERC1967Proxy proxy =
            new ERC1967Proxy(address(impl), abi.encodeCall(SubscriptionRegistryV1.initialize, (deployer)));
        SubscriptionRegistryV1 reg = SubscriptionRegistryV1(address(proxy));
        reg.createPlan(30 days);
        reg.createPlan(365 days);
        reg.subscribe(2);
        vm.stopBroadcast();

        string memory obj = "v1";
        vm.serializeAddress(obj, "proxy", address(proxy));
        vm.serializeAddress(obj, "implementation", address(impl));
        string memory json = vm.serializeAddress(obj, "owner", deployer);
        vm.createDir(_dir(), true);
        vm.writeJson(json, _file("v1"));
    }
}

/// @notice Reads the sentinels back from the chain (no transaction) and records them in sentinels.json, so every
///         later verification compares against what is really stored.
contract RecordSentinels is LabScript {
    function run() external {
        address proxy = _address("v1", "proxy");
        address owner = _address("v1", "owner");
        SubscriptionRegistryV1 reg = SubscriptionRegistryV1(proxy);
        (uint64 duration, bool active) = reg.plan(2);
        (uint256 planId, uint64 expiresAt) = reg.subscriptionOf(owner);
        require(planId == 2 && expiresAt > 0, "sentinel subscription missing");

        string memory obj = "sentinels";
        vm.serializeUint(obj, "planCount", reg.planCount());
        vm.serializeUint(obj, "plan2Duration", duration);
        vm.serializeUint(obj, "plan2Active", active ? 1 : 0);
        vm.serializeUint(obj, "subscriptionPlanId", planId);
        vm.serializeUint(obj, "subscriptionExpiresAt", expiresAt);
        vm.serializeUint(obj, "totalSubscriptions", reg.totalSubscriptions());
        vm.serializeUint(obj, "slot201", uint256(vm.load(proxy, bytes32(uint256(201)))));
        string memory json = vm.serializeUint(
            obj, "subscriptionSlot", uint256(vm.load(proxy, keccak256(abi.encode(owner, uint256(203)))))
        );
        vm.writeJson(json, _file("sentinels"));
    }
}
