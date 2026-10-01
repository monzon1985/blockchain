// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {OracleRouter} from "../src/OracleRouter.sol";
import {IOracleRouter} from "../src/interfaces/IOracleRouter.sol";
import {OracleRouterGovernance} from "./OracleRouterGovernance.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

/// @title DeployOracleRouter
/// @notice Deploys an AccessManager and a router, configures the initial assets from a JSON file and hands control to
///         governance (see `OracleRouterGovernance`). Keystore-based: no private key ever appears in the environment.
/// @dev forge script script/DeployOracleRouter.s.sol --rpc-url <url> --account <keystore> --sender <address> --broadcast
///      Environment: GOVERNANCE, GUARDIAN (required); SEQUENCER_FEED (optional, empty on L1);
///      ROUTER_CONFIG (optional, default script/config/assets.example.json).
contract DeployOracleRouter is Script {
    /// @notice The config file lists no asset.
    error NoAssets();

    /// @notice An asset's `mode` is neither "strict" nor "soft".
    /// @param mode The rejected value.
    error UnknownMode(string mode);

    /// @notice Deploys and wires everything.
    /// @return manager The AccessManager (admin: governance, with the 2-day delay).
    /// @return router The router.
    function run() external returns (AccessManager manager, OracleRouter router) {
        address governance = vm.envAddress("GOVERNANCE");
        address guardian = vm.envAddress("GUARDIAN");
        address sequencerFeed = vm.envOr("SEQUENCER_FEED", address(0));
        string memory json = vm.readFile(vm.envOr("ROUTER_CONFIG", string("script/config/assets.example.json")));
        (uint32 gracePeriod, IOracleRouter.InitialAsset[] memory assets) = loadConfig(json);

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        manager = new AccessManager(deployer);
        router =
            new OracleRouter(address(manager), sequencerFeed, sequencerFeed == address(0) ? 0 : gracePeriod, assets);
        OracleRouterGovernance.wire(manager, router, governance, guardian, deployer);
        vm.stopBroadcast();

        console.log("AccessManager:", address(manager));
        console.log("OracleRouter: ", address(router));
    }

    /// @notice Parses the deployment JSON (see script/config/assets.example.json for the schema). Integers that do not
    ///         fit their field revert (`SafeCast`) instead of being silently truncated.
    /// @param json The file content.
    /// @return gracePeriod Sequencer grace period in seconds.
    /// @return assets The initial assets.
    function loadConfig(string memory json)
        public
        view
        returns (uint32 gracePeriod, IOracleRouter.InitialAsset[] memory assets)
    {
        gracePeriod = SafeCast.toUint32(vm.parseJsonUint(json, ".gracePeriod"));
        uint256 count;
        while (vm.keyExistsJson(json, string.concat(".assets[", vm.toString(count), "]"))) ++count;
        require(count != 0, NoAssets());
        assets = new IOracleRouter.InitialAsset[](count);
        for (uint256 i; i < count; ++i) {
            string memory key = string.concat(".assets[", vm.toString(i), "]");
            assets[i] = IOracleRouter.InitialAsset({
                asset: vm.parseJsonAddress(json, string.concat(key, ".asset")),
                params: IOracleRouter.AssetParams({
                    primary: _feed(json, string.concat(key, ".primary")),
                    secondary: _feed(json, string.concat(key, ".secondary")),
                    maxDeviationBps: SafeCast.toUint16(vm.parseJsonUint(json, string.concat(key, ".maxDeviationBps"))),
                    twapWindow: SafeCast.toUint32(vm.parseJsonUint(json, string.concat(key, ".twapWindow"))),
                    mode: _mode(vm.parseJsonString(json, string.concat(key, ".mode")))
                })
            });
        }
    }

    function _feed(string memory json, string memory key) internal pure returns (IOracleRouter.FeedParams memory) {
        return IOracleRouter.FeedParams({
            feed: vm.parseJsonAddress(json, string.concat(key, ".feed")),
            heartbeat: SafeCast.toUint32(vm.parseJsonUint(json, string.concat(key, ".heartbeat"))),
            minAnswer: SafeCast.toUint192(vm.parseJsonUint(json, string.concat(key, ".minAnswer"))),
            maxAnswer: SafeCast.toUint192(vm.parseJsonUint(json, string.concat(key, ".maxAnswer")))
        });
    }

    function _mode(string memory mode) internal pure returns (IOracleRouter.Mode) {
        bytes32 h = keccak256(bytes(mode));
        if (h == keccak256("strict")) return IOracleRouter.Mode.Strict;
        if (h == keccak256("soft")) return IOracleRouter.Mode.Soft;
        revert UnknownMode(mode);
    }
}
