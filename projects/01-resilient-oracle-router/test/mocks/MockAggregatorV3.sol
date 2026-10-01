// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {AggregatorV3Interface} from "../../src/interfaces/AggregatorV3Interface.sol";

/// @title MockAggregatorV3
/// @notice Scriptable Chainlink-style feed with a full round history, used to reproduce every failure mode the router
///         defends against: stale answers, zero and negative answers, future timestamps, incomplete rounds, round
///         regressions (an answer carried over from an earlier round, `answeredInRound < roundId`), a feed that reverts
///         and a feed that returns malformed data.
/// @dev Test infrastructure only: every function is unpermissioned so tests and scripts can drive it freely.
contract MockAggregatorV3 is AggregatorV3Interface {
    /// @notice How `latestRoundData()` responds.
    enum Behavior {
        Normal,
        Revert,
        ShortReturn
    }

    /// @notice One stored round.
    struct RoundData {
        int256 answer;
        uint256 startedAt;
        uint256 updatedAt;
        uint80 answeredInRound;
    }

    /// @notice `getRoundData` was asked for a round that was never written (Chainlink reverts too).
    /// @param roundId The unknown round.
    error NoDataPresent(uint80 roundId);

    /// @notice `latestRoundData` is configured to revert, like a paused or access-controlled proxy.
    error FeedPaused();

    /// @notice A round was written.
    /// @param roundId The new round.
    /// @param answer Its answer.
    /// @param updatedAt Its update time.
    /// @param answeredInRound Its `answeredInRound`.
    event RoundPushed(uint80 indexed roundId, int256 answer, uint256 updatedAt, uint80 answeredInRound);

    /// @notice The response behavior changed.
    /// @param behavior The new behavior.
    event BehaviorSet(Behavior behavior);

    uint8 private immutable _decimals;
    string private _description;

    /// @notice The latest round id (zero before the first push).
    uint80 public latestRoundId;

    /// @notice Current response behavior of `latestRoundData()`.
    Behavior public behavior;

    mapping(uint80 roundId => RoundData) private _rounds;

    /// @param decimals_ Answer precision.
    /// @param description_ Pair name.
    constructor(uint8 decimals_, string memory description_) {
        _decimals = decimals_;
        _description = description_;
    }

    // ------------------------------------------------------------------------------------------------------------
    // Scripting
    // ------------------------------------------------------------------------------------------------------------

    /// @notice Writes a healthy round with `updatedAt = block.timestamp`.
    /// @param answer The answer.
    /// @return roundId The new round.
    function pushAnswer(int256 answer) external returns (uint80 roundId) {
        return _push(answer, block.timestamp, block.timestamp, 0);
    }

    /// @notice Writes a round last updated `age` seconds ago.
    /// @param answer The answer.
    /// @param age Seconds before `block.timestamp`.
    /// @return roundId The new round.
    function pushAnswerWithAge(int256 answer, uint256 age) external returns (uint80 roundId) {
        return _push(answer, block.timestamp - age, block.timestamp - age, 0);
    }

    /// @notice Writes a round whose `updatedAt` is `secondsAhead` in the future.
    /// @param answer The answer.
    /// @param secondsAhead Seconds after `block.timestamp`.
    /// @return roundId The new round.
    function pushFutureAnswer(int256 answer, uint256 secondsAhead) external returns (uint80 roundId) {
        return _push(answer, block.timestamp, block.timestamp + secondsAhead, 0);
    }

    /// @notice Writes a round that never completed (`updatedAt == 0`).
    /// @param answer The answer.
    /// @return roundId The new round.
    function pushIncompleteRound(int256 answer) external returns (uint80 roundId) {
        return _push(answer, block.timestamp, 0, 0);
    }

    /// @notice Writes a round regression: the answer is carried over from the previous round
    ///         (`answeredInRound < roundId`).
    /// @param answer The answer.
    /// @return roundId The new round.
    function pushCarriedOverRound(int256 answer) external returns (uint80 roundId) {
        return _push(answer, block.timestamp, block.timestamp, latestRoundId);
    }

    /// @notice Writes an arbitrary round.
    /// @param answer The answer.
    /// @param startedAt Round start.
    /// @param updatedAt Round update time.
    /// @param answeredInRound `answeredInRound`; zero means "the new round itself".
    /// @return roundId The new round.
    function pushRound(int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
        external
        returns (uint80 roundId)
    {
        return _push(answer, startedAt, updatedAt, answeredInRound);
    }

    /// @notice Sets how `latestRoundData()` responds.
    /// @param newBehavior The behavior.
    function setBehavior(Behavior newBehavior) external {
        behavior = newBehavior;
        emit BehaviorSet(newBehavior);
    }

    // ------------------------------------------------------------------------------------------------------------
    // AggregatorV3Interface
    // ------------------------------------------------------------------------------------------------------------

    /// @inheritdoc AggregatorV3Interface
    function decimals() external view returns (uint8) {
        return _decimals;
    }

    /// @inheritdoc AggregatorV3Interface
    function description() external view returns (string memory) {
        return _description;
    }

    /// @inheritdoc AggregatorV3Interface
    function version() external pure returns (uint256) {
        return 4;
    }

    /// @inheritdoc AggregatorV3Interface
    function getRoundData(uint80 roundId) external view returns (uint80, int256, uint256, uint256, uint80) {
        require(roundId != 0 && roundId <= latestRoundId, NoDataPresent(roundId));
        RoundData memory r = _rounds[roundId];
        return (roundId, r.answer, r.startedAt, r.updatedAt, r.answeredInRound);
    }

    /// @inheritdoc AggregatorV3Interface
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        Behavior current = behavior;
        if (current == Behavior.Revert) revert FeedPaused();
        if (current == Behavior.ShortReturn) {
            // Safety: deliberately returns a single word so tests can prove the router rejects malformed data.
            assembly ("memory-safe") {
                mstore(0x00, 1)
                return(0x00, 0x20)
            }
        }
        uint80 roundId = latestRoundId;
        RoundData memory r = _rounds[roundId];
        return (roundId, r.answer, r.startedAt, r.updatedAt, r.answeredInRound);
    }

    /// @notice The latest round as stored, ignoring `behavior` (lets reference models read a "dead" feed).
    /// @return roundId The latest round.
    /// @return round Its data.
    function latestRoundRaw() external view returns (uint80 roundId, RoundData memory round) {
        roundId = latestRoundId;
        round = _rounds[roundId];
    }

    function _push(int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
        private
        returns (uint80 roundId)
    {
        roundId = latestRoundId + 1;
        latestRoundId = roundId;
        uint80 answeredIn = answeredInRound == 0 ? roundId : answeredInRound;
        _rounds[roundId] = RoundData(answer, startedAt, updatedAt, answeredIn);
        emit RoundPushed(roundId, answer, updatedAt, answeredIn);
    }
}
