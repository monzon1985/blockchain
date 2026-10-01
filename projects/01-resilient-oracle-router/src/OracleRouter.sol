// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";
import {IOracleRouter} from "./interfaces/IOracleRouter.sol";
import {FeedReader} from "./libraries/FeedReader.sol";
import {ObservationRing} from "./libraries/ObservationRing.sol";
import {PriceMath} from "./libraries/PriceMath.sol";
import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import {AuthorityUtils} from "@openzeppelin/contracts/access/manager/AuthorityUtils.sol";

/// @title OracleRouter
/// @notice Turns Chainlink-style feeds into one hardened, 1e18-normalized price per asset.
/// @dev Pipeline for every quote, in order (the first failing step decides the status):
///      1. L2 sequencer: down (or unreadable, or uninitialized) -> `SEQUENCER_DOWN`; up for at most `gracePeriod`
///         seconds -> `GRACE_PERIOD`. Never bridged by any fallback.
///      2. Primary feed: answer > 0 (`ZERO` / `NEGATIVE`); `updatedAt` non-zero, not in the future, not older than
///         the heartbeat, and `answeredInRound >= roundId` (all `STALE`); answer within `[minAnswer, maxAnswer]`
///         (`OUT_OF_BOUNDS`).
///      3. Soft mode only, primary `STALE` only: the TWAP of validated observations (`FALLBACK_USED`) if the ring
///         covers a full window of at least 30 minutes since its last restart and its newest observation is at most
///         one window old. The ring restarts whenever keepers were silent for longer than `min(heartbeat, twapWindow)`
///         or a sequencer outage happened since the previous observation, so no answer is carried across a gap.
///      4. Secondary feed, if configured: validated like the primary. Unhealthy -> strict fails with its status,
///         soft ignores it. Healthy but more than `maxDeviationBps` away -> strict fails with `DEVIATION`, soft
///         quotes the conservative side (min for `Collateral`, max for `Debt`) with status `DEVIATION`.
///      Normalization rounds down for `Collateral` and up for `Debt`.
///
///      Access control: every configuration function is `restricted` through an OpenZeppelin `AccessManager`, and
///      the router itself refuses any configuration call made with an execution delay below `CONFIG_DELAY` (2 days).
///      The only immediate action is `forceStrict`, which can only make an asset more conservative.
contract OracleRouter is IOracleRouter, AccessManaged {
    using ObservationRing for ObservationRing.Ring;

    /// @notice Largest supported feed precision.
    uint8 public constant MAX_DECIMALS = 36;

    /// @notice Largest accepted heartbeat. Chainlink's longest standard heartbeat is 24 h; this leaves a buffer.
    uint32 public constant MAX_HEARTBEAT = 2 days;

    /// @notice Shortest TWAP window the fallback accepts.
    uint32 public constant MIN_TWAP_WINDOW = 30 minutes;

    /// @notice Longest TWAP window (it also caps how long a fallback can bridge a silent primary).
    uint32 public constant MAX_TWAP_WINDOW = 1 days;

    /// @notice Observations are at least `twapWindow / OBSERVATION_SPACING_DIVISOR` apart, so the 64 slots always span
    ///         at least 63/32 windows and nobody can evict the history a TWAP needs by recording too often.
    uint32 public constant OBSERVATION_SPACING_DIVISOR = 32;

    /// @notice Largest accepted deviation threshold (100 %).
    uint16 public constant MAX_DEVIATION_BPS = 10_000;

    /// @notice Recommended sequencer grace period (Chainlink's documented default).
    uint32 public constant DEFAULT_GRACE_PERIOD = 1 hours;

    /// @notice Largest accepted sequencer grace period.
    uint32 public constant MAX_GRACE_PERIOD = 1 days;

    /// @notice Minimum execution delay of every configuration call.
    uint32 public constant CONFIG_DELAY = 2 days;

    /// @inheritdoc IOracleRouter
    address public sequencerFeed;

    /// @inheritdoc IOracleRouter
    uint32 public gracePeriod;

    /// @dev Asset configuration, keyed by token address.
    mapping(address asset => AssetConfig) private _assets;

    /// @dev TWAP observation rings, keyed by token address.
    mapping(address asset => ObservationRing.Ring) private _rings;

    /// @dev Which custom error explains a failed quote. Carried as data so the fallback can be tried before deciding
    ///      to revert, while `getPrice` still reverts with a type-checked custom error.
    enum Reason {
        None,
        FeedUnavailable,
        ZeroAnswer,
        NegativeAnswer,
        MissingTimestamp,
        FutureTimestamp,
        StalePrice,
        StaleRound,
        AnswerOutOfBounds,
        SequencerDown,
        GracePeriodNotOver,
        DeviationTooHigh
    }

    /// @dev A primary-side price on its way through the deviation breaker: rounded down (for the comparison), in the
    ///      caller's rounding (for the answer), and the status it earns if the breaker lets it through.
    struct Candidate {
        uint256 floor;
        uint256 price;
        Status status;
    }

    /// @dev A failed quote: the reason, the feed or asset it concerns, and up to four error arguments.
    struct Failure {
        Reason reason;
        address source;
        uint256 a;
        uint256 b;
        uint256 c;
        uint256 d;
    }

    /// @param initialAuthority The `AccessManager` governing this router.
    /// @param initialSequencerFeed The L2 sequencer-uptime feed, or `address(0)` on L1.
    /// @param initialGracePeriod Grace period after a sequencer recovery (use `DEFAULT_GRACE_PERIOD` unless justified).
    /// @param initialAssets Assets configured at deployment, before the configuration delay applies.
    constructor(
        address initialAuthority,
        address initialSequencerFeed,
        uint32 initialGracePeriod,
        InitialAsset[] memory initialAssets
    ) AccessManaged(initialAuthority) {
        _setSequencerConfig(initialSequencerFeed, initialGracePeriod);
        for (uint256 i; i < initialAssets.length; ++i) {
            _setAssetConfig(initialAssets[i].asset, initialAssets[i].params);
        }
    }

    // ------------------------------------------------------------------------------------------------------------
    // Pricing
    // ------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IOracleRouter
    function getPrice(address asset, Intent intent) external view returns (uint256 price) {
        Failure memory failure;
        (price,,,, failure) = _quote(asset, intent);
        if (price == 0) _revertWith(failure);
    }

    /// @notice Returns the price of `asset` (1e18 = 1 USD per whole token) without reverting on any feed state.
    /// @dev Reverts only with `AssetNotConfigured` (a deployment error, not a runtime condition) or out of gas.
    /// @param asset The token whose price is requested.
    /// @param intent Rounding direction and conservative side requested by the consumer.
    /// @return price The normalized price, or zero when no usable price exists.
    /// @return status Why the price can or cannot be trusted.
    function tryGetPrice(address asset, Intent intent) external view returns (uint256 price, Status status) {
        (price, status,,,) = _quote(asset, intent);
    }

    /// @inheritdoc IOracleRouter
    function consultTwap(address asset, Intent intent) external view returns (bool available, uint256 price) {
        AssetConfig storage config = _configured(asset);
        uint32 window = config.twapWindow;
        (Status sequencerStatus,,) = _checkSequencer();
        if (window != 0 && sequencerStatus == Status.OK) {
            uint256 delta;
            (available, delta) = _rings[asset].consult(_now32(), window);
            if (available) price = PriceMath.averageToWad(delta, window, config.primary.decimals, intent);
        }
    }

    // ------------------------------------------------------------------------------------------------------------
    // Observations
    // ------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IOracleRouter
    function recordObservation(address asset) external returns (uint256 index) {
        AssetConfig storage config = _configured(asset);
        uint32 window = config.twapWindow;
        require(window != 0, TwapDisabled(asset));

        ObservationRing.Ring storage ring = _rings[asset];
        uint32 currentTime = _now32();
        uint32 elapsed = 0; // seconds since the previous observation; only reported when there was one
        if (ring.header.cardinality != 0) {
            elapsed = ring.newestAge(currentTime);
            uint32 spacing = window / OBSERVATION_SPACING_DIVISOR;
            require(elapsed >= spacing, ObservationTooSoon(asset, elapsed, spacing));
        }

        (uint256 answer, uint32 maxGap) = _observable(asset, config, window);
        uint224 answerCumulative;
        bool restarted;
        // casting to 'uint192' is safe because an `OK` answer is at most `maxAnswer`, itself a `uint192`
        // forge-lint: disable-next-line(unsafe-typecast)
        (index, answerCumulative, restarted) = ring.record(currentTime, uint192(answer), maxGap);
        if (restarted) emit ObservationHistoryRestarted(asset, elapsed, maxGap);
        emit ObservationRecorded(asset, index, block.timestamp, answer, answerCumulative);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Configuration
    // ------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IOracleRouter
    function setAssetConfig(address asset, AssetParams calldata params) external restricted {
        _setAssetConfig(asset, params);
    }

    /// @inheritdoc IOracleRouter
    function setSequencerConfig(address newSequencerFeed, uint32 newGracePeriod) external restricted {
        _setSequencerConfig(newSequencerFeed, newGracePeriod);
    }

    /// @inheritdoc IOracleRouter
    function forceStrict(address asset) external restricted {
        _configured(asset).mode = Mode.Strict;
        emit ModeForcedStrict(asset, _msgSender());
    }

    // ------------------------------------------------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IOracleRouter
    function getAssetConfig(address asset) external view returns (AssetConfig memory) {
        return _assets[asset];
    }

    /// @inheritdoc IOracleRouter
    function getRingState(address asset)
        external
        view
        returns (uint256 newest, uint256 cardinality, uint256 lastAnswer)
    {
        ObservationRing.Header memory header = _rings[asset].header;
        return (header.newest, header.cardinality, header.lastAnswer);
    }

    /// @inheritdoc IOracleRouter
    function getObservation(address asset, uint256 index)
        external
        view
        returns (uint32 timestamp, uint224 answerCumulative)
    {
        require(index < ObservationRing.CAPACITY, ObservationIndexOutOfRange(index));
        ObservationRing.Observation memory observation = _rings[asset].observations[index];
        return (observation.timestamp, observation.answerCumulative);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Access control
    // ------------------------------------------------------------------------------------------------------------

    /// @dev Adds a router-level floor on the execution delay of configuration calls. The `AccessManager` reports the
    ///      caller's delay for the target function; anything below `CONFIG_DELAY` is refused, including calls relayed
    ///      by `AccessManager.execute` (the manager is then the caller and reports no delay). Accounts without the
    ///      role get `(false, 0)` and fall through to `AccessManaged`'s own `AccessManagedUnauthorized`.
    ///      `forceStrict` is exempt: it can only tighten an asset.
    function _checkCanCall(address caller, bytes calldata data) internal override {
        bytes4 selector = bytes4(data[0:4]);
        if (selector != this.forceStrict.selector) {
            (bool immediate, uint32 delay) =
                AuthorityUtils.canCallWithDelay(authority(), caller, address(this), selector);
            if (immediate || delay != 0) {
                require(delay >= CONFIG_DELAY, ConfigDelayTooShort(caller, delay, CONFIG_DELAY));
            }
        }
        super._checkCanCall(caller, data);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Quote pipeline
    // ------------------------------------------------------------------------------------------------------------

    /// @dev The whole pipeline. Returns the usable price (zero when there is none), the status, the raw primary
    ///      answer when the primary validated, for how long the sequencer has been up (see `_checkSequencer`), and the
    ///      failure that `getPrice` reverts with when the price is zero. The last three serve keepers and `getPrice`.
    function _quote(address asset, Intent intent)
        private
        view
        returns (uint256 price, Status status, uint256 primaryAnswer, uint256 upFor, Failure memory failure)
    {
        AssetConfig storage config = _configured(asset);

        (status, upFor, failure) = _checkSequencer();
        if (status != Status.OK) return (0, status, 0, 0, failure);

        (status, primaryAnswer, failure) = _validate(config.primary);
        if (status == Status.OK) {
            uint8 decimals = config.primary.decimals;
            Candidate memory spot = Candidate(
                PriceMath.toWad(primaryAnswer, decimals, Intent.Collateral),
                PriceMath.toWad(primaryAnswer, decimals, intent),
                Status.OK
            );
            (price, status, failure) = _crossCheck(asset, config, spot, intent);
        } else if (status == Status.STALE && config.mode == Mode.Soft) {
            (price, status, failure) = _fallback(asset, config, intent, failure);
        }
    }

    /// @dev Step 3: the TWAP fallback for a stale primary in soft mode. Returns the primary's own `STALE` failure
    ///      unchanged when the TWAP is disabled, too short or expired.
    function _fallback(address asset, AssetConfig storage config, Intent intent, Failure memory staleFailure)
        private
        view
        returns (uint256, Status, Failure memory)
    {
        uint32 window = config.twapWindow;
        if (window == 0) return (0, Status.STALE, staleFailure);
        (bool available, uint256 delta) = _rings[asset].consult(_now32(), window);
        if (!available) return (0, Status.STALE, staleFailure);
        uint8 decimals = config.primary.decimals;
        Candidate memory twap = Candidate(
            PriceMath.averageToWad(delta, window, decimals, Intent.Collateral),
            PriceMath.averageToWad(delta, window, decimals, intent),
            Status.FALLBACK_USED
        );
        return _crossCheck(asset, config, twap, intent);
    }

    /// @dev Step 4, first half: asks the secondary for a vote. An unhealthy secondary fails a strict asset and is
    ///      ignored by a soft one.
    function _crossCheck(address asset, AssetConfig storage config, Candidate memory candidate, Intent intent)
        private
        view
        returns (uint256 price, Status status, Failure memory failure)
    {
        if (config.secondary.feed == address(0)) return (candidate.price, candidate.status, failure);

        uint256 secondaryAnswer;
        (status, secondaryAnswer, failure) = _validate(config.secondary);
        if (status == Status.OK) return _breaker(asset, config, candidate, secondaryAnswer, intent);
        // The witness cannot vote. Strict refuses to price without a cross-check; soft prices without one.
        if (config.mode == Mode.Strict) return (0, status, failure);
        return (candidate.price, candidate.status, Failure(Reason.None, address(0), 0, 0, 0, 0));
    }

    /// @dev Step 4, second half: the deviation breaker. The comparison uses rounded-down prices so both intents see
    ///      the same decision; the soft-mode answer uses the caller's rounding.
    function _breaker(
        address asset,
        AssetConfig storage config,
        Candidate memory candidate,
        uint256 secondaryAnswer,
        Intent intent
    ) private view returns (uint256 price, Status status, Failure memory failure) {
        uint8 decimals = config.secondary.decimals;
        uint256 secondaryFloor = PriceMath.toWad(secondaryAnswer, decimals, Intent.Collateral);
        uint256 deviation = PriceMath.deviationBps(candidate.floor, secondaryFloor);
        uint256 maxDeviation = config.maxDeviationBps;
        if (deviation <= maxDeviation) return (candidate.price, candidate.status, failure);

        if (config.mode == Mode.Strict) {
            failure = Failure(Reason.DeviationTooHigh, asset, candidate.floor, secondaryFloor, deviation, maxDeviation);
            return (0, Status.DEVIATION, failure);
        }
        uint256 secondaryPrice = PriceMath.toWad(secondaryAnswer, decimals, intent);
        if (intent == Intent.Collateral) {
            price = candidate.price < secondaryPrice ? candidate.price : secondaryPrice;
        } else {
            price = candidate.price > secondaryPrice ? candidate.price : secondaryPrice;
        }
        status = Status.DEVIATION;
    }

    /// @dev Step 1: the L2 sequencer-uptime check (answer 0 = up, 1 = down; `startedAt` = time of the last change).
    ///      Every doubtful reading fails closed: an unreadable feed, a non-zero answer and an uninitialized feed
    ///      (`startedAt == 0`) all count as down; a `startedAt` in the future counts as "just recovered".
    ///      With an `OK` status it also returns for how long the sequencer has been up (`type(uint256).max` on L1,
    ///      where there is no sequencer), so keepers never carry an observation across an outage.
    function _checkSequencer() private view returns (Status, uint256 upFor, Failure memory failure) {
        address feed = sequencerFeed;
        if (feed == address(0)) return (Status.OK, type(uint256).max, failure);

        (bool ok, FeedReader.Round memory round) = FeedReader.latestRound(feed);
        if (!ok) return (Status.SEQUENCER_DOWN, 0, Failure(Reason.FeedUnavailable, feed, 0, 0, 0, 0));
        if (round.answer != 0 || round.startedAt == 0) {
            return (
                Status.SEQUENCER_DOWN,
                0,
                // casting to 'uint256' is safe because `_revertWith` casts the same 256 bits back to `int256`
                // forge-lint: disable-next-line(unsafe-typecast)
                Failure(Reason.SequencerDown, feed, uint256(round.answer), round.startedAt, 0, 0)
            );
        }
        upFor = round.startedAt > block.timestamp ? 0 : block.timestamp - round.startedAt;
        uint256 grace = gracePeriod;
        if (upFor <= grace) {
            return (Status.GRACE_PERIOD, 0, Failure(Reason.GracePeriodNotOver, feed, round.startedAt, upFor, grace, 0));
        }
        return (Status.OK, upFor, failure);
    }

    /// @dev Keeper-side checks of `recordObservation`. Only an answer the router would serve as `OK` right now can
    ///      enter the ring and, for a soft asset with a witness, only while that witness can vote (a strict asset
    ///      already fails without one), so whenever a secondary is configured every stored answer passed the breaker.
    ///      Returns that answer and the longest gap across which the previous observation may be carried forward:
    ///      - one primary heartbeat: by then the primary must have published again, and nobody saw what;
    ///      - one TWAP window: a longer interval would fill a whole window with a single carried-forward answer;
    ///      - the time since the sequencer came back up: nothing recorded before an outage is carried across it.
    function _observable(address asset, AssetConfig storage config, uint32 window)
        private
        view
        returns (uint256 answer, uint32 maxGap)
    {
        Status status;
        uint256 upFor;
        (, status, answer, upFor,) = _quote(asset, Intent.Collateral);
        require(status == Status.OK, PriceNotObservable(asset, status));
        if (config.mode == Mode.Soft && config.secondary.feed != address(0)) {
            (Status witnessStatus,,) = _validate(config.secondary);
            require(witnessStatus == Status.OK, WitnessUnavailable(asset, witnessStatus));
        }

        uint32 heartbeat = config.primary.heartbeat;
        maxGap = heartbeat < window ? heartbeat : window;
        // casting to 'uint32' is safe because the value is below `maxGap`, itself a `uint32`
        // forge-lint: disable-next-line(unsafe-typecast)
        if (upFor < maxGap) maxGap = uint32(upFor);
    }

    /// @dev Steps 2 and 4: validates one feed, in the documented order.
    function _validate(FeedConfig storage feedConfig)
        private
        view
        returns (Status, uint256 answer, Failure memory failure)
    {
        address feed = feedConfig.feed;
        (bool ok, FeedReader.Round memory round) = FeedReader.latestRound(feed);
        if (!ok) return (Status.STALE, 0, Failure(Reason.FeedUnavailable, feed, 0, 0, 0, 0));
        if (round.answer == 0) return (Status.ZERO, 0, Failure(Reason.ZeroAnswer, feed, round.roundId, 0, 0, 0));
        if (round.answer < 0) {
            // casting to 'uint256' is safe because `_revertWith` casts the same 256 bits back to `int256`
            // forge-lint: disable-next-line(unsafe-typecast)
            return (Status.NEGATIVE, 0, Failure(Reason.NegativeAnswer, feed, uint256(round.answer), 0, 0, 0));
        }
        if (round.updatedAt == 0) {
            return (Status.STALE, 0, Failure(Reason.MissingTimestamp, feed, round.roundId, 0, 0, 0));
        }
        if (round.updatedAt > block.timestamp) {
            return (Status.STALE, 0, Failure(Reason.FutureTimestamp, feed, round.updatedAt, block.timestamp, 0, 0));
        }
        uint256 age = block.timestamp - round.updatedAt;
        uint256 heartbeat = feedConfig.heartbeat;
        if (age > heartbeat) {
            return (Status.STALE, 0, Failure(Reason.StalePrice, feed, round.updatedAt, age, heartbeat, 0));
        }
        if (round.answeredInRound < round.roundId) {
            return (Status.STALE, 0, Failure(Reason.StaleRound, feed, round.roundId, round.answeredInRound, 0, 0));
        }
        // casting to 'uint256' is safe because the answer was checked to be positive above
        // forge-lint: disable-next-line(unsafe-typecast)
        answer = uint256(round.answer);
        uint256 minAnswer = feedConfig.minAnswer;
        uint256 maxAnswer = feedConfig.maxAnswer;
        if (answer < minAnswer || answer > maxAnswer) {
            return (Status.OUT_OF_BOUNDS, 0, Failure(Reason.AnswerOutOfBounds, feed, answer, minAnswer, maxAnswer, 0));
        }
        return (Status.OK, answer, failure);
    }

    /// @dev Reverts with the custom error described by `failure`. Only called when a quote produced no price, which
    ///      always comes with a reason.
    function _revertWith(Failure memory f) private pure {
        // The `int256(f.a)` casts below restore answers that `_validate` and `_checkSequencer` stored bit for bit as
        // `uint256`; they cannot truncate.
        Reason reason = f.reason;
        if (reason == Reason.FeedUnavailable) revert FeedUnavailable(f.source);
        if (reason == Reason.ZeroAnswer) revert ZeroAnswer(f.source, f.a);
        // forge-lint: disable-next-line(unsafe-typecast)
        if (reason == Reason.NegativeAnswer) revert NegativeAnswer(f.source, int256(f.a));
        if (reason == Reason.MissingTimestamp) revert MissingTimestamp(f.source, f.a);
        if (reason == Reason.FutureTimestamp) revert FutureTimestamp(f.source, f.a, f.b);
        if (reason == Reason.StalePrice) revert StalePrice(f.source, f.a, f.b, f.c);
        if (reason == Reason.StaleRound) revert StaleRound(f.source, f.a, f.b);
        // forge-lint: disable-next-line(unsafe-typecast)
        if (reason == Reason.AnswerOutOfBounds) revert AnswerOutOfBounds(f.source, int256(f.a), f.b, f.c);
        // forge-lint: disable-next-line(unsafe-typecast)
        if (reason == Reason.SequencerDown) revert SequencerDown(f.source, int256(f.a), f.b);
        if (reason == Reason.GracePeriodNotOver) revert GracePeriodNotOver(f.a, f.b, f.c);
        revert DeviationTooHigh(f.source, f.a, f.b, f.c, f.d);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Configuration internals
    // ------------------------------------------------------------------------------------------------------------

    function _setAssetConfig(address asset, AssetParams memory params) private {
        require(asset != address(0), InvalidAsset());
        FeedConfig memory primary = _feedConfig(params.primary);
        FeedConfig memory secondary = FeedConfig(address(0), 0, 0, 0, 0);
        if (params.secondary.feed != address(0)) {
            require(params.secondary.feed != params.primary.feed, InvalidFeed(params.secondary.feed));
            secondary = _feedConfig(params.secondary);
            require(
                params.maxDeviationBps != 0 && params.maxDeviationBps <= MAX_DEVIATION_BPS,
                InvalidDeviation(params.maxDeviationBps)
            );
        } else {
            require(
                params.secondary.heartbeat == 0 && params.secondary.minAnswer == 0 && params.secondary.maxAnswer == 0,
                UnusedSecondaryParams()
            );
            require(params.maxDeviationBps == 0, InvalidDeviation(params.maxDeviationBps));
        }
        uint32 window = params.twapWindow;
        require(window == 0 || (window >= MIN_TWAP_WINDOW && window <= MAX_TWAP_WINDOW), InvalidTwapWindow(window));

        AssetConfig storage config = _assets[asset];
        config.primary = primary;
        config.secondary = secondary;
        config.maxDeviationBps = params.maxDeviationBps;
        config.twapWindow = window;
        config.mode = params.mode;

        // A new configuration may change the feed, its decimals or its bounds: old observations no longer describe
        // the answers this configuration would accept, so the history starts over.
        if (_rings[asset].reset()) emit ObservationsReset(asset);
        emit AssetConfigured(asset, config);
    }

    /// @dev Validates one feed's parameters and reads its decimals (the only configuration-time external call).
    function _feedConfig(FeedParams memory params) private view returns (FeedConfig memory) {
        address feed = params.feed;
        require(feed.code.length != 0, InvalidFeed(feed));
        // Configuration-time read (constructor loop or a delayed governance call), never on the pricing path.
        // slither-disable-next-line calls-loop
        uint8 decimals = AggregatorV3Interface(feed).decimals();
        require(decimals <= MAX_DECIMALS, UnsupportedDecimals(feed, decimals));
        require(params.heartbeat != 0 && params.heartbeat <= MAX_HEARTBEAT, InvalidHeartbeat(feed, params.heartbeat));
        // Every accepted answer must be worth at least one wei once normalized, so a validated price is never zero.
        uint256 minResolution = decimals > PriceMath.WAD_DECIMALS ? 10 ** (decimals - PriceMath.WAD_DECIMALS) : 1;
        require(
            params.minAnswer >= minResolution && params.minAnswer <= params.maxAnswer,
            InvalidBounds(feed, params.minAnswer, params.maxAnswer)
        );
        return FeedConfig(feed, params.heartbeat, decimals, params.minAnswer, params.maxAnswer);
    }

    function _setSequencerConfig(address feed, uint32 grace) private {
        require(feed == address(0) || feed.code.length != 0, InvalidFeed(feed));
        require(grace <= MAX_GRACE_PERIOD && (feed == address(0) || grace != 0), InvalidGracePeriod(grace));
        sequencerFeed = feed;
        gracePeriod = grace;
        emit SequencerConfigured(feed, grace);
    }

    /// @dev Storage pointer to a configured asset; reverts for unknown assets.
    function _configured(address asset) private view returns (AssetConfig storage config) {
        config = _assets[asset];
        require(config.primary.feed != address(0), AssetNotConfigured(asset));
    }

    /// @dev Block timestamp truncated to 32 bits. Truncation is intended: the ring only uses 32-bit differences,
    ///      which stay correct across the 2106 wrap.
    function _now32() private view returns (uint32) {
        // casting to 'uint32' truncates on purpose (see above)
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint32(block.timestamp);
    }
}
