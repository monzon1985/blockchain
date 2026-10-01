// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";
import {MockSequencerFeed} from "../mocks/MockSequencerFeed.sol";
import {Test} from "forge-std/Test.sol";

/// @notice The scriptable mocks behave like the Chainlink contracts they stand in for.
contract MocksTest is Test {
    MockAggregatorV3 internal feed;
    MockSequencerFeed internal sequencer;

    function setUp() public {
        vm.warp(1_750_000_000);
        feed = new MockAggregatorV3(8, "ETH / USD");
        sequencer = new MockSequencerFeed(1_700_000_000);
    }

    function test_Metadata() public view {
        assertEq(feed.decimals(), 8);
        assertEq(feed.description(), "ETH / USD");
        assertEq(feed.version(), 4);
        assertEq(sequencer.decimals(), 0);
    }

    function test_RoundHistory_IsKept() public {
        feed.pushAnswer(2000e8);
        vm.warp(block.timestamp + 60);
        feed.pushAnswerWithAge(2100e8, 30);
        (uint80 id, int256 answer,, uint256 updatedAt, uint80 answeredIn) = feed.getRoundData(1);
        assertEq(id, 1);
        assertEq(answer, 2000e8);
        assertEq(updatedAt, 1_750_000_000);
        assertEq(answeredIn, 1);
        (id, answer,, updatedAt,) = feed.latestRoundData();
        assertEq(id, 2);
        assertEq(answer, 2100e8);
        assertEq(updatedAt, 1_750_000_030);
    }

    function test_ScriptedFailures() public {
        feed.pushFutureAnswer(1, 99);
        (,,, uint256 updatedAt,) = feed.latestRoundData();
        assertEq(updatedAt, block.timestamp + 99);
        feed.pushIncompleteRound(1);
        (,,, updatedAt,) = feed.latestRoundData();
        assertEq(updatedAt, 0);
        uint80 id = feed.pushCarriedOverRound(1);
        (,,,, uint80 answeredIn) = feed.latestRoundData();
        assertEq(answeredIn, id - 1);
    }

    function test_UnknownRound_Reverts() public {
        vm.expectRevert(abi.encodeWithSelector(MockAggregatorV3.NoDataPresent.selector, uint80(0)));
        feed.getRoundData(0);
        vm.expectRevert(abi.encodeWithSelector(MockAggregatorV3.NoDataPresent.selector, uint80(1)));
        feed.getRoundData(1);
    }

    function test_Behaviors() public {
        feed.pushAnswer(2000e8);
        feed.setBehavior(MockAggregatorV3.Behavior.Revert);
        vm.expectRevert(MockAggregatorV3.FeedPaused.selector);
        feed.latestRoundData();
        (uint80 id, MockAggregatorV3.RoundData memory raw) = feed.latestRoundRaw();
        assertEq(id, 1);
        assertEq(raw.answer, 2000e8);

        feed.setBehavior(MockAggregatorV3.Behavior.ShortReturn);
        (bool ok, bytes memory data) = address(feed).staticcall(abi.encodeCall(feed.latestRoundData, ()));
        assertTrue(ok);
        assertEq(data.length, 32);
    }

    function test_Sequencer_StatusChanges() public {
        (, int256 answer, uint256 startedAt,,) = sequencer.latestRoundData();
        assertEq(answer, 0);
        assertEq(startedAt, 1_700_000_000);
        sequencer.setDown();
        (, answer, startedAt,,) = sequencer.latestRoundData();
        assertEq(answer, 1);
        assertEq(startedAt, block.timestamp);
        vm.warp(block.timestamp + 10);
        sequencer.flip();
        (, answer, startedAt,,) = sequencer.latestRoundData();
        assertEq(answer, 0);
        assertEq(startedAt, block.timestamp);
        sequencer.flip();
        (, answer,,,) = sequencer.latestRoundData();
        assertEq(answer, 1);
        sequencer.setUp();
        (, answer,,,) = sequencer.latestRoundData();
        assertEq(answer, 0);
        sequencer.setReverts(true);
        vm.expectRevert(MockSequencerFeed.FeedPaused.selector);
        sequencer.latestRoundData();
    }
}
