// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title AggregatorV3Interface
/// @notice The read interface of a Chainlink-style price feed (and of the Chainlink L2 sequencer-uptime feed).
/// @dev Declared locally with the same selectors as Chainlink's `AggregatorV3Interface` so the project has no
///      dependency on the Chainlink package. The router never calls these functions through this interface at
///      runtime: it reads `latestRoundData()` with a bounded low-level `staticcall` (see `FeedReader`) so that a
///      reverting or malformed feed cannot make the non-reverting API revert. `decimals()` is only read at
///      configuration time.
interface AggregatorV3Interface {
    /// @notice Number of decimals of `answer`.
    /// @return The decimals of every answer this feed reports.
    function decimals() external view returns (uint8);

    /// @notice Human-readable pair name, e.g. "ETH / USD".
    /// @return The feed description.
    function description() external view returns (string memory);

    /// @notice Aggregator implementation version.
    /// @return The version number.
    function version() external view returns (uint256);

    /// @notice Data of a historical round.
    /// @param roundId The round to read.
    /// @return roundId The round id.
    /// @return answer The reported answer, in `decimals()` precision.
    /// @return startedAt When the round started (for the sequencer feed: when the status last changed).
    /// @return updatedAt When the answer was last updated; zero means the round is not complete.
    /// @return answeredInRound Deprecated by Chainlink; the round in which the answer was computed.
    function getRoundData(uint80 roundId)
        external
        view
        returns (uint80, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    /// @notice Data of the latest round.
    /// @return roundId The round id.
    /// @return answer The reported answer, in `decimals()` precision.
    /// @return startedAt When the round started (for the sequencer feed: when the status last changed).
    /// @return updatedAt When the answer was last updated; zero means the round is not complete.
    /// @return answeredInRound Deprecated by Chainlink; the round in which the answer was computed.
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
