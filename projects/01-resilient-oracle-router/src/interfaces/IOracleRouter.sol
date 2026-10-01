// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IPriceOracle} from "./IPriceOracle.sol";

/// @title IOracleRouter
/// @notice Full interface of the resilient oracle router: the non-reverting `IPriceOracle` API, a reverting variant
///         whose custom errors carry the offending values, the TWAP observation ring and the delayed configuration.
interface IOracleRouter is IPriceOracle {
    // ------------------------------------------------------------------------------------------------------------
    // Types
    // ------------------------------------------------------------------------------------------------------------

    /// @notice How an asset degrades when something is wrong.
    /// @dev `Strict` fails closed on every anomaly. `Soft` serves a bounded, conservative answer where one exists: the
    ///      TWAP of validated observations while the primary is stale, the conservative side of a primary/secondary
    ///      disagreement, and the primary alone when the secondary is unhealthy. Strict is never looser than soft.
    enum Mode {
        Strict,
        Soft
    }

    /// @notice Governance input for one feed.
    /// @param feed Chainlink-style `AggregatorV3Interface` feed; `address(0)` means "no feed" for the secondary.
    /// @param heartbeat Maximum accepted answer age in seconds.
    /// @param minAnswer Smallest accepted raw answer, in the feed's own decimals.
    /// @param maxAnswer Largest accepted raw answer, in the feed's own decimals.
    struct FeedParams {
        address feed;
        uint32 heartbeat;
        uint192 minAnswer;
        uint192 maxAnswer;
    }

    /// @notice Governance input for one asset.
    /// @param primary The feed that prices the asset.
    /// @param secondary Optional independent witness for the deviation breaker (`feed == address(0)` disables it).
    /// @param maxDeviationBps Largest tolerated gap between primary and secondary, relative to the lower of the two.
    /// @param twapWindow TWAP window in seconds (at least 30 minutes), or zero to disable the TWAP fallback.
    /// @param mode Degradation mode.
    struct AssetParams {
        FeedParams primary;
        FeedParams secondary;
        uint16 maxDeviationBps;
        uint32 twapWindow;
        Mode mode;
    }

    /// @notice Stored configuration of one feed (three storage slots).
    /// @param feed The feed address.
    /// @param heartbeat Maximum accepted answer age in seconds.
    /// @param decimals The feed's decimals, read once when the asset is configured.
    /// @param minAnswer Smallest accepted raw answer.
    /// @param maxAnswer Largest accepted raw answer; at most `type(uint192).max`, like Chainlink's own int192 answers.
    struct FeedConfig {
        address feed;
        uint32 heartbeat;
        uint8 decimals;
        uint192 minAnswer;
        uint192 maxAnswer;
    }

    /// @notice Stored configuration of one asset.
    /// @param primary The primary feed.
    /// @param secondary The secondary feed (`feed == address(0)` when absent).
    /// @param maxDeviationBps Deviation-breaker threshold in basis points.
    /// @param twapWindow TWAP window in seconds, zero when the fallback is disabled.
    /// @param mode Degradation mode.
    struct AssetConfig {
        FeedConfig primary;
        FeedConfig secondary;
        uint16 maxDeviationBps;
        uint32 twapWindow;
        Mode mode;
    }

    /// @notice An asset configured at deployment, before the configuration delay applies.
    /// @param asset The token address.
    /// @param params Its configuration.
    struct InitialAsset {
        address asset;
        AssetParams params;
    }

    // ------------------------------------------------------------------------------------------------------------
    // Pricing errors (reverted by `getPrice`; `tryGetPrice` reports the matching `Status` instead)
    // ------------------------------------------------------------------------------------------------------------

    /// @notice The asset has never been configured. Raised by every entry point, including `tryGetPrice`.
    /// @param asset The unknown asset.
    error AssetNotConfigured(address asset);

    /// @notice A feed call reverted, returned fewer than 160 bytes, or hit an address without code.
    /// @dev Maps to `STALE` for price feeds and to `SEQUENCER_DOWN` for the sequencer-uptime feed.
    /// @param feed The feed that could not be read.
    error FeedUnavailable(address feed);

    /// @notice The feed answered zero. Maps to `ZERO`.
    /// @param feed The feed.
    /// @param roundId The round that carried the zero answer.
    error ZeroAnswer(address feed, uint256 roundId);

    /// @notice The feed answered a negative value. Maps to `NEGATIVE`.
    /// @param feed The feed.
    /// @param answer The negative answer.
    error NegativeAnswer(address feed, int256 answer);

    /// @notice The round has no `updatedAt` (it never completed). Maps to `STALE`.
    /// @param feed The feed.
    /// @param roundId The incomplete round.
    error MissingTimestamp(address feed, uint256 roundId);

    /// @notice The answer claims to come from the future. Maps to `STALE`.
    /// @param feed The feed.
    /// @param updatedAt The reported update time.
    /// @param currentTime The current block timestamp.
    error FutureTimestamp(address feed, uint256 updatedAt, uint256 currentTime);

    /// @notice The answer is older than the configured heartbeat. Maps to `STALE`.
    /// @param feed The feed.
    /// @param updatedAt When the answer was last updated.
    /// @param age Seconds since `updatedAt`.
    /// @param heartbeat The configured maximum age.
    error StalePrice(address feed, uint256 updatedAt, uint256 age, uint256 heartbeat);

    /// @notice The answer was carried over from an earlier round (`answeredInRound < roundId`). Maps to `STALE`.
    /// @param feed The feed.
    /// @param roundId The latest round id.
    /// @param answeredInRound The round the answer was computed in.
    error StaleRound(address feed, uint256 roundId, uint256 answeredInRound);

    /// @notice The answer lies outside the configured `[minAnswer, maxAnswer]`. Maps to `OUT_OF_BOUNDS`.
    /// @param feed The feed.
    /// @param answer The rejected answer.
    /// @param minAnswer The configured lower bound.
    /// @param maxAnswer The configured upper bound.
    error AnswerOutOfBounds(address feed, int256 answer, uint256 minAnswer, uint256 maxAnswer);

    /// @notice The L2 sequencer is reported down, or its status is not a valid "up". Maps to `SEQUENCER_DOWN`.
    /// @param sequencerFeed The sequencer-uptime feed.
    /// @param answer The reported status (0 = up, 1 = down).
    /// @param startedAt When the status last changed (zero means the feed is not initialized).
    error SequencerDown(address sequencerFeed, int256 answer, uint256 startedAt);

    /// @notice The sequencer came back up less than `gracePeriod` seconds ago. Maps to `GRACE_PERIOD`.
    /// @param startedAt When the sequencer came back up.
    /// @param elapsed Seconds since then (zero if `startedAt` is in the future).
    /// @param gracePeriod The configured grace period.
    error GracePeriodNotOver(uint256 startedAt, uint256 elapsed, uint256 gracePeriod);

    /// @notice Primary (or its TWAP) and secondary disagree by more than the threshold, in strict mode.
    /// @dev Maps to `DEVIATION`. Both prices are 1e18-normalized and rounded down.
    /// @param asset The asset.
    /// @param primaryPrice The primary-side price (spot or TWAP).
    /// @param secondaryPrice The secondary price.
    /// @param deviationBps The gap relative to the lower price, rounded up.
    /// @param maxDeviationBps The configured threshold.
    error DeviationTooHigh(
        address asset, uint256 primaryPrice, uint256 secondaryPrice, uint256 deviationBps, uint256 maxDeviationBps
    );

    // ------------------------------------------------------------------------------------------------------------
    // Observation errors
    // ------------------------------------------------------------------------------------------------------------

    /// @notice The asset has no TWAP window, so there is nothing to record.
    /// @param asset The asset.
    error TwapDisabled(address asset);

    /// @notice Observations must be at least `twapWindow / 32` seconds apart, so 64 slots always span 1.97 windows.
    /// @param asset The asset.
    /// @param elapsed Seconds since the newest observation.
    /// @param minSpacing The required spacing.
    error ObservationTooSoon(address asset, uint256 elapsed, uint256 minSpacing);

    /// @notice The ring has 64 slots.
    /// @param index The rejected slot index.
    error ObservationIndexOutOfRange(uint256 index);

    /// @notice Only prices the router would serve with `Status.OK` are recorded.
    /// @param asset The asset.
    /// @param status The status the router reports right now.
    error PriceNotObservable(address asset, Status status);

    /// @notice A soft asset's secondary cannot vote right now, so the primary answer is not recorded: the ring only
    ///         holds answers the witness confirmed (soft mode still serves the primary alone, but never stores it).
    /// @param asset The asset.
    /// @param witnessStatus The status of the secondary feed (`STALE`, `ZERO`, `NEGATIVE` or `OUT_OF_BOUNDS`).
    error WitnessUnavailable(address asset, Status witnessStatus);

    // ------------------------------------------------------------------------------------------------------------
    // Configuration errors
    // ------------------------------------------------------------------------------------------------------------

    /// @notice The asset address is zero.
    error InvalidAsset();

    /// @notice A feed is the zero address, has no code, or the secondary equals the primary.
    /// @param feed The rejected feed.
    error InvalidFeed(address feed);

    /// @notice A feed reports more than 36 decimals.
    /// @param feed The feed.
    /// @param decimals The reported decimals.
    error UnsupportedDecimals(address feed, uint256 decimals);

    /// @notice A heartbeat is zero or longer than `MAX_HEARTBEAT`.
    /// @param feed The feed.
    /// @param heartbeat The rejected heartbeat.
    error InvalidHeartbeat(address feed, uint256 heartbeat);

    /// @notice Bounds are inverted, or `minAnswer` is below one wei once normalized to 1e18.
    /// @param feed The feed.
    /// @param minAnswer The rejected lower bound.
    /// @param maxAnswer The rejected upper bound.
    error InvalidBounds(address feed, uint256 minAnswer, uint256 maxAnswer);

    /// @notice The deviation threshold is zero with a secondary, above 10 000 bps, or set without a secondary.
    /// @param maxDeviationBps The rejected threshold.
    error InvalidDeviation(uint256 maxDeviationBps);

    /// @notice Heartbeat or bounds were given for a secondary feed that is not set.
    error UnusedSecondaryParams();

    /// @notice The TWAP window is non-zero and outside `[MIN_TWAP_WINDOW, MAX_TWAP_WINDOW]`.
    /// @param twapWindow The rejected window.
    error InvalidTwapWindow(uint256 twapWindow);

    /// @notice The grace period is above `MAX_GRACE_PERIOD`, or zero while a sequencer feed is set.
    /// @param gracePeriod The rejected grace period.
    error InvalidGracePeriod(uint256 gracePeriod);

    /// @notice A configuration call arrived without the mandatory execution delay.
    /// @dev Enforced by the router itself, so a role granted with a shorter delay (or a call relayed through
    ///      `AccessManager.execute`, which hides the caller's delay) cannot bypass it.
    /// @param caller The caller.
    /// @param delay The execution delay the authority reports for this caller and function.
    /// @param required The minimum delay, `CONFIG_DELAY`.
    error ConfigDelayTooShort(address caller, uint256 delay, uint256 required);

    // ------------------------------------------------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------------------------------------------------

    /// @notice An asset was configured or reconfigured. Its TWAP history starts over.
    /// @param asset The asset.
    /// @param config The stored configuration, including the cached feed decimals.
    event AssetConfigured(address indexed asset, AssetConfig config);

    /// @notice The guardian switched an asset to strict mode without delay.
    /// @param asset The asset.
    /// @param caller The guardian account.
    event ModeForcedStrict(address indexed asset, address indexed caller);

    /// @notice The sequencer-uptime feed or grace period changed.
    /// @param sequencerFeed The new feed (`address(0)` disables the check, for L1 deployments).
    /// @param gracePeriod The new grace period in seconds.
    event SequencerConfigured(address indexed sequencerFeed, uint256 gracePeriod);

    /// @notice A validated primary answer was written to the asset's observation ring.
    /// @param asset The asset.
    /// @param index Ring slot written.
    /// @param timestamp Block timestamp of the observation.
    /// @param answer Raw primary answer recorded.
    /// @param answerCumulative Running time-weighted sum stored in the slot (modulo 2^224).
    event ObservationRecorded(
        address indexed asset, uint256 index, uint256 timestamp, uint256 answer, uint256 answerCumulative
    );

    /// @notice An asset's TWAP history was discarded because its configuration changed.
    /// @param asset The asset.
    event ObservationsReset(address indexed asset);

    /// @notice An observation arrived too long after the previous one, so the earlier history was discarded and this
    ///         observation starts a new one: no answer is carried across a gap longer than one primary heartbeat or
    ///         one TWAP window, nor across a sequencer outage.
    /// @param asset The asset.
    /// @param gap Seconds since the previous observation.
    /// @param maxGap The longest gap that would have been bridged: `min(heartbeat, twapWindow, sequencer uptime)`.
    event ObservationHistoryRestarted(address indexed asset, uint256 gap, uint256 maxGap);

    // ------------------------------------------------------------------------------------------------------------
    // Pricing
    // ------------------------------------------------------------------------------------------------------------

    /// @notice Returns the usable price of `asset`, or reverts with the custom error that explains why there is none.
    /// @dev Returns exactly what `tryGetPrice` returns whenever that price is non-zero, and reverts exactly when it is
    ///      zero. The status is not returned: callers that need it use `tryGetPrice`.
    /// @param asset The token whose price is requested.
    /// @param intent Rounding direction and conservative side.
    /// @return price The normalized price (1e18 = 1 USD per whole token).
    function getPrice(address asset, Intent intent) external view returns (uint256 price);

    /// @notice Diagnostic view: the time-weighted average the fallback would start from right now.
    /// @dev Not a price source. It ignores the primary's health, the deviation breaker and the asset's mode;
    ///      `tryGetPrice` and `getPrice` are the only pricing entry points. It does honor the sequencer: while the
    ///      sequencer is down, unreadable or in its grace period it returns `(false, 0)`, like every pricing path.
    /// @param asset The asset.
    /// @param intent Rounding direction.
    /// @return available Whether the sequencer is healthy, the ring covers a full window since its last restart and
    ///         its newest observation is at most one window old.
    /// @return price The 1e18-normalized average, zero when unavailable.
    function consultTwap(address asset, Intent intent) external view returns (bool available, uint256 price);

    // ------------------------------------------------------------------------------------------------------------
    // Observations
    // ------------------------------------------------------------------------------------------------------------

    /// @notice Records the current primary answer in the asset's ring. Permissionless (keepers call it).
    /// @dev Succeeds only when the router would serve the asset with `Status.OK`, the asset's secondary (if any) is
    ///      healthy enough to have cross-checked it, and at least `twapWindow / 32` seconds have passed since the
    ///      previous observation. When the previous observation is older than `min(heartbeat, twapWindow)`, or older
    ///      than the sequencer's latest recovery, the earlier history is discarded (`ObservationHistoryRestarted`).
    /// @param asset The asset.
    /// @return index The ring slot written.
    function recordObservation(address asset) external returns (uint256 index);

    // ------------------------------------------------------------------------------------------------------------
    // Configuration
    // ------------------------------------------------------------------------------------------------------------

    /// @notice Configures or reconfigures an asset and discards its TWAP history.
    /// @dev Restricted; the caller's execution delay must be at least `CONFIG_DELAY`.
    /// @param asset The asset.
    /// @param params The new configuration.
    function setAssetConfig(address asset, AssetParams calldata params) external;

    /// @notice Sets the L2 sequencer-uptime feed and its grace period.
    /// @dev Restricted; the caller's execution delay must be at least `CONFIG_DELAY`.
    /// @param newSequencerFeed The feed, or `address(0)` on L1.
    /// @param newGracePeriod Seconds after recovery during which prices stay unavailable.
    function setSequencerConfig(address newSequencerFeed, uint32 newGracePeriod) external;

    /// @notice Switches an asset to strict mode immediately. Loosening back requires a delayed `setAssetConfig`.
    /// @dev Restricted to the guardian role; strict mode is never looser than soft mode, so no delay is needed.
    /// @param asset The asset.
    function forceStrict(address asset) external;

    // ------------------------------------------------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------------------------------------------------

    /// @notice The stored configuration of `asset`.
    /// @param asset The asset.
    /// @return The configuration (all zero when the asset is not configured).
    function getAssetConfig(address asset) external view returns (AssetConfig memory);

    /// @notice The ring header of `asset`.
    /// @param asset The asset.
    /// @return newest Index of the newest observation.
    /// @return cardinality Number of populated slots (at most 64).
    /// @return lastAnswer Raw answer of the newest observation.
    function getRingState(address asset) external view returns (uint256 newest, uint256 cardinality, uint256 lastAnswer);

    /// @notice One slot of the observation ring of `asset`.
    /// @param asset The asset.
    /// @param index The slot, below 64 (reverts with `ObservationIndexOutOfRange` otherwise).
    /// @return timestamp Observation time, truncated to 32 bits.
    /// @return answerCumulative Running time-weighted sum of raw answers, modulo 2^224.
    function getObservation(address asset, uint256 index)
        external
        view
        returns (uint32 timestamp, uint224 answerCumulative);

    /// @notice The L2 sequencer-uptime feed, `address(0)` when the check is disabled.
    /// @return The feed.
    function sequencerFeed() external view returns (address);

    /// @notice Seconds after a sequencer recovery during which prices stay unavailable.
    /// @return The grace period.
    function gracePeriod() external view returns (uint32);
}
