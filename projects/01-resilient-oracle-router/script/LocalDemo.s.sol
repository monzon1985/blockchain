// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {MockAggregatorV3} from "../test/mocks/MockAggregatorV3.sol";
import {MockSequencerFeed} from "../test/mocks/MockSequencerFeed.sol";
import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

/// @title DeployDemoFeeds
/// @notice First step of the local anvil demo (script/local-demo.sh): deploys scriptable feeds and a sequencer-uptime
///         feed, then writes the JSON config that the production deployment script consumes. Local chains only.
contract DeployDemoFeeds is Script {
    /// @notice The demo refuses to run anywhere but a local chain.
    /// @param chainId The chain it was pointed at.
    error NotALocalChain(uint256 chainId);

    /// @notice Token address used for the demo asset (no token contract is needed to price it).
    address public constant DEMO_ASSET = address(0xE7E7);

    /// @notice Where the generated config is written (git-ignored).
    string public constant CONFIG_PATH = "demo-out/config.json";

    /// @notice Deploys the feeds and writes the config.
    function run() external {
        require(block.chainid == 31_337, NotALocalChain(block.chainid));
        vm.startBroadcast();
        MockAggregatorV3 primary = new MockAggregatorV3(8, "ETH / USD (demo primary)");
        MockAggregatorV3 secondary = new MockAggregatorV3(18, "ETH / USD (demo witness)");
        MockSequencerFeed sequencer = new MockSequencerFeed(block.timestamp - 2 hours);
        primary.pushAnswer(2000e8);
        secondary.pushAnswer(2000e18);
        vm.stopBroadcast();

        // Same schema as script/config/assets.example.json: one soft-mode asset, 1 h TWAP window, 3 % breaker.
        string memory config = string.concat(
            '{"gracePeriod":3600,"assets":[{"asset":"',
            vm.toString(DEMO_ASSET),
            '","mode":"soft","maxDeviationBps":300,"twapWindow":3600,"primary":{"feed":"',
            vm.toString(address(primary)),
            '","heartbeat":3600,"minAnswer":"10000000000","maxAnswer":"10000000000000"},"secondary":{"feed":"',
            vm.toString(address(secondary)),
            '","heartbeat":86400,"minAnswer":"100000000000000000000","maxAnswer":"100000000000000000000000"}}]}'
        );
        vm.writeFile(CONFIG_PATH, config);

        console.log("PRIMARY=%s", address(primary));
        console.log("SECONDARY=%s", address(secondary));
        console.log("SEQUENCER=%s", address(sequencer));
        console.log("ASSET=%s", DEMO_ASSET);
    }
}
