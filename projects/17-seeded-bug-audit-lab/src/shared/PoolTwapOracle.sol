// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { IPriceOracle } from "./IPriceOracle.sol";

/// @notice Minimal view of a Kestrel pool's price accumulator.
interface IObservablePool {
    /// @notice Price accumulator brought up to the current block.
    /// @return cumulative token0-in-token1 price integrated over time (WAD-seconds).
    /// @return timestamp Current block timestamp.
    function observe() external view returns (uint256 cumulative, uint256 timestamp);
}

/// @title PoolTwapOracle
/// @notice Fixed-period time-weighted average price over a Kestrel pool's accumulator, in the
///         style of the Uniswap v2 "ExampleOracleSimple".
/// @dev    Consumers read the stored average of the last COMPLETED window, never a partial
///         window, so nothing a third party does can make a read revert or shrink the window:
///         - {update} only closes a window once at least {period} seconds have elapsed. A
///           griefer calling it early gets a revert; calling it on time is what a keeper does
///           anyway. The window a published price covers is therefore always in
///           `[period, maxWindow]` seconds.
///         - A window longer than {maxWindow} is discarded instead of published: an average
///           over days of history would hide a recent crash. The oracle re-anchors and
///           publishes the next full period.
///         - {priceToken0In1} reverts once the published average is older than {maxAge}, so a
///           consumer never prices collateral off a stale average.
///         Because the pool folds the OLD spot price into the accumulator before reserves move,
///         a same-transaction pump adds zero elapsed-weighted price to the accumulator.
contract PoolTwapOracle is IPriceOracle {
    /// @notice The pool whose accumulator is averaged.
    IObservablePool public immutable pool;
    /// @notice Minimum length of an averaging window, in seconds.
    uint256 public immutable period;
    /// @notice Maximum length of an averaging window; longer windows are discarded, in seconds.
    uint256 public immutable maxWindow;
    /// @notice Maximum age of the published average before reads revert, in seconds.
    uint256 public immutable maxAge;

    /// @notice Accumulator value at the start of the open window.
    uint256 public cumulativeLast;
    /// @notice Timestamp at the start of the open window.
    uint256 public timestampLast;
    /// @notice Average price (token1 per 1e18 token0, WAD) over the last completed window.
    uint256 public priceAverage;
    /// @notice End timestamp of the last completed window; zero until the first publication.
    uint256 public priceTimestamp;

    /// @notice Emitted when a completed window is published.
    /// @param price Average price over the window, WAD.
    /// @param windowStart Window start timestamp.
    /// @param windowEnd Window end timestamp.
    event PricePublished(uint256 price, uint256 windowStart, uint256 windowEnd);
    /// @notice Emitted when a window longer than {maxWindow} is discarded and a new one opened.
    /// @param windowStart Discarded window start timestamp.
    /// @param windowEnd Discarded window end (= new window start) timestamp.
    event WindowDiscarded(uint256 windowStart, uint256 windowEnd);

    /// @notice Thrown when {update} is called before {period} seconds have elapsed.
    /// @param elapsed Seconds since the window opened.
    /// @param required Minimum window length ({period}).
    error PeriodNotElapsed(uint256 elapsed, uint256 required);
    /// @notice Thrown when no window has been published yet.
    error NoPrice();
    /// @notice Thrown when the published average is older than {maxAge}.
    /// @param age Seconds since the published window ended.
    /// @param maxAge_ Maximum accepted age.
    error StalePrice(uint256 age, uint256 maxAge_);
    /// @notice Thrown when the constructor parameters are inconsistent.
    /// @param period_ Requested period.
    /// @param maxWindow_ Requested maximum window.
    /// @param maxAge_ Requested maximum age.
    error InvalidConfig(uint256 period_, uint256 maxWindow_, uint256 maxAge_);

    /// @notice Deploy the oracle and open the first window at the current accumulator reading.
    /// @param _pool Pool to observe.
    /// @param _period Minimum window length in seconds (> 0).
    /// @param _maxWindow Maximum window length in seconds (>= `_period`).
    /// @param _maxAge Maximum age of a published price in seconds (>= `_period`).
    constructor(IObservablePool _pool, uint256 _period, uint256 _maxWindow, uint256 _maxAge) {
        require(
            _period > 0 && _maxWindow >= _period && _maxAge >= _period,
            InvalidConfig(_period, _maxWindow, _maxAge)
        );
        pool = _pool;
        period = _period;
        maxWindow = _maxWindow;
        maxAge = _maxAge;
        (uint256 c, uint256 t) = _pool.observe();
        cumulativeLast = c;
        timestampLast = t;
    }

    /// @notice Close the open window and publish its average, then open a new window.
    ///         Permissionless: it can only be called once a full {period} has elapsed.
    /// @return published True when a price was published; false when an over-long window was
    ///         discarded (the next full period will publish).
    function update() external returns (bool published) {
        (uint256 c, uint256 t) = pool.observe();
        uint256 start = timestampLast;
        uint256 elapsed = t - start;
        require(elapsed >= period, PeriodNotElapsed(elapsed, period));
        if (elapsed <= maxWindow) {
            uint256 price = (c - cumulativeLast) / elapsed;
            priceAverage = price;
            priceTimestamp = t;
            published = true;
            emit PricePublished(price, start, t);
        } else {
            emit WindowDiscarded(start, t);
        }
        cumulativeLast = c;
        timestampLast = t;
    }

    /// @inheritdoc IPriceOracle
    /// @dev Reverts with {NoPrice} before the first publication and with {StalePrice} once the
    ///      published average is older than {maxAge}.
    function priceToken0In1() external view returns (uint256 price) {
        uint256 ts = priceTimestamp;
        require(ts != 0, NoPrice());
        uint256 age = block.timestamp - ts;
        require(age <= maxAge, StalePrice(age, maxAge));
        price = priceAverage;
    }
}
