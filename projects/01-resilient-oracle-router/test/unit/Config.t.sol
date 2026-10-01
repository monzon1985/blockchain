// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {OracleRouter} from "../../src/OracleRouter.sol";
import {IOracleRouter} from "../../src/interfaces/IOracleRouter.sol";
import {IPriceOracle} from "../../src/interfaces/IPriceOracle.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";
import {RouterTestBase} from "../utils/RouterTestBase.sol";

/// @notice Configuration rules: every rejected parameter, the stored layout, events, and delayed reconfiguration.
contract ConfigTest is RouterTestBase {
    enum Mutation {
        ZeroAsset,
        PrimaryWithoutCode,
        SecondaryEqualsPrimary,
        TooManyDecimals,
        ZeroHeartbeat,
        HeartbeatTooLong,
        InvertedBounds,
        MinBelowResolution,
        ZeroDeviationWithSecondary,
        DeviationAbove100Percent,
        DeviationWithoutSecondary,
        HeartbeatWithoutSecondary,
        TwapWindowTooShort,
        TwapWindowTooLong
    }

    struct ConfigCase {
        string name;
        Mutation mutation;
    }

    MockAggregatorV3 internal feed37;
    MockAggregatorV3 internal feed27;

    function setUp() public override {
        super.setUp();
        feed37 = new MockAggregatorV3(37, "37 decimals");
        feed27 = new MockAggregatorV3(27, "27 decimals");
    }

    function fixtureConfig() public pure returns (ConfigCase[] memory cases) {
        cases = new ConfigCase[](14);
        cases[0] = ConfigCase("zero asset", Mutation.ZeroAsset);
        cases[1] = ConfigCase("primary without code", Mutation.PrimaryWithoutCode);
        cases[2] = ConfigCase("secondary equals primary", Mutation.SecondaryEqualsPrimary);
        cases[3] = ConfigCase("37 decimals", Mutation.TooManyDecimals);
        cases[4] = ConfigCase("zero heartbeat", Mutation.ZeroHeartbeat);
        cases[5] = ConfigCase("heartbeat above 2 days", Mutation.HeartbeatTooLong);
        cases[6] = ConfigCase("inverted bounds", Mutation.InvertedBounds);
        cases[7] = ConfigCase("min below one wei", Mutation.MinBelowResolution);
        cases[8] = ConfigCase("zero deviation", Mutation.ZeroDeviationWithSecondary);
        cases[9] = ConfigCase("deviation above 100%", Mutation.DeviationAbove100Percent);
        cases[10] = ConfigCase("deviation without secondary", Mutation.DeviationWithoutSecondary);
        cases[11] = ConfigCase("heartbeat without secondary", Mutation.HeartbeatWithoutSecondary);
        cases[12] = ConfigCase("TWAP window 29:59", Mutation.TwapWindowTooShort);
        cases[13] = ConfigCase("TWAP window above 1 day", Mutation.TwapWindowTooLong);
    }

    /// @notice Each invalid configuration is rejected with its dedicated error, at deployment and on reconfiguration.
    function tableConfigTest(ConfigCase memory config) public {
        (address asset, IOracleRouter.AssetParams memory params, bytes memory revertData) = _mutate(config.mutation);
        IOracleRouter.InitialAsset[] memory assets = new IOracleRouter.InitialAsset[](1);
        assets[0] = IOracleRouter.InitialAsset(asset, params);
        vm.expectRevert(revertData);
        this.deployRouterExternal(address(sequencer), 1 hours, assets);

        _governanceCallReverts(softRouter, abi.encodeCall(IOracleRouter.setAssetConfig, (asset, params)), revertData);
    }

    function test_Constructor_StoresConfigWithCachedDecimals() public view {
        IOracleRouter.AssetConfig memory c = softRouter.getAssetConfig(ASSET);
        assertEq(c.primary.feed, address(primary));
        assertEq(c.primary.decimals, 8);
        assertEq(c.primary.heartbeat, PRIMARY_HEARTBEAT);
        assertEq(c.primary.minAnswer, PRIMARY_MIN);
        assertEq(c.primary.maxAnswer, PRIMARY_MAX);
        assertEq(c.secondary.feed, address(secondary));
        assertEq(c.secondary.decimals, 18);
        assertEq(c.maxDeviationBps, MAX_DEVIATION_BPS);
        assertEq(c.twapWindow, TWAP_WINDOW);
        assertEq(uint256(c.mode), uint256(IOracleRouter.Mode.Soft));
        assertEq(softRouter.sequencerFeed(), address(sequencer));
        assertEq(softRouter.gracePeriod(), 1 hours);
        assertEq(softRouter.authority(), address(manager));
    }

    function test_Constructor_EmitsConfigurationEvents() public {
        IOracleRouter.InitialAsset[] memory assets = new IOracleRouter.InitialAsset[](1);
        assets[0] = IOracleRouter.InitialAsset(ASSET, _params(IOracleRouter.Mode.Strict));
        IOracleRouter.AssetConfig memory expected = strictRouter.getAssetConfig(ASSET);
        vm.expectEmit();
        emit IOracleRouter.SequencerConfigured(address(sequencer), 1 hours);
        vm.expectEmit();
        emit IOracleRouter.AssetConfigured(ASSET, expected);
        new OracleRouter(address(manager), address(sequencer), 1 hours, assets);
    }

    function test_Constructor_RejectsBadSequencerConfig() public {
        IOracleRouter.InitialAsset[] memory none = new IOracleRouter.InitialAsset[](0);
        vm.expectRevert(abi.encodeWithSelector(IOracleRouter.InvalidFeed.selector, address(0xDEAD)));
        this.deployRouterExternal(address(0xDEAD), 1 hours, none);
        vm.expectRevert(abi.encodeWithSelector(IOracleRouter.InvalidGracePeriod.selector, 0));
        this.deployRouterExternal(address(sequencer), 0, none);
        vm.expectRevert(abi.encodeWithSelector(IOracleRouter.InvalidGracePeriod.selector, 1 days + 1));
        this.deployRouterExternal(address(sequencer), 1 days + 1, none);
        vm.expectRevert(abi.encodeWithSelector(IOracleRouter.InvalidGracePeriod.selector, 1 days + 1));
        this.deployRouterExternal(address(0), 1 days + 1, none);
        // An empty router is valid: assets can be added later through governance.
        assertEq(this.deployRouterExternal(address(0), 0, none).sequencerFeed(), address(0));
    }

    function test_UnconfiguredAsset_ReadsAsEmptyConfig() public view {
        IOracleRouter.AssetConfig memory c = softRouter.getAssetConfig(address(0xBEEF));
        assertEq(c.primary.feed, address(0));
        assertEq(c.twapWindow, 0);
    }

    function test_ConsultTwap_UnknownAssetReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IOracleRouter.AssetNotConfigured.selector, address(0xBEEF)));
        softRouter.consultTwap(address(0xBEEF), COLLATERAL);
    }

    function test_SetAssetConfig_AddsANewAsset() public {
        address weth2 = address(0xE7E7);
        IOracleRouter.AssetParams memory params = _primaryOnlyParams(IOracleRouter.Mode.Strict);
        _scheduleConfig(softRouter, abi.encodeCall(IOracleRouter.setAssetConfig, (weth2, params)));
        primary.pushAnswer(PRIMARY_PRICE);
        vm.recordLogs();
        vm.prank(governance);
        softRouter.setAssetConfig(weth2, params);
        // No history existed, so no reset event: only the configuration event.
        assertEq(vm.getRecordedLogs().length, 2, "OperationExecuted + AssetConfigured");
        (uint256 price, IPriceOracle.Status status) = softRouter.tryGetPrice(weth2, COLLATERAL);
        assertEq(price, 2000e18);
        assertEq(uint256(status), uint256(IPriceOracle.Status.OK));
    }

    function test_SetSequencerConfig_SwitchesToL1() public {
        _scheduleConfig(softRouter, abi.encodeCall(IOracleRouter.setSequencerConfig, (address(0), 0)));
        vm.expectEmit(address(softRouter));
        emit IOracleRouter.SequencerConfigured(address(0), 0);
        vm.prank(governance);
        softRouter.setSequencerConfig(address(0), 0);
        assertEq(softRouter.sequencerFeed(), address(0));
        sequencer.setDown();
        primary.pushAnswer(PRIMARY_PRICE);
        secondary.pushAnswer(SECONDARY_PRICE);
        _assertQuoteBoth(softRouter, 2000e18, IPriceOracle.Status.OK);
    }

    function test_SetSequencerConfig_RejectsBadValues() public {
        _governanceCallReverts(
            softRouter,
            abi.encodeCall(IOracleRouter.setSequencerConfig, (address(sequencer), 0)),
            abi.encodeWithSelector(IOracleRouter.InvalidGracePeriod.selector, 0)
        );
        _governanceCallReverts(
            softRouter,
            abi.encodeCall(IOracleRouter.setSequencerConfig, (address(0), 1 days + 1)),
            abi.encodeWithSelector(IOracleRouter.InvalidGracePeriod.selector, 1 days + 1)
        );
        _governanceCallReverts(
            softRouter,
            abi.encodeCall(IOracleRouter.setSequencerConfig, (address(0xDEAD), 1 hours)),
            abi.encodeWithSelector(IOracleRouter.InvalidFeed.selector, address(0xDEAD))
        );
    }

    function test_ForceStrict_UnknownAssetReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IOracleRouter.AssetNotConfigured.selector, address(0xBEEF)));
        softRouter.forceStrict(address(0xBEEF));
    }

    // ------------------------------------------------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------------------------------------------------

    function _mutate(Mutation mutation)
        internal
        view
        returns (address asset, IOracleRouter.AssetParams memory p, bytes memory revertData)
    {
        asset = address(0xC0FFEE);
        p = _params(IOracleRouter.Mode.Soft);
        if (mutation == Mutation.ZeroAsset) {
            asset = address(0);
            revertData = abi.encodeWithSelector(IOracleRouter.InvalidAsset.selector);
        } else if (mutation == Mutation.PrimaryWithoutCode) {
            p.primary.feed = address(0x1234);
            revertData = abi.encodeWithSelector(IOracleRouter.InvalidFeed.selector, address(0x1234));
        } else if (mutation == Mutation.SecondaryEqualsPrimary) {
            p.secondary.feed = address(primary);
            revertData = abi.encodeWithSelector(IOracleRouter.InvalidFeed.selector, address(primary));
        } else if (mutation == Mutation.TooManyDecimals) {
            p.primary.feed = address(feed37);
            revertData = abi.encodeWithSelector(IOracleRouter.UnsupportedDecimals.selector, address(feed37), 37);
        } else if (mutation == Mutation.ZeroHeartbeat) {
            p.primary.heartbeat = 0;
            revertData = abi.encodeWithSelector(IOracleRouter.InvalidHeartbeat.selector, address(primary), 0);
        } else if (mutation == Mutation.HeartbeatTooLong) {
            p.secondary.heartbeat = 2 days + 1;
            revertData = abi.encodeWithSelector(IOracleRouter.InvalidHeartbeat.selector, address(secondary), 2 days + 1);
        } else if (mutation == Mutation.InvertedBounds) {
            p.primary.minAnswer = PRIMARY_MAX + 1;
            revertData = abi.encodeWithSelector(
                IOracleRouter.InvalidBounds.selector, address(primary), PRIMARY_MAX + 1, PRIMARY_MAX
            );
        } else if (mutation == Mutation.MinBelowResolution) {
            // A 27-decimal answer below 1e9 would normalize to zero wei.
            p.primary = IOracleRouter.FeedParams(address(feed27), 1 hours, 1e9 - 1, 1e40);
            revertData = abi.encodeWithSelector(IOracleRouter.InvalidBounds.selector, address(feed27), 1e9 - 1, 1e40);
        } else if (mutation == Mutation.ZeroDeviationWithSecondary) {
            p.maxDeviationBps = 0;
            revertData = abi.encodeWithSelector(IOracleRouter.InvalidDeviation.selector, 0);
        } else if (mutation == Mutation.DeviationAbove100Percent) {
            p.maxDeviationBps = 10_001;
            revertData = abi.encodeWithSelector(IOracleRouter.InvalidDeviation.selector, 10_001);
        } else if (mutation == Mutation.DeviationWithoutSecondary) {
            p.secondary = IOracleRouter.FeedParams(address(0), 0, 0, 0);
            revertData = abi.encodeWithSelector(IOracleRouter.InvalidDeviation.selector, MAX_DEVIATION_BPS);
        } else if (mutation == Mutation.HeartbeatWithoutSecondary) {
            p.secondary.feed = address(0);
            p.maxDeviationBps = 0;
            revertData = abi.encodeWithSelector(IOracleRouter.UnusedSecondaryParams.selector);
        } else if (mutation == Mutation.TwapWindowTooShort) {
            p.twapWindow = 30 minutes - 1;
            revertData = abi.encodeWithSelector(IOracleRouter.InvalidTwapWindow.selector, 30 minutes - 1);
        } else {
            p.twapWindow = 1 days + 1;
            revertData = abi.encodeWithSelector(IOracleRouter.InvalidTwapWindow.selector, 1 days + 1);
        }
    }
}
