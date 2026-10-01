// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {OracleRouter} from "../../src/OracleRouter.sol";
import {IOracleRouter} from "../../src/interfaces/IOracleRouter.sol";
import {IPriceOracle} from "../../src/interfaces/IPriceOracle.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";
import {MockSequencerFeed} from "../mocks/MockSequencerFeed.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title OracleSystem
/// @notice One stateful world shared by the Foundry invariant suite and the Medusa campaign: three assets with very
///         different feeds (8/18, 36/0 and 18/none decimals), one sequencer, and a strict and a soft router over the
///         same feeds. Actions age, update, corrupt, silence and heal feeds, flip the sequencer, and let keepers
///         record observations on every asset of both routers. Properties compare every quote with an independent
///         reference model that reads the mocks' raw storage and a ghost log of the observations each router accepted.
/// @dev Actions never revert (Foundry runs with `fail_on_revert = true`). Properties are `view` and return `bool`
///      (Medusa's property mode); the Foundry suite asserts them. Nothing here reuses router internals.
///
///      The world is shaped so that the fallback properties (P7, P8) are exercised, not vacuous: keepers record after
///      every time step (as real keepers run continuously), sequencer outages are rare (each one forces a 1 h grace
///      period and a new TWAP history), the witness usually agrees with the primary, and `silencePrimary` makes a
///      primary go stale without touching the history keepers built. `_sample` counts, after every action, the
///      states in which those properties have something to check; both engines check every property after every
///      action, so each count is a number of non-vacuous property evaluations.
contract OracleSystem {
    Vm internal constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint256 public constant ASSET_COUNT = 3;
    uint256 internal constant WINDOW_CAPACITY = 64;

    struct Asset {
        address token;
        MockAggregatorV3 primary;
        MockAggregatorV3 secondary; // zero for asset 2
        uint8 primaryDecimals;
        uint8 secondaryDecimals;
        uint32 primaryHeartbeat;
        uint32 secondaryHeartbeat;
        uint192 primaryMin;
        uint192 primaryMax;
        uint192 secondaryMin;
        uint192 secondaryMax;
        uint16 maxDeviationBps;
        uint32 twapWindow;
    }

    struct Observation {
        uint256 timestamp;
        uint256 answer;
    }

    AccessManager public manager;
    MockSequencerFeed public sequencer;
    OracleRouter public strictRouter;
    OracleRouter public softRouter;
    /// @dev A short (valid) grace period, so that a brief outage plus its grace period can be shorter than every gap
    ///      limit: only the "never across an outage" rule then restarts the history, and the campaign checks it.
    uint32 public constant GRACE = 10 minutes;

    Asset[3] internal _assets;

    /// @dev Ghost copy of every observation each router accepted: [0] = strict, [1] = soft.
    mapping(uint256 routerIndex => mapping(uint256 asset => Observation[])) internal _ghostObservations;

    /// @dev Index in the ghost log of the first observation after the last break: a silence longer than
    ///      `min(heartbeat, twapWindow)`, or a sequencer recovery between two accepted observations. The TWAP may only
    ///      average observations from there on (the specification of the gap rule, written independently).
    mapping(uint256 routerIndex => mapping(uint256 asset => uint256)) internal _ghostHistoryStart;

    /// @notice Bit i set when some action left some quote with `Status(i)` (proves the campaign is not vacuous).
    uint256 public statusesSeen;

    /// @notice Number of actions called so far (a run's length, so short replays can be told from full runs).
    uint256 public actionCount;

    /// @notice Number of observations accepted, per router.
    uint256[2] public observationsRecorded;

    /// @notice Accepted observations that, per the reference model, started a new history (gap or outage).
    uint256 public historyRestarts;

    /// @notice Post-action states in which a soft quote was `FALLBACK_USED`, so P7 compared it with the reference TWAP.
    uint256 public fallbackStates;

    /// @notice Post-action states in which a soft quote was `DEVIATION` while its primary was stale: the TWAP was
    ///         checked against a live witness that disagreed.
    uint256 public twapDeviationStates;

    /// @notice Post-action states in which P8's premise held for some asset (healthy sequencer, stale-family primary,
    ///         a full and fresh window in the reference model), so P8 required the soft router to quote.
    uint256 public bridgeableStates;

    /// @notice Post-action states in which some soft quote was `STALE`: the primary was stale and the fallback was
    ///         refused (window too short, expired or restarted), and P2, P3 and P8 checked that refusal.
    uint256 public refusedFallbackStates;

    constructor() {
        uint256 start = block.timestamp;
        manager = new AccessManager(address(this));
        sequencer = new MockSequencerFeed(start > 30 days ? start - 30 days : 1);

        _assets[0] = _newAsset(address(0xA0), 8, 18, 1 hours, 1 days, 300, 30 minutes, true);
        _assets[1] = _newAsset(address(0xA1), 36, 0, 2 hours, 1 days, 500, 1 hours, true);
        // Asset 2's heartbeat is shorter than its window, so its gap limit is the heartbeat (the others: the window).
        _assets[2] = _newAsset(address(0xA2), 18, 0, 30 minutes, 0, 0, 45 minutes, false);

        IOracleRouter.InitialAsset[] memory strictAssets = new IOracleRouter.InitialAsset[](ASSET_COUNT);
        IOracleRouter.InitialAsset[] memory softAssets = new IOracleRouter.InitialAsset[](ASSET_COUNT);
        for (uint256 i; i < ASSET_COUNT; ++i) {
            strictAssets[i] = IOracleRouter.InitialAsset(_assets[i].token, _paramsOf(i, IOracleRouter.Mode.Strict));
            softAssets[i] = IOracleRouter.InitialAsset(_assets[i].token, _paramsOf(i, IOracleRouter.Mode.Soft));
            _assets[i].primary.pushAnswer(int256(2000 * 10 ** _assets[i].primaryDecimals));
            if (address(_assets[i].secondary) != address(0)) {
                _assets[i].secondary.pushAnswer(int256(2000 * 10 ** _assets[i].secondaryDecimals));
            }
        }
        strictRouter = new OracleRouter(address(manager), address(sequencer), GRACE, strictAssets);
        softRouter = new OracleRouter(address(manager), address(sequencer), GRACE, softAssets);
    }

    // ============================================================================================================
    // Actions
    // ============================================================================================================

    modifier action() {
        ++actionCount;
        _;
    }

    /// @notice Time passes. Usually (16 calls in 20) 1 to 15 minutes of normal operation: every feed that is healthy
    ///         keeps publishing (a heartbeat update of its last answer) and keepers record every asset on both routers.
    ///         Three calls in 20, keepers pause for 20 to 75 minutes while feeds keep publishing, so the next
    ///         observations land just under or just over the gap limits (30, 60 and 30 minutes). One call in 20 is up
    ///         to 6 hours of silence: nothing is published, and keepers only come back at the end.
    function warp(uint256 seed) external action {
        seed = _mix(seed);
        uint256 kind = seed % 20;
        if (kind == 0) {
            VM.warp(block.timestamp + _bound(seed >> 8, 1, 6 hours));
        } else {
            uint256 remaining = kind <= 3 ? _bound(seed >> 8, 20 minutes, 75 minutes) : _bound(seed >> 8, 1, 15 minutes);
            while (remaining != 0) {
                uint256 step = remaining < 15 minutes ? remaining : 15 minutes;
                VM.warp(block.timestamp + step);
                remaining -= step;
                _republishHealthyFeeds();
            }
        }
        _keepersRecord();
        _sample();
    }

    /// @notice A healthy primary update: usually a +-5 % move from the last answer, one call in ten a jump anywhere
    ///         between $50 and $150,000 (sometimes out of bounds, often far from the secondary).
    function updatePrimary(uint256 assetSeed, uint256 priceSeed) external action {
        Asset storage a = _asset(assetSeed);
        priceSeed = _mix(priceSeed);
        a.primary.setBehavior(MockAggregatorV3.Behavior.Normal);
        uint256 unit = 10 ** a.primaryDecimals;
        (, MockAggregatorV3.RoundData memory last) = a.primary.latestRoundRaw();
        uint256 answer;
        if (priceSeed % 10 == 0 || last.answer <= 0) {
            answer = _bound(priceSeed >> 8, 50 * unit, 150_000 * unit);
        } else {
            answer = uint256(last.answer) * _bound(priceSeed >> 8, 9500, 10_500) / 10_000;
            if (answer == 0) answer = 1;
        }
        a.primary.pushAnswer(int256(answer));
        _sample();
    }

    /// @notice A healthy secondary update: three calls in four within +-2 % of the primary (below both breaker
    ///         thresholds), one in four within +-10 % (so the breaker sometimes trips).
    function updateSecondary(uint256 assetSeed, uint256 deviationSeed) external action {
        Asset storage a = _asset(assetSeed);
        if (address(a.secondary) == address(0)) return;
        deviationSeed = _mix(deviationSeed);
        (, MockAggregatorV3.RoundData memory p) = a.primary.latestRoundRaw();
        uint256 primaryWad = p.answer > 0 ? Math.mulDiv(uint256(p.answer), 1e18, 10 ** a.primaryDecimals) : 2000e18;
        uint256 factor = deviationSeed % 4 == 0
            ? _bound(deviationSeed >> 8, 9000, 11_000)
            : _bound(deviationSeed >> 8, 9800, 10_200);
        uint256 secondaryWad = primaryWad * factor / 10_000;
        uint256 answer = Math.mulDiv(secondaryWad, 10 ** a.secondaryDecimals, 1e18);
        a.secondary.setBehavior(MockAggregatorV3.Behavior.Normal);
        a.secondary.pushAnswer(int256(answer == 0 ? 1 : answer));
        _sample();
    }

    /// @notice Breaks a feed in one of nine ways.
    function corruptFeed(uint256 assetSeed, bool onSecondary, uint256 kindSeed, uint256 amountSeed) external action {
        Asset storage a = _asset(assetSeed);
        MockAggregatorV3 feed = onSecondary ? a.secondary : a.primary;
        if (address(feed) == address(0)) return;
        (, MockAggregatorV3.RoundData memory last) = feed.latestRoundRaw();
        int256 answer = last.answer > 0 ? last.answer : int256(2000 * 10 ** feed.decimals());
        uint256 kind = _mix(kindSeed) % 9;
        if (kind == 0) {
            feed.pushAnswer(0);
        } else if (kind == 1) {
            feed.pushAnswer(-answer);
        } else if (kind == 2) {
            uint256 heartbeat = onSecondary ? a.secondaryHeartbeat : a.primaryHeartbeat;
            uint256 age = _bound(amountSeed, heartbeat + 1, 3 days);
            if (age <= block.timestamp) feed.pushAnswerWithAge(answer, age);
        } else if (kind == 3) {
            feed.pushFutureAnswer(answer, _bound(amountSeed, 1, 1 hours));
        } else if (kind == 4) {
            feed.pushIncompleteRound(answer);
        } else if (kind == 5) {
            feed.pushCarriedOverRound(answer);
        } else if (kind == 6) {
            feed.setBehavior(MockAggregatorV3.Behavior.Revert);
        } else if (kind == 7) {
            feed.setBehavior(MockAggregatorV3.Behavior.ShortReturn);
        } else {
            uint192 minAnswer = onSecondary ? a.secondaryMin : a.primaryMin;
            feed.pushAnswer(int256(_bound(amountSeed, 1, uint256(minAnswer) - 1)));
        }
        _sample();
    }

    /// @notice The scenario the TWAP fallback exists for. The primary publishes a sane answer and keeps publishing for
    ///         one TWAP window, then goes silent until it is just stale (one heartbeat plus up to half a window).
    ///         Time passes in steps of a third of the window, during which every other healthy feed keeps publishing
    ///         and keepers keep recording, so a full window of history exists whenever the rest of the world allows
    ///         it. One call in two, the market then moves and the witness (if any) publishes an answer up to 15 %
    ///         away from the silent primary. Whether the soft router can bridge depends on everything else (sequencer,
    ///         witness, breaker, history), which the properties check against the reference model.
    function silencePrimary(uint256 assetSeed, uint256 lagSeed) external action {
        lagSeed = _mix(lagSeed);
        uint256 index = assetSeed % ASSET_COUNT;
        Asset storage a = _assets[index];
        (, MockAggregatorV3.RoundData memory last) = a.primary.latestRoundRaw();
        int256 answer = last.answer >= int256(uint256(a.primaryMin)) && last.answer <= int256(uint256(a.primaryMax))
            ? last.answer
            : int256(2000 * 10 ** a.primaryDecimals);
        a.primary.setBehavior(MockAggregatorV3.Behavior.Normal);
        a.primary.pushAnswer(answer);
        _keepersRecord();

        uint256 step = a.twapWindow / 3;
        uint256 silentFrom = block.timestamp + 3 * step;
        uint256 staleAt = silentFrom + a.primaryHeartbeat + 1 + _bound(lagSeed, 0, a.twapWindow / 2);
        while (block.timestamp + step < staleAt) {
            VM.warp(block.timestamp + step);
            for (uint256 i; i < ASSET_COUNT; ++i) {
                Asset storage other = _assets[i];
                if (i != index || block.timestamp <= silentFrom) {
                    _republishIfHealthy(other.primary, other.primaryHeartbeat, other.primaryMin, other.primaryMax);
                }
                if (address(other.secondary) != address(0)) {
                    _republishIfHealthy(
                        other.secondary, other.secondaryHeartbeat, other.secondaryMin, other.secondaryMax
                    );
                }
            }
            _keepersRecord();
        }
        VM.warp(staleAt);
        if (address(a.secondary) != address(0) && (lagSeed >> 128) % 2 == 0) {
            uint256 primaryWad = Math.mulDiv(uint256(answer), 1e18, 10 ** a.primaryDecimals);
            uint256 secondaryWad = primaryWad * _bound(lagSeed >> 136, 8500, 11_500) / 10_000;
            a.secondary.setBehavior(MockAggregatorV3.Behavior.Normal);
            a.secondary.pushAnswer(int256(Math.mulDiv(secondaryWad, 10 ** a.secondaryDecimals, 1e18)));
        }
        _sample();
    }

    /// @notice Sequencer incidents: an up sequencer goes down one call in sixteen; a down sequencer always comes back
    ///         up (starting its grace period). Every outage silences keepers and restarts every TWAP history, so they
    ///         are kept rare enough for full windows to be rebuilt in between.
    function toggleSequencer(uint256 seed) external action {
        if (sequencer.answer() == 0) {
            if (_mix(seed) % 16 == 0) sequencer.setDown();
        } else {
            sequencer.setUp();
        }
        _sample();
    }

    /// @notice A keeper round at the current time: every asset on both routers (most attempts are refused by the
    ///         spacing rule right after `warp`, or because the router would not serve `OK`).
    function recordObservation() external action {
        _keepersRecord();
        _sample();
    }

    // ============================================================================================================
    // Properties (each returns true when it holds)
    // ============================================================================================================

    /// @notice P1. `OK` is only ever returned for a fresh, positive, in-bounds primary behind a healthy sequencer,
    ///         and then equals the primary normalized in the caller's rounding.
    function property_okMeansHealthyInputs() public view returns (bool) {
        for (uint256 r; r < 2; ++r) {
            for (uint256 i; i < ASSET_COUNT; ++i) {
                for (uint256 k; k < 2; ++k) {
                    IPriceOracle.Intent intent = IPriceOracle.Intent(k);
                    (uint256 price, IPriceOracle.Status status) = _router(r).tryGetPrice(_assets[i].token, intent);
                    if (status != IPriceOracle.Status.OK) continue;
                    if (!_sequencerHealthy()) return false;
                    (FeedState state, uint256 answer) = _primaryState(i);
                    if (state != FeedState.Healthy) return false;
                    if (price != _toWad(answer, _assets[i].primaryDecimals, intent)) return false;
                }
            }
        }
        return true;
    }

    /// @notice P2. The headline property: never `OK` with a stale, zero, negative or out-of-bounds primary price.
    function property_neverOkWithStaleZeroOrOutOfBounds() public view returns (bool) {
        for (uint256 r; r < 2; ++r) {
            for (uint256 i; i < ASSET_COUNT; ++i) {
                (FeedState state,) = _primaryState(i);
                if (state == FeedState.Healthy) continue;
                for (uint256 k; k < 2; ++k) {
                    (uint256 price, IPriceOracle.Status status) =
                        _router(r).tryGetPrice(_assets[i].token, IPriceOracle.Intent(k));
                    if (status == IPriceOracle.Status.OK) return false;
                    // A broken primary may only be bridged by the soft router's TWAP (possibly as its conservative
                    // side): never by the broken answer itself.
                    if (price != 0 && (r == 0 || state != FeedState.StaleFamily)) return false;
                }
            }
        }
        return true;
    }

    /// @notice P3. A price is non-zero exactly when it is usable: OK, FALLBACK_USED, or DEVIATION in soft mode.
    function property_zeroPriceIffUnusable() public view returns (bool) {
        for (uint256 r; r < 2; ++r) {
            for (uint256 i; i < ASSET_COUNT; ++i) {
                for (uint256 k; k < 2; ++k) {
                    (uint256 price, IPriceOracle.Status status) =
                        _router(r).tryGetPrice(_assets[i].token, IPriceOracle.Intent(k));
                    bool usable = status == IPriceOracle.Status.OK || status == IPriceOracle.Status.FALLBACK_USED
                        || (status == IPriceOracle.Status.DEVIATION && r == 1);
                    if (usable != (price != 0)) return false;
                }
            }
        }
        return true;
    }

    /// @notice P4. `getPrice` returns exactly the non-zero price of `tryGetPrice`, and reverts exactly when it is zero.
    function property_revertingAndNonRevertingApisAgree() public view returns (bool) {
        for (uint256 r; r < 2; ++r) {
            for (uint256 i; i < ASSET_COUNT; ++i) {
                for (uint256 k; k < 2; ++k) {
                    IPriceOracle.Intent intent = IPriceOracle.Intent(k);
                    (uint256 price,) = _router(r).tryGetPrice(_assets[i].token, intent);
                    try _router(r).getPrice(_assets[i].token, intent) returns (uint256 value) {
                        if (price == 0 || value != price) return false;
                    } catch {
                        if (price != 0) return false;
                    }
                }
            }
        }
        return true;
    }

    /// @notice P5. While the sequencer is down or in its grace period nothing is priced, in either mode.
    function property_sequencerOutageBlocksEverything() public view returns (bool) {
        if (_sequencerHealthy()) return true;
        for (uint256 r; r < 2; ++r) {
            for (uint256 i; i < ASSET_COUNT; ++i) {
                for (uint256 k; k < 2; ++k) {
                    (uint256 price, IPriceOracle.Status status) =
                        _router(r).tryGetPrice(_assets[i].token, IPriceOracle.Intent(k));
                    if (price != 0) return false;
                    if (status != IPriceOracle.Status.SEQUENCER_DOWN && status != IPriceOracle.Status.GRACE_PERIOD) {
                        return false;
                    }
                }
            }
        }
        return true;
    }

    /// @notice P6. Strict is never looser than soft: whenever strict prices, soft returns the same price and status.
    function property_strictNeverLooserThanSoft() public view returns (bool) {
        for (uint256 i; i < ASSET_COUNT; ++i) {
            for (uint256 k; k < 2; ++k) {
                IPriceOracle.Intent intent = IPriceOracle.Intent(k);
                (uint256 strictPrice, IPriceOracle.Status strictStatus) =
                    strictRouter.tryGetPrice(_assets[i].token, intent);
                if (strictPrice == 0) continue;
                (uint256 softPrice, IPriceOracle.Status softStatus) = softRouter.tryGetPrice(_assets[i].token, intent);
                if (softPrice != strictPrice || softStatus != strictStatus) return false;
                if (strictStatus != IPriceOracle.Status.OK) return false;
            }
        }
        return true;
    }

    /// @notice P7. `FALLBACK_USED` only comes from the soft router, for a stale-family primary, and equals the
    ///         time-weighted mean of the accepted observations over the window (recomputed from the ghost log, which
    ///         never carries an answer across a gap or an outage).
    function property_fallbackIsExactTwapOfValidatedAnswers() public view returns (bool) {
        for (uint256 r; r < 2; ++r) {
            for (uint256 i; i < ASSET_COUNT; ++i) {
                for (uint256 k; k < 2; ++k) {
                    IPriceOracle.Intent intent = IPriceOracle.Intent(k);
                    (uint256 price, IPriceOracle.Status status) = _router(r).tryGetPrice(_assets[i].token, intent);
                    if (status != IPriceOracle.Status.FALLBACK_USED) continue;
                    if (r == 0) return false;
                    (FeedState state,) = _primaryState(i);
                    if (state != FeedState.StaleFamily) return false;
                    (bool available, uint256 twap) = _referenceTwap(1, i, intent);
                    if (!available || twap != price) return false;
                }
            }
        }
        return true;
    }

    /// @notice P8. Liveness of soft mode: with a healthy sequencer, a stale-family primary and a full, fresh window of
    ///         observations, the soft router always quotes (the TWAP, or the conservative side against a live
    ///         secondary that disagrees).
    function property_softBridgesWheneverItCan() public view returns (bool) {
        if (!_sequencerHealthy()) return true;
        for (uint256 i; i < ASSET_COUNT; ++i) {
            (FeedState state,) = _primaryState(i);
            if (state != FeedState.StaleFamily) continue;
            for (uint256 k; k < 2; ++k) {
                IPriceOracle.Intent intent = IPriceOracle.Intent(k);
                (bool available,) = _referenceTwap(1, i, intent);
                if (!available) continue;
                (uint256 price, IPriceOracle.Status status) = softRouter.tryGetPrice(_assets[i].token, intent);
                if (price == 0) return false;
                if (status != IPriceOracle.Status.FALLBACK_USED && status != IPriceOracle.Status.DEVIATION) {
                    return false;
                }
            }
        }
        return true;
    }

    /// @notice P9. Rounding is part of the API: a debt quote is never below the collateral quote of the same state.
    function property_debtNeverBelowCollateral() public view returns (bool) {
        for (uint256 r; r < 2; ++r) {
            for (uint256 i; i < ASSET_COUNT; ++i) {
                (uint256 collateral, IPriceOracle.Status cs) =
                    _router(r).tryGetPrice(_assets[i].token, IPriceOracle.Intent.Collateral);
                (uint256 debt, IPriceOracle.Status ds) =
                    _router(r).tryGetPrice(_assets[i].token, IPriceOracle.Intent.Debt);
                if (cs != ds) return false; // the status never depends on the intent
                if (debt < collateral) return false;
                if (cs == IPriceOracle.Status.OK || cs == IPriceOracle.Status.FALLBACK_USED) {
                    if (debt - collateral > 1) return false; // one rounding step apart at most
                }
            }
        }
        return true;
    }

    /// @notice P10. Every usable price lies within the normalized bounds of the feeds it can come from.
    function property_usablePricesWithinBounds() public view returns (bool) {
        for (uint256 r; r < 2; ++r) {
            for (uint256 i; i < ASSET_COUNT; ++i) {
                Asset storage a = _assets[i];
                uint256 lo = Math.mulDiv(a.primaryMin, 1e18, 10 ** a.primaryDecimals);
                uint256 hi = Math.mulDiv(a.primaryMax, 1e18, 10 ** a.primaryDecimals, Math.Rounding.Ceil);
                if (address(a.secondary) != address(0)) {
                    lo = Math.min(lo, Math.mulDiv(a.secondaryMin, 1e18, 10 ** a.secondaryDecimals));
                    hi = Math.max(hi, Math.mulDiv(a.secondaryMax, 1e18, 10 ** a.secondaryDecimals, Math.Rounding.Ceil));
                }
                for (uint256 k; k < 2; ++k) {
                    (uint256 price,) = _router(r).tryGetPrice(a.token, IPriceOracle.Intent(k));
                    if (price != 0 && (price < lo || price > hi)) return false;
                }
            }
        }
        return true;
    }

    // ============================================================================================================
    // Reference model (independent of the router's code)
    // ============================================================================================================

    enum FeedState {
        Healthy,
        StaleFamily, // unreadable, missing/future/old timestamp, carried-over round
        Invalid // zero, negative or out of bounds
    }

    function _primaryState(uint256 i) internal view returns (FeedState, uint256) {
        Asset storage a = _assets[i];
        return _feedState(a.primary, a.primaryHeartbeat, a.primaryMin, a.primaryMax);
    }

    function _feedState(MockAggregatorV3 feed, uint256 heartbeat, uint256 minAnswer, uint256 maxAnswer)
        internal
        view
        returns (FeedState, uint256)
    {
        (uint80 roundId, MockAggregatorV3.RoundData memory r) = feed.latestRoundRaw();
        bool unreadable = feed.behavior() != MockAggregatorV3.Behavior.Normal;
        // Readability is checked first by the router, then the sign: mirror that order.
        if (unreadable) return (FeedState.StaleFamily, 0);
        if (r.answer <= 0) return (FeedState.Invalid, 0);
        if (
            r.updatedAt == 0 || r.updatedAt > block.timestamp || block.timestamp - r.updatedAt > heartbeat
                || r.answeredInRound < roundId
        ) return (FeedState.StaleFamily, 0);
        uint256 answer = uint256(r.answer);
        if (answer < minAnswer || answer > maxAnswer) return (FeedState.Invalid, 0);
        return (FeedState.Healthy, answer);
    }

    function _sequencerHealthy() internal view returns (bool) {
        if (sequencer.reverts() || sequencer.answer() != 0) return false;
        uint256 startedAt = sequencer.startedAt();
        return startedAt != 0 && startedAt < block.timestamp && block.timestamp - startedAt > GRACE;
    }

    /// @dev TWAP from the ghost log: the last 64 observations since the last break, window ending at the newest,
    ///      fresh and fully covered.
    function _referenceTwap(uint256 routerIndex, uint256 i, IPriceOracle.Intent intent)
        internal
        view
        returns (bool available, uint256 price)
    {
        Observation[] storage log = _ghostObservations[routerIndex][i];
        uint256 n = log.length;
        uint256 oldest = n > WINDOW_CAPACITY ? n - WINDOW_CAPACITY : 0;
        uint256 historyStart = _ghostHistoryStart[routerIndex][i];
        if (historyStart > oldest) oldest = historyStart;
        if (n < oldest + 2) return (false, 0);
        uint256 window = _assets[i].twapWindow;
        uint256 newest = log[n - 1].timestamp;
        if (block.timestamp - newest > window || newest - log[oldest].timestamp < window) return (false, 0);
        uint256 sum = _windowSum(log, oldest, newest - window);
        uint256 denominator = window * 10 ** _assets[i].primaryDecimals;
        Math.Rounding rounding = intent == IPriceOracle.Intent.Debt ? Math.Rounding.Ceil : Math.Rounding.Floor;
        return (true, Math.mulDiv(sum, 1e18, denominator, rounding));
    }

    /// @dev Sum of answer * seconds from `from` to the newest observation, each answer holding until the next one.
    function _windowSum(Observation[] storage log, uint256 oldest, uint256 from) internal view returns (uint256 sum) {
        for (uint256 j = oldest; j + 1 < log.length; ++j) {
            uint256 lo = log[j].timestamp > from ? log[j].timestamp : from;
            uint256 hi = log[j + 1].timestamp;
            if (hi > lo) sum += log[j].answer * (hi - lo);
        }
    }

    function _toWad(uint256 answer, uint8 decimals, IPriceOracle.Intent intent) internal pure returns (uint256) {
        Math.Rounding rounding = intent == IPriceOracle.Intent.Debt ? Math.Rounding.Ceil : Math.Rounding.Floor;
        return Math.mulDiv(answer, 1e18, 10 ** decimals, rounding);
    }

    // ============================================================================================================
    // Internals
    // ============================================================================================================

    /// @dev Keepers try every asset on both routers; accepted observations are mirrored in the ghost log, and the
    ///      model decides on its own whether each one starts a new history.
    function _keepersRecord() internal {
        for (uint256 r; r < 2; ++r) {
            for (uint256 i; i < ASSET_COUNT; ++i) {
                Asset storage a = _assets[i];
                try _router(r).recordObservation(a.token) {
                    (, MockAggregatorV3.RoundData memory p) = a.primary.latestRoundRaw();
                    Observation[] storage log = _ghostObservations[r][i];
                    uint256 n = log.length;
                    if (n != 0) {
                        uint256 previous = log[n - 1].timestamp;
                        uint256 maxGap = Math.min(a.primaryHeartbeat, a.twapWindow);
                        if (block.timestamp - previous > maxGap || sequencer.startedAt() > previous) {
                            _ghostHistoryStart[r][i] = n;
                            ++historyRestarts;
                        }
                    }
                    log.push(Observation(block.timestamp, uint256(p.answer)));
                    ++observationsRecorded[r];
                } catch {}
            }
        }
    }

    /// @dev Runs after every action: records which statuses were reached and counts the states in which the
    ///      fallback properties have something to check.
    function _sample() internal {
        bool fallbackState;
        bool twapDeviationState;
        bool refusedState;
        for (uint256 r; r < 2; ++r) {
            for (uint256 i; i < ASSET_COUNT; ++i) {
                (, IPriceOracle.Status status) = _router(r).tryGetPrice(_assets[i].token, IPriceOracle.Intent.Debt);
                statusesSeen |= 1 << uint256(status);
                if (r == 0) continue;
                (FeedState state,) = _primaryState(i);
                if (status == IPriceOracle.Status.FALLBACK_USED) fallbackState = true;
                if (status == IPriceOracle.Status.DEVIATION && state == FeedState.StaleFamily) {
                    twapDeviationState = true;
                }
                if (status == IPriceOracle.Status.STALE) refusedState = true;
            }
        }
        if (fallbackState) ++fallbackStates;
        if (twapDeviationState) ++twapDeviationStates;
        if (refusedState) ++refusedFallbackStates;
        if (_sequencerHealthy()) {
            for (uint256 i; i < ASSET_COUNT; ++i) {
                (FeedState state,) = _primaryState(i);
                if (state != FeedState.StaleFamily) continue;
                (bool available,) = _referenceTwap(1, i, IPriceOracle.Intent.Debt);
                if (available) {
                    ++bridgeableStates;
                    break;
                }
            }
        }
    }

    /// @dev Every healthy feed publishes again (normal operation between two keeper rounds).
    function _republishHealthyFeeds() internal {
        for (uint256 i; i < ASSET_COUNT; ++i) {
            Asset storage a = _assets[i];
            _republishIfHealthy(a.primary, a.primaryHeartbeat, a.primaryMin, a.primaryMax);
            if (address(a.secondary) != address(0)) {
                _republishIfHealthy(a.secondary, a.secondaryHeartbeat, a.secondaryMin, a.secondaryMax);
            }
        }
    }

    /// @dev A feed in normal operation publishes at least once per heartbeat: re-push its answer if it is healthy.
    function _republishIfHealthy(MockAggregatorV3 feed, uint256 heartbeat, uint256 minAnswer, uint256 maxAnswer)
        internal
    {
        (FeedState state, uint256 answer) = _feedState(feed, heartbeat, minAnswer, maxAnswer);
        if (state == FeedState.Healthy) feed.pushAnswer(int256(answer));
    }

    /// @dev Fuzzers favor edge values (0, 1, max) for raw seeds; hashing keeps the documented frequencies.
    function _mix(uint256 seed) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed)));
    }

    function _router(uint256 r) internal view returns (OracleRouter) {
        return r == 0 ? strictRouter : softRouter;
    }

    function _asset(uint256 seed) internal view returns (Asset storage) {
        return _assets[seed % ASSET_COUNT];
    }

    function _paramsOf(uint256 i, IOracleRouter.Mode mode) internal view returns (IOracleRouter.AssetParams memory) {
        Asset storage a = _assets[i];
        return IOracleRouter.AssetParams({
            primary: IOracleRouter.FeedParams(address(a.primary), a.primaryHeartbeat, a.primaryMin, a.primaryMax),
            secondary: IOracleRouter.FeedParams(
                address(a.secondary), a.secondaryHeartbeat, a.secondaryMin, a.secondaryMax
            ),
            maxDeviationBps: a.maxDeviationBps,
            twapWindow: a.twapWindow,
            mode: mode
        });
    }

    function _newAsset(
        address token,
        uint8 primaryDecimals,
        uint8 secondaryDecimals,
        uint32 primaryHeartbeat,
        uint32 secondaryHeartbeat,
        uint16 maxDeviationBps,
        uint32 twapWindow,
        bool withSecondary
    ) internal returns (Asset memory a) {
        a.token = token;
        a.primary = new MockAggregatorV3(primaryDecimals, "primary");
        a.primaryDecimals = primaryDecimals;
        a.primaryHeartbeat = primaryHeartbeat;
        a.primaryMin = uint192(100 * 10 ** primaryDecimals);
        a.primaryMax = uint192(100_000 * 10 ** primaryDecimals);
        a.twapWindow = twapWindow;
        if (withSecondary) {
            a.secondary = new MockAggregatorV3(secondaryDecimals, "secondary");
            a.secondaryDecimals = secondaryDecimals;
            a.secondaryHeartbeat = secondaryHeartbeat;
            a.secondaryMin = uint192(100 * 10 ** secondaryDecimals);
            a.secondaryMax = uint192(100_000 * 10 ** secondaryDecimals);
            a.maxDeviationBps = maxDeviationBps;
        }
    }

    function _bound(uint256 x, uint256 lo, uint256 hi) internal pure returns (uint256) {
        return lo + x % (hi - lo + 1);
    }
}
