// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {OracleRouter} from "../../src/OracleRouter.sol";
import {IOracleRouter} from "../../src/interfaces/IOracleRouter.sol";
import {IPriceOracle} from "../../src/interfaces/IPriceOracle.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";
import {RouterTestBase} from "../utils/RouterTestBase.sol";

/// @notice The observation ring as seen through the router: who may record, when the TWAP fallback is served, and
///         that its value is the exact time-weighted mean of validated answers.
/// @dev Reference history used by most tests (window = 1 h, primary heartbeat = 1 h):
///      the primary answers a_k = 2000 + 10k USD at T0 + 10k minutes (k = 0..9) and then goes silent; keepers record
///      at every update and at T0 + 100, 110, 120 minutes. At T0 + 151 min the primary is stale (61 min old) while
///      the newest observation (T0 + 120 min) is 31 min old, so the fallback averages [T0 + 60, T0 + 120]:
///      (2060*10 + 2070*10 + 2080*10 + 2090*30) / 60 = 2080 USD, against a last spot of 2090 USD.
contract TwapFallbackTest is RouterTestBase {
    uint256 internal constant STALE_AT = T0 + 151 minutes;

    function _referenceHistory() internal {
        for (uint256 k = 0; k <= 9; ++k) {
            vm.warp(T0 + k * 10 minutes);
            int256 answer = 2000e8 + int256(k) * 10e8;
            primary.pushAnswer(answer);
            secondary.pushAnswer(answer * 1e10);
            _observeBoth();
        }
        for (uint256 m = 100; m <= 120; m += 10) {
            vm.warp(T0 + m * 1 minutes);
            _observeBoth();
        }
    }

    // ------------------------------------------------------------------------------------------------------------
    // Serving the fallback
    // ------------------------------------------------------------------------------------------------------------

    function test_StalePrimary_SoftServesExactTwap() public {
        _referenceHistory();
        vm.warp(STALE_AT);
        _assertQuoteBoth(softRouter, 2080e18, IPriceOracle.Status.FALLBACK_USED);
        assertEq(softRouter.getPrice(ASSET, COLLATERAL), 2080e18);
        (bool available, uint256 twap) = softRouter.consultTwap(ASSET, COLLATERAL);
        assertTrue(available);
        assertEq(twap, 2080e18);
    }

    function test_StalePrimary_StrictNeverFallsBack() public {
        _referenceHistory();
        vm.warp(STALE_AT);
        _assertQuoteBoth(strictRouter, 0, IPriceOracle.Status.STALE);
        _expectGetPriceRevert(
            strictRouter,
            abi.encodeWithSelector(
                IOracleRouter.StalePrice.selector, address(primary), T0 + 90 minutes, 61 minutes, PRIMARY_HEARTBEAT
            )
        );
        // The ring itself is fine: strict mode simply does not use it.
        (bool available,) = strictRouter.consultTwap(ASSET, COLLATERAL);
        assertTrue(available);
    }

    /// @notice The window start falls inside an interval; the sum there is interpolated exactly.
    function test_WindowStartingMidInterval_IsInterpolatedExactly() public {
        _referenceHistory();
        vm.warp(T0 + 125 minutes);
        softRouter.recordObservation(ASSET);
        vm.warp(STALE_AT);
        // [T0+65, T0+125]: 2060*5 + 2070*10 + 2080*10 + 2090*35 = 124,950 USD*min over 60 min = 2082.5 USD.
        _assertQuoteBoth(softRouter, 2082.5e18, IPriceOracle.Status.FALLBACK_USED);
    }

    /// @notice A non-terminating average is rounded once, down for collateral and up for debt.
    function test_TwapRounding_FollowsIntent() public {
        // 2000e8 for 20 min then 2000e8 + 1 for 40 min: mean = 2000e8 + 2/3 raw units = 2000e18 + 6,666,666,666.67 wei.
        primary.pushAnswer(2000e8);
        softRouter.recordObservation(ASSET);
        vm.warp(T0 + 20 minutes);
        primary.pushAnswer(2000e8 + 1);
        softRouter.recordObservation(ASSET);
        vm.warp(T0 + 60 minutes);
        softRouter.recordObservation(ASSET);
        vm.warp(T0 + 60 minutes + PRIMARY_HEARTBEAT + 1 - 40 minutes);
        _assertQuote(softRouter, COLLATERAL, 2000e18 + 6_666_666_666, IPriceOracle.Status.FALLBACK_USED);
        _assertQuote(softRouter, DEBT, 2000e18 + 6_666_666_667, IPriceOracle.Status.FALLBACK_USED);
    }

    /// @notice Every STALE-family cause is bridged, not only an old `updatedAt`.
    function test_EveryStaleCause_IsBridged() public {
        _referenceHistory();
        vm.warp(T0 + 121 minutes);
        uint256 snapshot = vm.snapshotState();

        primary.pushIncompleteRound(2090e8);
        _assertQuoteBoth(softRouter, 2080e18, IPriceOracle.Status.FALLBACK_USED);
        vm.revertToState(snapshot);

        primary.pushFutureAnswer(2090e8, 1);
        _assertQuoteBoth(softRouter, 2080e18, IPriceOracle.Status.FALLBACK_USED);
        vm.revertToState(snapshot);

        primary.pushCarriedOverRound(2090e8);
        _assertQuoteBoth(softRouter, 2080e18, IPriceOracle.Status.FALLBACK_USED);
        vm.revertToState(snapshot);

        primary.setBehavior(MockAggregatorV3.Behavior.Revert);
        _assertQuoteBoth(softRouter, 2080e18, IPriceOracle.Status.FALLBACK_USED);
        vm.revertToState(snapshot);

        primary.setBehavior(MockAggregatorV3.Behavior.ShortReturn);
        _assertQuoteBoth(softRouter, 2080e18, IPriceOracle.Status.FALLBACK_USED);
    }

    /// @notice A primary that is actively wrong (zero, negative, out of bounds) is never bridged: the cause is unknown
    ///         and a lagging average would hide a real crash below the bounds.
    function test_ActiveMalfunctions_AreNeverBridged() public {
        _referenceHistory();
        vm.warp(T0 + 121 minutes);
        primary.pushAnswer(0);
        _assertQuoteBoth(softRouter, 0, IPriceOracle.Status.ZERO);
        primary.pushAnswer(-2090e8);
        _assertQuoteBoth(softRouter, 0, IPriceOracle.Status.NEGATIVE);
        primary.pushAnswer(99e8);
        _assertQuoteBoth(softRouter, 0, IPriceOracle.Status.OUT_OF_BOUNDS);
    }

    // ------------------------------------------------------------------------------------------------------------
    // When the fallback is not available
    // ------------------------------------------------------------------------------------------------------------

    function test_HistoryShorterThanWindow_IsNotBridged() public {
        vm.warp(T0 + 30 minutes);
        primary.pushAnswer(2000e8);
        softRouter.recordObservation(ASSET);
        vm.warp(T0 + 89 minutes);
        softRouter.recordObservation(ASSET);
        // 59 minutes of history for a 60-minute window.
        vm.warp(T0 + 91 minutes);
        _assertQuoteBoth(softRouter, 0, IPriceOracle.Status.STALE);
        (bool available, uint256 twap) = softRouter.consultTwap(ASSET, DEBT);
        assertFalse(available);
        assertEq(twap, 0);
    }

    function test_SingleObservation_IsNotBridged() public {
        softRouter.recordObservation(ASSET);
        vm.warp(T0 + PRIMARY_HEARTBEAT + 1);
        _assertQuoteBoth(softRouter, 0, IPriceOracle.Status.STALE);
    }

    function test_NewestObservationExactlyOneWindowOld_IsStillServed() public {
        _referenceHistory();
        vm.warp(T0 + 120 minutes + TWAP_WINDOW);
        _assertQuoteBoth(softRouter, 2080e18, IPriceOracle.Status.FALLBACK_USED);
    }

    function test_NewestObservationOlderThanWindow_Expires() public {
        _referenceHistory();
        vm.warp(T0 + 120 minutes + TWAP_WINDOW + 1);
        _assertQuoteBoth(softRouter, 0, IPriceOracle.Status.STALE);
        _expectGetPriceRevert(
            softRouter,
            abi.encodeWithSelector(
                IOracleRouter.StalePrice.selector, address(primary), T0 + 90 minutes, 90 minutes + 1, PRIMARY_HEARTBEAT
            )
        );
    }

    function test_TwapDisabled_SoftBehavesLikeStrictOnStale() public {
        IOracleRouter.AssetParams memory p = _params(IOracleRouter.Mode.Soft);
        p.twapWindow = 0;
        OracleRouter router = _deployRouter(p);
        vm.expectRevert(abi.encodeWithSelector(IOracleRouter.TwapDisabled.selector, ASSET));
        router.recordObservation(ASSET);
        vm.warp(T0 + PRIMARY_HEARTBEAT + 1);
        _assertQuoteBoth(router, 0, IPriceOracle.Status.STALE);
        (bool available, uint256 twap) = router.consultTwap(ASSET, COLLATERAL);
        assertFalse(available);
        assertEq(twap, 0);
    }

    // ------------------------------------------------------------------------------------------------------------
    // The TWAP still faces the deviation breaker
    // ------------------------------------------------------------------------------------------------------------

    /// @notice The market moved while the primary was silent: a live secondary 10 % lower catches the lagging TWAP.
    function test_TwapDeviatingFromLiveSecondary_QuotesConservativeSide() public {
        _referenceHistory();
        vm.warp(STALE_AT);
        secondary.pushAnswer(1872e18);
        _assertQuote(softRouter, COLLATERAL, 1872e18, IPriceOracle.Status.DEVIATION);
        _assertQuote(softRouter, DEBT, 2080e18, IPriceOracle.Status.DEVIATION);
    }

    function test_TwapWithDeadSecondary_IsServedAlone() public {
        _referenceHistory();
        vm.warp(STALE_AT);
        secondary.setBehavior(MockAggregatorV3.Behavior.Revert);
        _assertQuoteBoth(softRouter, 2080e18, IPriceOracle.Status.FALLBACK_USED);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Recording
    // ------------------------------------------------------------------------------------------------------------

    function test_Record_EmitsAndAccumulates() public {
        vm.expectEmit(address(softRouter));
        emit IOracleRouter.ObservationRecorded(ASSET, 0, T0, 2000e8, 0);
        softRouter.recordObservation(ASSET);

        vm.warp(T0 + 10 minutes);
        primary.pushAnswer(2010e8);
        vm.expectEmit(address(softRouter));
        emit IOracleRouter.ObservationRecorded(ASSET, 1, T0 + 10 minutes, 2010e8, 2000e8 * 600);
        uint256 index = softRouter.recordObservation(ASSET);
        assertEq(index, 1);

        (uint256 newest, uint256 cardinality, uint256 lastAnswer) = softRouter.getRingState(ASSET);
        assertEq(newest, 1);
        assertEq(cardinality, 2);
        assertEq(lastAnswer, 2010e8);
        (uint32 timestamp, uint224 cumulative) = softRouter.getObservation(ASSET, 1);
        assertEq(timestamp, T0 + 10 minutes);
        assertEq(cumulative, 2000e8 * 600);
    }

    function test_Record_EnforcesSpacing() public {
        softRouter.recordObservation(ASSET);
        uint256 spacing = TWAP_WINDOW / 32; // 112 s
        vm.warp(T0 + spacing - 1);
        vm.expectRevert(abi.encodeWithSelector(IOracleRouter.ObservationTooSoon.selector, ASSET, spacing - 1, spacing));
        softRouter.recordObservation(ASSET);
        vm.warp(T0 + spacing);
        softRouter.recordObservation(ASSET);
    }

    function test_Record_RejectsAnythingButOk() public {
        primary.pushAnswerWithAge(2000e8, PRIMARY_HEARTBEAT + 1);
        vm.expectRevert(
            abi.encodeWithSelector(IOracleRouter.PriceNotObservable.selector, ASSET, IPriceOracle.Status.STALE)
        );
        softRouter.recordObservation(ASSET);

        primary.pushAnswer(2000e8);
        secondary.pushAnswer(1000e18);
        vm.expectRevert(
            abi.encodeWithSelector(IOracleRouter.PriceNotObservable.selector, ASSET, IPriceOracle.Status.DEVIATION)
        );
        softRouter.recordObservation(ASSET);
    }

    function test_GetObservation_RejectsIndexBeyondRing() public {
        vm.expectRevert(abi.encodeWithSelector(IOracleRouter.ObservationIndexOutOfRange.selector, 64));
        softRouter.getObservation(ASSET, 64);
    }

    function test_Record_UnknownAssetReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IOracleRouter.AssetNotConfigured.selector, address(0xBEEF)));
        softRouter.recordObservation(address(0xBEEF));
    }

    /// @notice Recording as fast as allowed for hours still leaves more than one window of history in 64 slots,
    ///         and the TWAP read across the wrapped ring is exact.
    /// @dev 200 observations 112 s apart (the minimum spacing); the primary moves every 20 observations (2,240 s) to
    ///      2000 + j USD. Newest observation at T0 + 22,288; the window [T0 + 18,688, T0 + 22,288] holds 2008 USD for
    ///      1,472 s and 2009 USD for 2,128 s.
    function test_RingRollover_KeepsAtLeastOneWindow() public {
        uint256 spacing = TWAP_WINDOW / 32;
        for (uint256 i = 0; i < 200; ++i) {
            vm.warp(T0 + i * spacing);
            if (i % 20 == 0) primary.pushAnswer(2000e8 + int256(i / 20) * 1e8);
            softRouter.recordObservation(ASSET);
        }
        (uint256 newest, uint256 cardinality,) = softRouter.getRingState(ASSET);
        assertEq(cardinality, 64);
        assertEq(newest, 199 % 64);

        uint256 sum = 2008e8 * 1472 + 2009e8 * 2128;
        uint256 floorPrice = sum * 1e10 / 3600;
        uint256 ceilPrice = (sum * 1e10 + 3599) / 3600;
        assertEq(ceilPrice, floorPrice + 1, "non-terminating mean");

        vm.warp(T0 + 180 * spacing + PRIMARY_HEARTBEAT + 1); // primary (last update at i = 180) just went stale
        _assertQuote(softRouter, COLLATERAL, floorPrice, IPriceOracle.Status.FALLBACK_USED);
        _assertQuote(softRouter, DEBT, ceilPrice, IPriceOracle.Status.FALLBACK_USED);
    }

    function test_Reconfiguration_ResetsHistory() public {
        _referenceHistory();
        (, uint256 cardinality,) = softRouter.getRingState(ASSET);
        assertEq(cardinality, 13);
        bytes memory data = abi.encodeCall(IOracleRouter.setAssetConfig, (ASSET, _params(IOracleRouter.Mode.Soft)));
        _scheduleConfig(softRouter, data);
        vm.expectEmit(address(softRouter));
        emit IOracleRouter.ObservationsReset(ASSET);
        vm.prank(governance);
        softRouter.setAssetConfig(ASSET, _params(IOracleRouter.Mode.Soft));
        (, cardinality,) = softRouter.getRingState(ASSET);
        assertEq(cardinality, 0);
        (bool available,) = softRouter.consultTwap(ASSET, COLLATERAL);
        assertFalse(available);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Gaps: no answer is carried across a silence longer than min(heartbeat, window), nor across an outage
    // ------------------------------------------------------------------------------------------------------------

    /// @dev Regression for review finding 1 (proof of concept 1): one observation at 2,100 USD, then three days in
    ///      which the primary is healthy at 1,900 USD but nobody records, then one fresh observation. Before the fix
    ///      the window ending at that observation was 2,100 USD for its whole length and the soft router served
    ///      the three-day-old answer as `FALLBACK_USED`.
    function test_RecordingGap_DiscardsHistory_PrimaryOnly() public {
        OracleRouter soft = _deployRouter(_primaryOnlyParams(IOracleRouter.Mode.Soft));
        _threeSilentDays(soft);
        (, uint256 cardinality, uint256 lastAnswer) = soft.getRingState(ASSET);
        assertEq(cardinality, 1, "only the post-gap observation remains");
        assertEq(lastAnswer, 1900e8);

        vm.warp(T0 + 3 days - 10 minutes + PRIMARY_HEARTBEAT + 1); // the primary just went stale
        _assertQuoteBoth(soft, 0, IPriceOracle.Status.STALE);
        _expectGetPriceRevert(
            soft,
            abi.encodeWithSelector(
                IOracleRouter.StalePrice.selector,
                address(primary),
                T0 + 3 days - 10 minutes,
                PRIMARY_HEARTBEAT + 1,
                PRIMARY_HEARTBEAT
            )
        );
        (bool available,) = soft.consultTwap(ASSET, COLLATERAL);
        assertFalse(available);
    }

    /// @dev Regression for review finding 1 (proof of concept 2): the same gap on the default soft router, whose
    ///      witness then dies, so the deviation breaker cannot catch the old answer either.
    function test_RecordingGap_DiscardsHistory_DeadWitness() public {
        _threeSilentDays(softRouter);
        vm.warp(T0 + 3 days - 10 minutes + PRIMARY_HEARTBEAT + 1);
        secondary.setBehavior(MockAggregatorV3.Behavior.Revert);
        _assertQuoteBoth(softRouter, 0, IPriceOracle.Status.STALE);
    }

    /// @dev Regression for review finding 1 (proof of concept 3): one hour of history at 2,100 USD, a 5-hour
    ///      sequencer outage and its 1-hour grace period, during which the market fell to 1,800 USD. Before the fix
    ///      the first post-outage observation turned the pre-outage price into a `FALLBACK_USED` quote.
    function test_SequencerOutage_DiscardsHistory() public {
        OracleRouter soft = _deployRouter(_primaryOnlyParams(IOracleRouter.Mode.Soft));
        for (uint256 m = 0; m <= 60; m += 5) {
            vm.warp(T0 + m * 1 minutes);
            primary.pushAnswer(2100e8);
            soft.recordObservation(ASSET);
        }
        sequencer.setDown();
        vm.warp(T0 + 6 hours);
        sequencer.setUp();
        vm.warp(T0 + 6 hours + 30 minutes);
        primary.pushAnswer(1800e8);
        vm.warp(T0 + 7 hours + 1);
        vm.expectEmit(address(soft));
        emit IOracleRouter.ObservationHistoryRestarted(ASSET, 6 hours + 1, 1 hours);
        soft.recordObservation(ASSET);

        vm.warp(T0 + 7 hours + 30 minutes + 1);
        _assertQuoteBoth(soft, 0, IPriceOracle.Status.STALE);
    }

    /// @notice A sequencer outage restarts the history even when the silence it caused is shorter than
    ///         `min(heartbeat, window)`: nothing recorded before an outage is ever averaged after it.
    /// @dev Heartbeat 24 h and window 4 h (so the gap limit is 4 h); a 10-minute outage plus the 1-hour grace period
    ///      leaves a 70-minute silence, well within 4 h, but the sequencer has only been up for 1 h + 1 s.
    function test_SequencerOutage_RestartsHistoryEvenWithinMaxGap() public {
        OracleRouter soft = _fourHourWindowRouter();
        sequencer.setDown();
        vm.warp(T0 + 250 minutes);
        sequencer.setUp();
        vm.warp(T0 + 310 minutes + 1);
        vm.expectEmit(address(soft));
        emit IOracleRouter.ObservationHistoryRestarted(ASSET, 70 minutes + 1, 1 hours + 1);
        soft.recordObservation(ASSET);
        primary.setBehavior(MockAggregatorV3.Behavior.Revert);
        _assertQuoteBoth(soft, 0, IPriceOracle.Status.STALE);
    }

    /// @notice Control for the test above: the same 70-minute keeper pause without an outage is bridged.
    function test_KeeperPauseWithinMaxGap_IsBridged() public {
        OracleRouter soft = _fourHourWindowRouter();
        vm.warp(T0 + 310 minutes + 1);
        vm.recordLogs();
        soft.recordObservation(ASSET);
        assertEq(vm.getRecordedLogs().length, 1, "ObservationRecorded only, no restart");
        primary.setBehavior(MockAggregatorV3.Behavior.Revert);
        _assertQuoteBoth(soft, 2000e18, IPriceOracle.Status.FALLBACK_USED);
    }

    /// @notice The gap limit is the shorter of the primary heartbeat and the TWAP window, and a gap of exactly that
    ///         length is still bridged.
    function test_MaxGap_IsTheShorterOfHeartbeatAndWindow() public {
        // Heartbeat 2 h, window 1 h: the limit is the window.
        IOracleRouter.AssetParams memory p = _primaryOnlyParams(IOracleRouter.Mode.Soft);
        p.primary.heartbeat = 2 hours;
        OracleRouter windowBound = _deployRouter(p);
        windowBound.recordObservation(ASSET);
        vm.warp(T0 + 1 hours);
        vm.recordLogs();
        windowBound.recordObservation(ASSET);
        assertEq(vm.getRecordedLogs().length, 1, "a gap of exactly one window is bridged");
        vm.warp(T0 + 2 hours + 1);
        primary.pushAnswer(2000e8);
        vm.expectEmit(address(windowBound));
        emit IOracleRouter.ObservationHistoryRestarted(ASSET, 1 hours + 1, 1 hours);
        windowBound.recordObservation(ASSET);

        // Heartbeat 45 min, window 2 h: the limit is the heartbeat.
        p.primary.heartbeat = 45 minutes;
        p.twapWindow = 2 hours;
        OracleRouter heartbeatBound = _deployRouter(p);
        heartbeatBound.recordObservation(ASSET);
        vm.warp(block.timestamp + 45 minutes + 1);
        primary.pushAnswer(2000e8);
        vm.expectEmit(address(heartbeatBound));
        emit IOracleRouter.ObservationHistoryRestarted(ASSET, 45 minutes + 1, 45 minutes);
        heartbeatBound.recordObservation(ASSET);
    }

    /// @notice After a restart the fallback comes back once keepers have covered a full window of new observations,
    ///         and then averages only those.
    function test_AfterARestart_FallbackNeedsAFullNewWindow() public {
        OracleRouter soft = _deployRouter(_primaryOnlyParams(IOracleRouter.Mode.Soft));
        _threeSilentDays(soft);
        for (uint256 m = 10; m <= 90; m += 10) {
            vm.warp(T0 + 3 days + m * 1 minutes);
            if (m <= 30) primary.pushAnswer(1900e8);
            soft.recordObservation(ASSET);
        }
        vm.warp(T0 + 3 days + 90 minutes + 1); // last primary update at +30 min: stale now
        _assertQuoteBoth(soft, 1900e18, IPriceOracle.Status.FALLBACK_USED);
    }

    /// @dev One observation at 2,100 USD at T0, the primary healthy at 1,900 USD for three days with no keeper, then
    ///      one observation at T0 + 3 days that restarts the history.
    function _threeSilentDays(OracleRouter router) internal {
        primary.pushAnswer(2100e8);
        secondary.pushAnswer(2100e18);
        router.recordObservation(ASSET);
        for (uint256 h = 1; h <= 72; ++h) {
            vm.warp(T0 + h * 1 hours - 10 minutes);
            primary.pushAnswer(1900e8);
            secondary.pushAnswer(1900e18);
        }
        vm.warp(T0 + 3 days);
        vm.expectEmit(address(router));
        emit IOracleRouter.ObservationHistoryRestarted(ASSET, 3 days, PRIMARY_HEARTBEAT);
        vm.expectEmit(address(router));
        emit IOracleRouter.ObservationRecorded(ASSET, 0, T0 + 3 days, 1900e8, 0);
        router.recordObservation(ASSET);
    }

    /// @dev A primary-only soft router with a 24 h heartbeat and a 4 h window, and four hours of observations at
    ///      2,000 USD, every 10 minutes, ending at T0 + 240 min.
    function _fourHourWindowRouter() internal returns (OracleRouter soft) {
        IOracleRouter.AssetParams memory p = _primaryOnlyParams(IOracleRouter.Mode.Soft);
        p.primary.heartbeat = 1 days;
        p.twapWindow = 4 hours;
        soft = _deployRouter(p);
        for (uint256 m = 0; m <= 240; m += 10) {
            vm.warp(T0 + m * 1 minutes);
            soft.recordObservation(ASSET);
        }
    }

    // ------------------------------------------------------------------------------------------------------------
    // Witness rule: the ring only holds answers the secondary confirmed
    // ------------------------------------------------------------------------------------------------------------

    /// @dev Regression for review finding 6: a soft asset served its primary alone while the witness was dead, and
    ///      keepers recorded that unchecked answer. Soft mode still serves it, but no longer stores it.
    function test_Record_SoftAssetWithDeadWitness_IsRefused() public {
        secondary.setBehavior(MockAggregatorV3.Behavior.Revert);
        _assertQuoteBoth(softRouter, 2000e18, IPriceOracle.Status.OK);
        vm.expectRevert(
            abi.encodeWithSelector(IOracleRouter.WitnessUnavailable.selector, ASSET, IPriceOracle.Status.STALE)
        );
        softRouter.recordObservation(ASSET);
        // A strict asset already refuses to price, hence to record, without its witness.
        vm.expectRevert(
            abi.encodeWithSelector(IOracleRouter.PriceNotObservable.selector, ASSET, IPriceOracle.Status.STALE)
        );
        strictRouter.recordObservation(ASSET);
    }

    function test_Record_SoftAssetWithUnhealthyWitness_IsRefused() public {
        uint256 snapshot = vm.snapshotState();
        secondary.pushAnswerWithAge(SECONDARY_PRICE, SECONDARY_HEARTBEAT + 1);
        _expectWitnessUnavailable(IPriceOracle.Status.STALE);
        vm.revertToState(snapshot);

        secondary.pushAnswer(0);
        _expectWitnessUnavailable(IPriceOracle.Status.ZERO);
        vm.revertToState(snapshot);

        secondary.pushAnswer(-1);
        _expectWitnessUnavailable(IPriceOracle.Status.NEGATIVE);
        vm.revertToState(snapshot);

        secondary.pushAnswer(99e18);
        _expectWitnessUnavailable(IPriceOracle.Status.OUT_OF_BOUNDS);
        vm.revertToState(snapshot);

        // The witness comes back: recording resumes.
        secondary.pushAnswer(SECONDARY_PRICE);
        assertEq(softRouter.recordObservation(ASSET), 0);
    }

    function test_Record_PrimaryOnlySoftAsset_NeedsNoWitness() public {
        OracleRouter soft = _deployRouter(_primaryOnlyParams(IOracleRouter.Mode.Soft));
        assertEq(soft.recordObservation(ASSET), 0);
    }

    function _expectWitnessUnavailable(IPriceOracle.Status witnessStatus) internal {
        _assertQuoteBoth(softRouter, 2000e18, IPriceOracle.Status.OK);
        vm.expectRevert(abi.encodeWithSelector(IOracleRouter.WitnessUnavailable.selector, ASSET, witnessStatus));
        softRouter.recordObservation(ASSET);
    }

    // ------------------------------------------------------------------------------------------------------------
    // consultTwap is a diagnostic view, but it never reports a TWAP during a sequencer outage
    // ------------------------------------------------------------------------------------------------------------

    /// @dev Regression for review finding 7: `consultTwap` used to return a TWAP while the sequencer was down.
    function test_ConsultTwap_IsUnavailableWhileTheSequencerIsUnhealthy() public {
        _referenceHistory();
        vm.warp(T0 + 125 minutes);
        uint256 snapshot = vm.snapshotState();
        (bool available, uint256 price) = softRouter.consultTwap(ASSET, COLLATERAL);
        assertTrue(available, "healthy sequencer: available");
        assertEq(price, 2080e18);

        sequencer.setDown();
        _assertConsultUnavailable();
        vm.revertToState(snapshot);

        sequencer.setDown();
        vm.warp(T0 + 126 minutes);
        sequencer.setUp(); // grace period until T0 + 186 min
        vm.warp(T0 + 130 minutes);
        _assertConsultUnavailable();
        vm.revertToState(snapshot);

        sequencer.setReverts(true);
        _assertConsultUnavailable();
    }

    function _assertConsultUnavailable() internal view {
        (bool available, uint256 price) = softRouter.consultTwap(ASSET, COLLATERAL);
        assertFalse(available);
        assertEq(price, 0);
        (available, price) = strictRouter.consultTwap(ASSET, DEBT);
        assertFalse(available);
        assertEq(price, 0);
    }
}
