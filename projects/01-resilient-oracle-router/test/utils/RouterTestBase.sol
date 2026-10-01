// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {OracleRouter} from "../../src/OracleRouter.sol";
import {IOracleRouter} from "../../src/interfaces/IOracleRouter.sol";
import {IPriceOracle} from "../../src/interfaces/IPriceOracle.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";
import {MockSequencerFeed} from "../mocks/MockSequencerFeed.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Shared fixture: an ETH-like asset priced by an 8-decimal primary (1 h heartbeat) and cross-checked by an
///         18-decimal secondary (24 h heartbeat), a healthy L2 sequencer, and one router per mode on the same feeds.
///         The test contract is the AccessManager admin without delay; production wiring is tested in Governance.t.sol.
abstract contract RouterTestBase is Test {
    uint256 internal constant T0 = 1_750_000_000;

    uint32 internal constant PRIMARY_HEARTBEAT = 1 hours;
    uint32 internal constant SECONDARY_HEARTBEAT = 1 days;
    uint16 internal constant MAX_DEVIATION_BPS = 300;
    uint32 internal constant TWAP_WINDOW = 1 hours;

    uint192 internal constant PRIMARY_MIN = 100e8;
    uint192 internal constant PRIMARY_MAX = 100_000e8;
    uint192 internal constant SECONDARY_MIN = 100e18;
    uint192 internal constant SECONDARY_MAX = 100_000e18;

    int256 internal constant PRIMARY_PRICE = 2000e8;
    int256 internal constant SECONDARY_PRICE = 2001e18;

    address internal constant ASSET = address(0xA55E7);

    uint64 internal constant TEST_CONFIG_ROLE = 1;
    address internal governance = makeAddr("governance");

    IPriceOracle.Intent internal constant COLLATERAL = IPriceOracle.Intent.Collateral;
    IPriceOracle.Intent internal constant DEBT = IPriceOracle.Intent.Debt;

    AccessManager internal manager;
    MockSequencerFeed internal sequencer;
    MockAggregatorV3 internal primary;
    MockAggregatorV3 internal secondary;

    /// @dev Strict and soft routers over the same feeds, sequencer and asset.
    OracleRouter internal strictRouter;
    OracleRouter internal softRouter;

    function setUp() public virtual {
        vm.warp(T0);
        manager = new AccessManager(address(this));
        sequencer = new MockSequencerFeed(T0 - 30 days);
        primary = new MockAggregatorV3(8, "ETH / USD");
        secondary = new MockAggregatorV3(18, "ETH / USD (witness)");
        primary.pushAnswer(PRIMARY_PRICE);
        secondary.pushAnswer(SECONDARY_PRICE);
        strictRouter = _deployRouter(_params(IOracleRouter.Mode.Strict));
        softRouter = _deployRouter(_params(IOracleRouter.Mode.Soft));
    }

    // ------------------------------------------------------------------------------------------------------------
    // Builders
    // ------------------------------------------------------------------------------------------------------------

    function _params(IOracleRouter.Mode mode) internal view returns (IOracleRouter.AssetParams memory) {
        return IOracleRouter.AssetParams({
            primary: IOracleRouter.FeedParams(address(primary), PRIMARY_HEARTBEAT, PRIMARY_MIN, PRIMARY_MAX),
            secondary: IOracleRouter.FeedParams(address(secondary), SECONDARY_HEARTBEAT, SECONDARY_MIN, SECONDARY_MAX),
            maxDeviationBps: MAX_DEVIATION_BPS,
            twapWindow: TWAP_WINDOW,
            mode: mode
        });
    }

    function _primaryOnlyParams(IOracleRouter.Mode mode) internal view returns (IOracleRouter.AssetParams memory p) {
        p = _params(mode);
        p.secondary = IOracleRouter.FeedParams(address(0), 0, 0, 0);
        p.maxDeviationBps = 0;
    }

    function _deployRouter(IOracleRouter.AssetParams memory params) internal returns (OracleRouter) {
        return _deployRouter(address(sequencer), params);
    }

    function _deployRouter(address sequencerFeed, IOracleRouter.AssetParams memory params)
        internal
        returns (OracleRouter)
    {
        IOracleRouter.InitialAsset[] memory assets = new IOracleRouter.InitialAsset[](1);
        assets[0] = IOracleRouter.InitialAsset(ASSET, params);
        return new OracleRouter(address(manager), sequencerFeed, sequencerFeed == address(0) ? 0 : 1 hours, assets);
    }

    function _router(IOracleRouter.Mode mode) internal view returns (OracleRouter) {
        return mode == IOracleRouter.Mode.Strict ? strictRouter : softRouter;
    }

    // ------------------------------------------------------------------------------------------------------------
    // Scenario helpers
    // ------------------------------------------------------------------------------------------------------------

    /// @dev Records one observation on both routers.
    function _observeBoth() internal {
        strictRouter.recordObservation(ASSET);
        softRouter.recordObservation(ASSET);
    }

    /// @dev Builds `minutes_` minutes of history: the primary moves every 10 minutes along `_pathPrice`, the secondary
    ///      follows every 30 minutes, keepers record every 5 minutes on both routers. Ends at the current time + span.
    function _buildHistory(uint256 minutes_) internal {
        for (uint256 m = 0; m <= minutes_; m += 5) {
            if (m != 0) vm.warp(block.timestamp + 5 minutes);
            if (m % 10 == 0) primary.pushAnswer(_pathPrice(m / 10));
            if (m % 30 == 0) secondary.pushAnswer(_pathPrice(m / 10) * 1e10);
            _observeBoth();
        }
    }

    /// @dev A deterministic, bounded price path around $2,000 (8 decimals).
    function _pathPrice(uint256 step) internal pure returns (int256) {
        int256[8] memory deltas = [int256(0), 12e8, -7e8, 18e8, 3e8, -15e8, 9e8, -4e8];
        return 2000e8 + deltas[step % 8] + int256(step % 5) * 1e8;
    }

    /// @dev 8-decimal answer to 1e18.
    function _wad8(int256 answer) internal pure returns (uint256) {
        return uint256(answer) * 1e10;
    }

    function _assertQuote(
        OracleRouter router,
        IPriceOracle.Intent intent,
        uint256 expectedPrice,
        IPriceOracle.Status expectedStatus
    ) internal view {
        (uint256 price, IPriceOracle.Status status) = router.tryGetPrice(ASSET, intent);
        assertEq(uint256(status), uint256(expectedStatus), "status");
        assertEq(price, expectedPrice, "price");
    }

    function _assertQuoteBoth(OracleRouter router, uint256 expectedPrice, IPriceOracle.Status expectedStatus)
        internal
        view
    {
        _assertQuote(router, COLLATERAL, expectedPrice, expectedStatus);
        _assertQuote(router, DEBT, expectedPrice, expectedStatus);
    }

    /// @dev Prepares a configuration call the way production does: `governance` holds a role with the mandatory
    ///      2-day execution delay and schedules the call on the AccessManager; then time moves past the delay.
    function _scheduleConfig(OracleRouter router, bytes memory data) internal {
        if (manager.getTargetFunctionRole(address(router), bytes4(data)) != TEST_CONFIG_ROLE) {
            bytes4[] memory selectors = new bytes4[](1);
            selectors[0] = bytes4(data);
            manager.setTargetFunctionRole(address(router), selectors, TEST_CONFIG_ROLE);
        }
        (bool isMember,) = manager.hasRole(TEST_CONFIG_ROLE, governance);
        if (!isMember) manager.grantRole(TEST_CONFIG_ROLE, governance, router.CONFIG_DELAY());
        vm.prank(governance);
        manager.schedule(address(router), data, 0);
        vm.warp(block.timestamp + router.CONFIG_DELAY());
    }

    /// @dev Schedules, waits and executes a configuration call (governance calls the router directly).
    function _governanceCall(OracleRouter router, bytes memory data) internal {
        _scheduleConfig(router, data);
        vm.prank(governance);
        (bool ok, bytes memory returnData) = address(router).call(data);
        if (!ok) {
            // Safety: re-throws the router's revert data unchanged so `vm.expectRevert` can match it.
            assembly ("memory-safe") {
                revert(add(returnData, 0x20), mload(returnData))
            }
        }
    }

    /// @dev Schedules a configuration call, then expects the router to revert with `revertData` when governance
    ///      executes it. `vm.expectRevert` must directly precede the router call: placed before `_governanceCall` it
    ///      would be consumed by the first AccessManager call instead.
    function _governanceCallReverts(OracleRouter router, bytes memory data, bytes memory revertData) internal {
        _scheduleConfig(router, data);
        vm.prank(governance);
        vm.expectRevert(revertData);
        (bool ok,) = address(router).call(data);
        assertTrue(ok, "expectRevert matched");
    }

    /// @dev External deployment entry point, so `vm.expectRevert` can target a constructor revert: an inline `new`
    ///      is lowered to a `deployCode` cheatcode whose revert would end the calling test early.
    function deployRouterExternal(address sequencerFeed, uint32 grace, IOracleRouter.InitialAsset[] memory assets)
        external
        returns (OracleRouter)
    {
        return new OracleRouter(address(manager), sequencerFeed, grace, assets);
    }

    function _expectGetPriceRevert(OracleRouter router, bytes memory revertData) internal {
        vm.expectRevert(revertData);
        router.getPrice(ASSET, COLLATERAL);
        vm.expectRevert(revertData);
        router.getPrice(ASSET, DEBT);
    }
}
