// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.37;

import {Script, console2} from "forge-std/Script.sol";

import {AMMFactory} from "../src/AMMFactory.sol";
import {AMMRouter} from "../src/AMMRouter.sol";

/// @notice Deploys the core protocol (factory + router). Keystore-based, no raw keys:
///
///   forge script script/Deploy.s.sol --rpc-url $RPC_URL --account <keystore-name> --broadcast
///
/// The factory owner (who can only set the protocol-fee recipient) defaults to the broadcaster and can be
/// overridden with AMM_FACTORY_OWNER (for example a multisig).
contract Deploy is Script {
    function run() external virtual returns (AMMFactory factory, AMMRouter router) {
        vm.startBroadcast();
        (, address broadcaster,) = vm.readCallers();
        (factory, router) = _deployCore(vm.envOr("AMM_FACTORY_OWNER", broadcaster));
        vm.stopBroadcast();
        console2.log("AMMFactory:", address(factory));
        console2.log("AMMRouter: ", address(router));
    }

    function _deployCore(address owner) internal returns (AMMFactory factory, AMMRouter router) {
        factory = new AMMFactory(owner);
        router = new AMMRouter(address(factory));
    }
}
