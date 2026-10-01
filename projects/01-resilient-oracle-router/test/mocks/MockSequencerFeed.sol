// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title MockSequencerFeed
/// @notice Scriptable Chainlink L2 sequencer-uptime feed: `answer` is 0 when the sequencer is up and 1 when it is down,
///         and `startedAt` is the time of the last status change.
/// @dev Test infrastructure only: every function is unpermissioned so tests and scripts can drive it freely.
contract MockSequencerFeed {
    /// @notice `latestRoundData` is configured to revert.
    error FeedPaused();

    /// @notice The reported status changed.
    /// @param answer The new answer.
    /// @param startedAt The new `startedAt`.
    event StatusSet(int256 answer, uint256 startedAt);

    /// @notice Current answer (0 = up, 1 = down; other values are invalid and must be treated as down).
    int256 public answer;

    /// @notice Time of the last status change.
    uint256 public startedAt;

    /// @notice Round counter, bumped on every change.
    uint80 public roundId;

    /// @notice When true, `latestRoundData` reverts.
    bool public reverts;

    /// @param upSince When the sequencer last came up.
    constructor(uint256 upSince) {
        _set(0, upSince);
    }

    /// @notice Marks the sequencer as down from now on.
    function setDown() external {
        _set(1, block.timestamp);
    }

    /// @notice Marks the sequencer as up from now on (starting the grace period).
    function setUp() external {
        _set(0, block.timestamp);
    }

    /// @notice Flips the status, starting a new period now.
    function flip() external {
        _set(answer == 0 ? int256(1) : int256(0), block.timestamp);
    }

    /// @notice Writes an arbitrary reading.
    /// @param newAnswer The answer.
    /// @param newStartedAt The status-change time.
    function setRaw(int256 newAnswer, uint256 newStartedAt) external {
        _set(newAnswer, newStartedAt);
    }

    /// @notice Makes `latestRoundData` revert (or stop reverting).
    /// @param shouldRevert The new behavior.
    function setReverts(bool shouldRevert) external {
        reverts = shouldRevert;
    }

    /// @notice Chainlink-compatible read.
    /// @return The round id, answer, startedAt, updatedAt (= startedAt) and answeredInRound.
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        require(!reverts, FeedPaused());
        return (roundId, answer, startedAt, startedAt, roundId);
    }

    /// @notice Sequencer-uptime feeds report no decimals.
    /// @return Always 0.
    function decimals() external pure returns (uint8) {
        return 0;
    }

    function _set(int256 newAnswer, uint256 newStartedAt) private {
        answer = newAnswer;
        startedAt = newStartedAt;
        ++roundId;
        emit StatusSet(newAnswer, newStartedAt);
    }
}
