// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ObservationRingHarness} from "../utils/Harnesses.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Differential test of the observation ring against a naive reference that keeps every observation in an
///         unbounded array, uses 256-bit absolute timestamps and sums the window interval by interval.
/// @dev Random histories of 1-150 observations (so the 64-slot ring wraps), random gaps of up to 2 hours against a
///      random gap limit (so histories restart), random answers up to 2^192 - 1, start times up to 2^33 (so 32-bit
///      timestamps wrap), random windows and query times. The reference applies the gap rule its own way: it keeps
///      every observation and looks for the last gap longer than the limit, instead of restarting anything.
contract TwapFuzzTest is Test {
    uint256 internal constant CAPACITY = 64;

    ObservationRingHarness internal ring;
    uint256[] internal times;
    uint256[] internal answers;

    function setUp() public {
        ring = new ObservationRingHarness();
    }

    function testFuzz_RingMatchesNaiveReference(
        uint256 seed,
        uint256 count,
        uint256 start,
        uint256 maxGap,
        uint256 window,
        uint256 lag
    ) public {
        count = bound(count, 1, 150);
        start = bound(start, 0, 2 ** 33);
        // Mostly limits the 1 s - 2 h gaps can exceed (restarts happen), sometimes one they never reach.
        maxGap = seed % 4 == 0 ? type(uint32).max : bound(maxGap, 1, 3 hours);
        uint256 t = start;
        uint256 segmentStart;
        for (uint256 i; i < count; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            if (i != 0) t += 1 + (r % 2 hours);
            // Mostly realistic answers, sometimes the largest representable one.
            uint256 answer = (r >> 64) % 8 == 0 ? type(uint192).max - (r >> 128) % 1e6 : 1 + (r >> 64) % 1e30;
            times.push(t);
            answers.push(answer);
            bool gap = i != 0 && t - times[i - 1] > maxGap;
            if (gap) segmentStart = i;
            // Safe: truncation to 32 bits is exactly what the router does with block.timestamp.
            (,, bool restarted) = ring.record(uint32(t), uint192(answer), uint32(maxGap));
            assertEq(restarted, gap, "restart exactly after a gap longer than the limit");
        }

        // The ring retains the last 64 observations, and none from before the last gap.
        uint256 oldest = count > CAPACITY ? count - CAPACITY : 0;
        if (segmentStart > oldest) oldest = segmentStart;
        uint256 retained = count - oldest;
        uint256 newest = times[count - 1];
        uint256 span = newest - times[oldest];
        window = bound(window, 1, span + 1 hours);
        lag = bound(lag, 0, window + 1 hours);
        uint256 currentTime = newest + lag;

        bool expectedAvailable = retained >= 2 && lag <= window && span >= window;
        (bool available, uint256 delta) = ring.consult(uint32(currentTime), uint32(window));
        assertEq(available, expectedAvailable, "availability");
        if (!available) {
            assertEq(delta, 0);
            return;
        }
        assertEq(delta, _referenceSum(oldest, newest - window, newest), "time-weighted sum");
    }

    /// @dev Sum of answer * seconds over [from, to], each answer holding until the next observation.
    function _referenceSum(uint256 oldest, uint256 from, uint256 to) internal view returns (uint256 sum) {
        for (uint256 i = oldest; i + 1 < times.length; ++i) {
            uint256 lo = times[i] > from ? times[i] : from;
            uint256 hi = times[i + 1] < to ? times[i + 1] : to;
            if (hi > lo) sum += answers[i] * (hi - lo);
        }
    }
}
