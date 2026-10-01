// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {OracleRouter} from "../../src/OracleRouter.sol";
import {IOracleRouter} from "../../src/interfaces/IOracleRouter.sol";
import {IPriceOracle} from "../../src/interfaces/IPriceOracle.sol";
import {RouterTestBase} from "../utils/RouterTestBase.sol";

/// @notice The L2 sequencer-uptime check: down, grace period (with exact boundaries), and every doubtful reading.
///         Sequencer outages are never bridged, so both modes must behave identically even with TWAP history.
contract SequencerTest is RouterTestBase {
    uint256 internal constant GRACE = 1 hours;

    function setUp() public override {
        super.setUp();
        _buildHistory(90);
    }

    function test_Down_BlocksEveryModeAndIntent() public {
        sequencer.setDown();
        _assertBothModes(0, IPriceOracle.Status.SEQUENCER_DOWN);
        _expectGetPriceRevert(
            strictRouter,
            abi.encodeWithSelector(IOracleRouter.SequencerDown.selector, address(sequencer), int256(1), block.timestamp)
        );
        _expectGetPriceRevert(
            softRouter,
            abi.encodeWithSelector(IOracleRouter.SequencerDown.selector, address(sequencer), int256(1), block.timestamp)
        );
    }

    function test_Down_BlocksObservations() public {
        sequencer.setDown();
        vm.warp(block.timestamp + 5 minutes);
        vm.expectRevert(
            abi.encodeWithSelector(IOracleRouter.PriceNotObservable.selector, ASSET, IPriceOracle.Status.SEQUENCER_DOWN)
        );
        softRouter.recordObservation(ASSET);
    }

    function test_GracePeriod_StartsWhenSequencerComesBack() public {
        sequencer.setDown();
        vm.warp(block.timestamp + 2 hours);
        sequencer.setUp();
        uint256 upAt = block.timestamp;
        primary.pushAnswer(PRIMARY_PRICE);
        _assertBothModes(0, IPriceOracle.Status.GRACE_PERIOD);
        _expectGetPriceRevert(
            strictRouter, abi.encodeWithSelector(IOracleRouter.GracePeriodNotOver.selector, upAt, 0, GRACE)
        );

        vm.warp(upAt + GRACE);
        primary.pushAnswer(PRIMARY_PRICE);
        _assertBothModes(0, IPriceOracle.Status.GRACE_PERIOD);
        _expectGetPriceRevert(
            softRouter, abi.encodeWithSelector(IOracleRouter.GracePeriodNotOver.selector, upAt, GRACE, GRACE)
        );

        vm.warp(upAt + GRACE + 1);
        primary.pushAnswer(PRIMARY_PRICE);
        secondary.pushAnswer(SECONDARY_PRICE);
        _assertBothModes(_wad8(PRIMARY_PRICE), IPriceOracle.Status.OK);
    }

    function test_UninitializedFeed_CountsAsDown() public {
        sequencer.setRaw(0, 0);
        _assertBothModes(0, IPriceOracle.Status.SEQUENCER_DOWN);
        _expectGetPriceRevert(
            strictRouter, abi.encodeWithSelector(IOracleRouter.SequencerDown.selector, address(sequencer), int256(0), 0)
        );
    }

    function test_InvalidAnswer_CountsAsDown() public {
        sequencer.setRaw(2, T0 - 30 days);
        _assertBothModes(0, IPriceOracle.Status.SEQUENCER_DOWN);
        sequencer.setRaw(-1, T0 - 30 days);
        _assertBothModes(0, IPriceOracle.Status.SEQUENCER_DOWN);
    }

    function test_FutureStartedAt_CountsAsJustRecovered() public {
        sequencer.setRaw(0, block.timestamp + 10);
        _assertBothModes(0, IPriceOracle.Status.GRACE_PERIOD);
        _expectGetPriceRevert(
            strictRouter,
            abi.encodeWithSelector(IOracleRouter.GracePeriodNotOver.selector, block.timestamp + 10, 0, GRACE)
        );
    }

    function test_UnreadableFeed_CountsAsDown() public {
        sequencer.setReverts(true);
        _assertBothModes(0, IPriceOracle.Status.SEQUENCER_DOWN);
        _expectGetPriceRevert(
            strictRouter, abi.encodeWithSelector(IOracleRouter.FeedUnavailable.selector, address(sequencer))
        );
    }

    /// @notice The sequencer check runs before the feeds: a down sequencer masks a broken primary.
    function test_SequencerCheckedBeforeFeeds() public {
        sequencer.setDown();
        primary.pushAnswer(0);
        _assertBothModes(0, IPriceOracle.Status.SEQUENCER_DOWN);
    }

    function test_L1Deployment_SkipsTheCheck() public {
        OracleRouter l1 = _deployRouter(address(0), _params(IOracleRouter.Mode.Strict));
        assertEq(l1.sequencerFeed(), address(0));
        assertEq(l1.gracePeriod(), 0);
        sequencer.setDown(); // irrelevant: l1 never reads it
        primary.pushAnswer(PRIMARY_PRICE);
        secondary.pushAnswer(SECONDARY_PRICE);
        _assertQuoteBoth(l1, _wad8(PRIMARY_PRICE), IPriceOracle.Status.OK);
    }

    function _assertBothModes(uint256 expectedPrice, IPriceOracle.Status expectedStatus) internal view {
        _assertQuoteBoth(strictRouter, expectedPrice, expectedStatus);
        _assertQuoteBoth(softRouter, expectedPrice, expectedStatus);
    }
}
