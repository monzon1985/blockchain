// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IPriceOracle} from "../../src/interfaces/IPriceOracle.sol";
import {FeedReader} from "../../src/libraries/FeedReader.sol";
import {ObservationRing} from "../../src/libraries/ObservationRing.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";
import {
    FeedReaderHarness,
    FourWordFeed,
    ObservationRingHarness,
    PriceMathHarness,
    ReturnBombFeed
} from "../utils/Harnesses.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Unit tests of the three libraries in isolation.
contract ObservationRingTest is Test {
    /// @dev A gap limit that never triggers, for tests about everything but the gap rule.
    uint32 internal constant NO_GAP_LIMIT = type(uint32).max;

    ObservationRingHarness internal ring;

    function setUp() public {
        ring = new ObservationRingHarness();
    }

    function test_FirstObservation_StartsAtZero() public {
        (uint8 index, uint224 cumulative, bool restarted) = ring.record(1000, 5, NO_GAP_LIMIT);
        assertEq(index, 0);
        assertEq(cumulative, 0);
        assertFalse(restarted, "an empty ring is started, not restarted");
        assertEq(ring.header().cardinality, 1);
        assertEq(ring.header().lastAnswer, 5);
        (bool available,) = ring.consult(1000, 60);
        assertFalse(available, "one observation is not a window");
    }

    function test_Accumulates_PreviousAnswerTimesElapsed() public {
        ring.record(1000, 5, NO_GAP_LIMIT);
        (, uint224 cumulative,) = ring.record(1060, 7, NO_GAP_LIMIT);
        assertEq(cumulative, 5 * 60);
        (, cumulative,) = ring.record(1100, 9, NO_GAP_LIMIT);
        assertEq(cumulative, 5 * 60 + 7 * 40);
    }

    function test_DuplicateTimestamp_Reverts() public {
        ring.record(1000, 5, NO_GAP_LIMIT);
        vm.expectRevert(abi.encodeWithSelector(ObservationRing.DuplicateTimestamp.selector, uint32(1000)));
        ring.record(1000, 6, NO_GAP_LIMIT);
    }

    function test_IndexWrapsAfter64() public {
        for (uint32 i = 0; i < 64; ++i) {
            ring.record(1000 + i * 10, 1, NO_GAP_LIMIT);
        }
        assertEq(ring.header().newest, 63);
        assertEq(ring.header().cardinality, 64);
        (uint8 index,,) = ring.record(2000, 1, NO_GAP_LIMIT);
        assertEq(index, 0);
        assertEq(ring.header().cardinality, 64);
        assertEq(ring.observation(0).timestamp, 2000);
    }

    function test_Consult_ExactWindowAndInterpolation() public {
        ring.record(0 + 1000, 10, NO_GAP_LIMIT); // 10 on [1000, 1100)
        ring.record(1100, 20, NO_GAP_LIMIT); // 20 on [1100, 1300)
        ring.record(1300, 30, NO_GAP_LIMIT); // 30 on [1300, 1400]
        ring.record(1400, 40, NO_GAP_LIMIT);
        // Window of 250 s ending at 1400: [1150, 1400] = 20*150 + 30*100 = 6000.
        (bool available, uint256 delta) = ring.consult(1400, 250);
        assertTrue(available);
        assertEq(delta, 6000);
        // Window exactly aligned on an observation: [1100, 1400] = 20*200 + 30*100.
        (available, delta) = ring.consult(1400, 300);
        assertEq(delta, 7000);
        // Whole history: [1000, 1400].
        (available, delta) = ring.consult(1400, 400);
        assertEq(delta, 8000);
    }

    function test_Consult_UnavailableWhenTooShortOrExpired() public {
        ring.record(1000, 10, NO_GAP_LIMIT);
        ring.record(1100, 20, NO_GAP_LIMIT);
        (bool available,) = ring.consult(1100, 101);
        assertFalse(available, "history shorter than window");
        (available,) = ring.consult(1200, 100);
        assertTrue(available, "newest exactly one window old");
        (available,) = ring.consult(1201, 100);
        assertFalse(available, "newest older than window");
    }

    function test_Reset_ForgetsHistory() public {
        assertFalse(ring.reset(), "empty ring");
        ring.record(1000, 10, NO_GAP_LIMIT);
        ring.record(1100, 20, NO_GAP_LIMIT);
        assertTrue(ring.reset());
        assertEq(ring.header().cardinality, 0);
        (bool available,) = ring.consult(1100, 50);
        assertFalse(available);
        (uint8 index, uint224 cumulative,) = ring.record(5000, 1, NO_GAP_LIMIT);
        assertEq(index, 0);
        assertEq(cumulative, 0);
    }

    // ------------------------------------------------------------------------------------------------------------
    // The gap rule: no answer is carried across more than `maxGap` seconds
    // ------------------------------------------------------------------------------------------------------------

    /// @notice A gap of exactly `maxGap` is still bridged; one second more restarts the history.
    function test_GapOfExactlyMaxGap_IsCarried_OneSecondMoreRestarts() public {
        ring.record(1000, 10, 100);
        (uint8 index, uint224 cumulative, bool restarted) = ring.record(1100, 20, 100);
        assertFalse(restarted, "a gap of exactly maxGap is carried");
        assertEq(index, 1);
        assertEq(cumulative, 10 * 100);

        (index, cumulative, restarted) = ring.record(1201, 30, 100);
        assertTrue(restarted, "one second over maxGap restarts");
        assertEq(index, 0);
        assertEq(cumulative, 0);
        assertEq(ring.header().newest, 0);
        assertEq(ring.header().cardinality, 1);
        assertEq(ring.header().lastAnswer, 30);
        assertEq(ring.observation(0).timestamp, 1201);
        (bool available,) = ring.consult(1201, 50);
        assertFalse(available, "a restarted ring holds a single observation");
    }

    /// @notice The reviewer's scenario on the library: an answer recorded before a long silence never reaches the
    ///         window that ends at the first observation after it. Without the gap rule the window below would be
    ///         2100 for its full length.
    function test_AncientAnswer_IsNeverCarriedIntoTheWindow() public {
        uint32 hour = 3600;
        ring.record(10_000, 2100, hour);
        ring.record(10_000 + 3 days, 1900, hour); // 3 days of silence: restart
        (bool available,) = ring.consult(10_000 + 3 days + 30 minutes, hour);
        assertFalse(available, "nothing to average yet");
        for (uint32 m = 10; m <= 60; m += 10) {
            ring.record(10_000 + 3 days + m * 60, 1900, hour);
        }
        uint256 delta;
        (available, delta) = ring.consult(10_000 + 3 days + 60 minutes, hour);
        assertTrue(available, "a full window of new observations");
        assertEq(delta, uint256(1900) * hour, "only the new answer is averaged");
    }

    /// @notice A restart in a full ring forgets every slot: the window never mixes the two histories.
    function test_RestartOfAFullRing_ForgetsEverySlot() public {
        for (uint32 i = 0; i < 70; ++i) {
            ring.record(1000 + i * 10, 7, 10);
        }
        assertEq(ring.header().cardinality, 64);
        (,, bool restarted) = ring.record(1690 + 11, 9, 10); // 11 s after the newest (1690)
        assertTrue(restarted);
        assertEq(ring.header().cardinality, 1);
        ring.record(1711, 11, 10);
        ring.record(1721, 13, 10);
        // [1701, 1721] = 9*10 + 11*10; the old answer 7 never contributes.
        (bool available, uint256 delta) = ring.consult(1721, 20);
        assertTrue(available);
        assertEq(delta, 9 * 10 + 11 * 10);
        (available,) = ring.consult(1721, 21);
        assertFalse(available, "the history before the restart is gone");
    }

    /// @notice Timestamps are 32-bit: a history that straddles 2^32 (year 2106) is still averaged exactly.
    function test_TimestampWrap_IsTolerated() public {
        uint32 start = type(uint32).max - 150; // 150 s before the wrap
        ring.record(start, 10, NO_GAP_LIMIT);
        unchecked {
            ring.record(start + 100, 20, NO_GAP_LIMIT); // still before the wrap
            (,, bool restarted) = ring.record(start + 300, 30, 200); // wrapped: small absolute value, 200 s gap
            assertFalse(restarted, "the gap is measured across the wrap");
            assertLt(start + 300, start);
            (bool available, uint256 delta) = ring.consult(start + 310, 250);
            // Window [start + 50, start + 300] = 10*50 + 20*200 = 4500.
            assertTrue(available);
            assertEq(delta, 4500);
            assertEq(ring.newestAge(start + 310), 10);
        }
    }

    /// @notice The running sum wraps modulo 2^224 and differences stay exact. With the largest answer (2^192 - 1)
    ///         the accumulator wraps after about 2^32 seconds of lifetime; observations 2^25 s apart keep each 64-slot
    ///         span below 2^32 s (the library's precondition) while 140 of them wrap both the accumulator and the
    ///         32-bit timestamps.
    function test_CumulativeWrap_IsTolerated() public {
        uint192 big = type(uint192).max;
        uint32 step = 2 ** 25;
        uint32 t = 1000;
        ring.record(t, big, step);
        uint224 previous;
        bool accumulatorWrapped;
        bool clockWrapped;
        for (uint256 i = 1; i <= 140; ++i) {
            uint32 before = t;
            unchecked {
                t += step;
            }
            if (t < before) clockWrapped = true;
            (, uint224 cumulative, bool restarted) = ring.record(t, big, step);
            assertFalse(restarted);
            if (cumulative < previous) accumulatorWrapped = true;
            previous = cumulative;
        }
        assertTrue(accumulatorWrapped, "accumulator wrapped");
        assertTrue(clockWrapped, "timestamps wrapped");
        (bool available, uint256 delta) = ring.consult(t, 10 * step + step / 2);
        assertTrue(available);
        assertEq(delta, uint256(big) * (10 * step + step / 2));
    }
}

contract PriceMathTest is Test {
    PriceMathHarness internal math;
    IPriceOracle.Intent internal constant C = IPriceOracle.Intent.Collateral;
    IPriceOracle.Intent internal constant D = IPriceOracle.Intent.Debt;

    function setUp() public {
        math = new PriceMathHarness();
    }

    function test_ToWad_ScalesUpExactly() public view {
        assertEq(math.toWad(2000e8, 8, C), 2000e18);
        assertEq(math.toWad(2000e8, 8, D), 2000e18);
        assertEq(math.toWad(7, 0, C), 7e18);
        assertEq(math.toWad(123, 18, D), 123);
    }

    function test_ToWad_RoundsByIntentAbove18Decimals() public view {
        assertEq(math.toWad(1e36 + 1, 36, C), 1e18);
        assertEq(math.toWad(1e36 + 1, 36, D), 1e18 + 1);
        assertEq(math.toWad(1e36, 36, D), 1e18, "exact values do not round up");
    }

    function test_AverageToWad_SingleRounding() public view {
        // (1 + 2) / 2 raw units at 19 decimals = 0.15 wei -> 0 down, 1 up.
        assertEq(math.averageToWad(3, 2, 19, C), 0);
        assertEq(math.averageToWad(3, 2, 19, D), 1);
        // 8 decimals: 3 raw units / 2 s = 1.5e10 wei, exact.
        assertEq(math.averageToWad(3, 2, 8, C), 1.5e10);
        assertEq(math.averageToWad(3, 2, 8, D), 1.5e10);
        // 1 raw unit / 3 s at 18 decimals.
        assertEq(math.averageToWad(1, 3, 18, C), 0);
        assertEq(math.averageToWad(1, 3, 18, D), 1);
    }

    function test_DeviationBps_IsSymmetricAndRoundsUp() public view {
        assertEq(math.deviationBps(100, 103), 300);
        assertEq(math.deviationBps(103, 100), 300);
        assertEq(math.deviationBps(10_000, 10_001), 1);
        assertEq(math.deviationBps(100_000, 100_001), 1, "0.1 bp rounds up to 1");
        assertEq(math.deviationBps(5, 5), 0);
    }

    function test_DeviationBps_SaturatesInsteadOfOverflowing() public view {
        assertEq(math.deviationBps(1, type(uint256).max), type(uint256).max);
        assertEq(math.deviationBps(1, type(uint256).max / 10_000 + 2), type(uint256).max);
        assertEq(math.deviationBps(1, type(uint256).max / 10_000 + 1), (type(uint256).max / 10_000) * 10_000);
    }
}

contract FeedReaderTest is Test {
    FeedReaderHarness internal reader;

    function setUp() public {
        reader = new FeedReaderHarness();
        vm.warp(1_750_000_000);
    }

    function test_ReadsAllFiveWords() public {
        MockAggregatorV3 feed = new MockAggregatorV3(8, "x");
        feed.pushRound(-42, 111, 222, 0);
        (bool ok, FeedReader.Round memory round) = reader.latestRound(address(feed));
        assertTrue(ok);
        assertEq(round.roundId, 1);
        assertEq(round.answer, -42);
        assertEq(round.startedAt, 111);
        assertEq(round.updatedAt, 222);
        assertEq(round.answeredInRound, 1);
    }

    function test_RevertingFeed_IsNotOk() public {
        MockAggregatorV3 feed = new MockAggregatorV3(8, "x");
        feed.setBehavior(MockAggregatorV3.Behavior.Revert);
        (bool ok, FeedReader.Round memory round) = reader.latestRound(address(feed));
        assertFalse(ok);
        assertEq(round.answer, 0);
    }

    function test_ShortReturn_IsNotOk() public {
        (bool ok,) = reader.latestRound(address(new FourWordFeed()));
        assertFalse(ok);
        MockAggregatorV3 feed = new MockAggregatorV3(8, "x");
        feed.setBehavior(MockAggregatorV3.Behavior.ShortReturn);
        (ok,) = reader.latestRound(address(feed));
        assertFalse(ok);
    }

    function test_AddressWithoutCode_IsNotOk() public view {
        (bool ok,) = reader.latestRound(address(0xDEAD));
        assertFalse(ok);
    }

    /// @notice Only 160 bytes are copied: a 64 KiB answer costs the reader no memory expansion.
    function test_ReturnBomb_IsBounded() public {
        ReturnBombFeed bomb = new ReturnBombFeed();
        uint256 gasBefore = gasleft();
        (bool ok, FeedReader.Round memory round) = reader.latestRound(address(bomb));
        uint256 used = gasBefore - gasleft();
        assertTrue(ok, "enough data: decoded as a zero round");
        assertEq(round.answer, 0);
        // The callee pays for its own 64 KiB of memory; the reader's copy stays constant-size.
        assertLt(used, 30_000);
    }
}
