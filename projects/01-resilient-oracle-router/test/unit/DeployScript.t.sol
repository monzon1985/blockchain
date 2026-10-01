// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {DeployOracleRouter} from "../../script/DeployOracleRouter.s.sol";
import {OracleRouterGovernance} from "../../script/OracleRouterGovernance.sol";
import {OracleRouter} from "../../src/OracleRouter.sol";
import {IOracleRouter} from "../../src/interfaces/IOracleRouter.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Test} from "forge-std/Test.sol";

/// @notice The deployment script parses its JSON config and produces the governed layout end to end.
contract DeployScriptTest is Test {
    string internal constant CONFIG = "script/config/assets.example.json";
    DeployOracleRouter internal script;

    function setUp() public {
        script = new DeployOracleRouter();
    }

    function test_LoadConfig_ParsesExample() public view {
        (uint32 grace, IOracleRouter.InitialAsset[] memory assets) = script.loadConfig(vm.readFile(CONFIG));
        assertEq(grace, 3600);
        assertEq(assets.length, 2);
        assertEq(assets[0].asset, address(0xA1));
        assertEq(uint256(assets[0].params.mode), uint256(IOracleRouter.Mode.Strict));
        assertEq(assets[0].params.primary.feed, address(0xF1));
        assertEq(assets[0].params.primary.minAnswer, 100e8);
        assertEq(assets[0].params.secondary.maxAnswer, 100_000e18);
        assertEq(assets[0].params.maxDeviationBps, 300);
        assertEq(assets[1].params.secondary.feed, address(0));
        assertEq(uint256(assets[1].params.mode), uint256(IOracleRouter.Mode.Soft));
        assertEq(assets[1].params.twapWindow, 1800);
    }

    function test_LoadConfig_RejectsEmptyAndUnknownMode() public {
        vm.expectRevert(DeployOracleRouter.NoAssets.selector);
        script.loadConfig('{"gracePeriod": 3600, "assets": []}');
        string memory json = vm.replace(vm.readFile(CONFIG), '"strict"', '"lenient"');
        vm.expectRevert(abi.encodeWithSelector(DeployOracleRouter.UnknownMode.selector, "lenient"));
        script.loadConfig(json);
    }

    /// @notice A heartbeat of 2^32 seconds must not silently become 0 (or any other truncated value).
    function test_LoadConfig_RejectsOutOfRangeIntegers() public {
        string memory json = vm.replace(vm.readFile(CONFIG), '"heartbeat": 3600', '"heartbeat": 4294967296');
        vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 32, 4_294_967_296));
        script.loadConfig(json);
    }

    function test_Run_DeploysGovernedRouter() public {
        // Place feed code at the example's placeholder addresses.
        vm.etch(address(0xF1), address(new MockAggregatorV3(8, "p")).code);
        vm.etch(address(0xF2), address(new MockAggregatorV3(18, "s")).code);
        vm.etch(address(0xF3), address(new MockAggregatorV3(18, "p2")).code);
        address governance = makeAddr("governance");
        address guardian = makeAddr("guardian");
        vm.setEnv("GOVERNANCE", vm.toString(governance));
        vm.setEnv("GUARDIAN", vm.toString(guardian));
        vm.setEnv("SEQUENCER_FEED", vm.toString(address(0)));
        vm.setEnv("ROUTER_CONFIG", CONFIG);

        (AccessManager manager, OracleRouter router) = script.run();

        assertEq(router.authority(), address(manager));
        assertEq(router.getAssetConfig(address(0xA1)).primary.decimals, 8);
        assertEq(router.getAssetConfig(address(0xA2)).twapWindow, 1800);
        assertEq(router.sequencerFeed(), address(0));
        (bool isAdmin, uint32 delay) = manager.hasRole(manager.ADMIN_ROLE(), governance);
        assertTrue(isAdmin);
        assertEq(delay, 2 days);
        (bool isGuardian,) = manager.hasRole(OracleRouterGovernance.GUARDIAN_ROLE, guardian);
        assertTrue(isGuardian);
    }
}
