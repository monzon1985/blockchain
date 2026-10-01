// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title ObservationRing
/// @notice A fixed ring of 64 time-weighted observations of a feed answer, from which exact TWAPs are derived.
/// @dev Design follows the Uniswap v2/v3 price accumulators: every observation stores the running sum of
///      `answer * seconds` since the ring started, so the average over any interval is a difference of two sums
///      divided by its length. Two quantities are allowed to wrap:
///      - timestamps are stored in 32 bits (they wrap in 2106); every comparison is made on differences, computed in
///        `unchecked` 32-bit arithmetic, which stay correct across the wrap as long as the ring spans less than
///        2^32 seconds (63 gaps of at most `maxGap`; the router's `maxGap` is at most one day);
///      - the running sum is stored in 224 bits and wraps modulo 2^224; differences computed in `unchecked` 224-bit
///        arithmetic stay exact as long as the true difference is below 2^224. Answers are below 2^192 and the ring
///        spans less than 2^32 seconds, so every difference is below 2^224.
///      The answer recorded with an observation is assumed to hold until the next observation, but never across a
///      gap longer than the `maxGap` the caller passes to `record`: an observation that arrives later than that starts
///      a new history (the ring restarts), because nothing is known about the answers in force during the gap. So
///      every second a TWAP averages is priced by an answer observed at most `maxGap` seconds earlier. The TWAP window
///      always ends at the newest observation, never at "now".
library ObservationRing {
    /// @notice Number of slots.
    uint256 internal constant CAPACITY = 64;

    /// @notice Two observations cannot share a timestamp (the interval between them would be empty).
    /// @param timestamp The repeated timestamp.
    error DuplicateTimestamp(uint32 timestamp);

    /// @notice One ring slot (one storage word).
    /// @param timestamp Block timestamp truncated to 32 bits.
    /// @param answerCumulative Sum of `answer * seconds` since the first observation, modulo 2^224.
    struct Observation {
        uint32 timestamp;
        uint224 answerCumulative;
    }

    /// @notice Ring bookkeeping (one storage word).
    /// @param newest Slot of the newest observation.
    /// @param cardinality Number of populated slots, at most `CAPACITY`.
    /// @param lastAnswer Answer recorded with the newest observation; it accrues until the next write.
    struct Header {
        uint8 newest;
        uint8 cardinality;
        uint192 lastAnswer;
    }

    /// @notice The ring.
    /// @param header Bookkeeping.
    /// @param observations The slots.
    struct Ring {
        Header header;
        Observation[64] observations;
    }

    /// @notice Appends an observation, overwriting the oldest one once the ring is full. When the previous observation
    ///         is more than `maxGap` seconds old, its answer is not carried across the gap: the ring restarts and the
    ///         new observation becomes the first of a new history.
    /// @param ring The ring.
    /// @param timestamp Current block timestamp, truncated to 32 bits.
    /// @param answer Answer valid from `timestamp` until the next observation (for at most `maxGap` seconds).
    /// @param maxGap Longest interval across which the previous answer may be carried forward, in seconds.
    /// @return index Slot written.
    /// @return answerCumulative Running sum stored in that slot.
    /// @return restarted Whether earlier observations were discarded because of the gap.
    function record(Ring storage ring, uint32 timestamp, uint192 answer, uint32 maxGap)
        internal
        returns (uint8 index, uint224 answerCumulative, bool restarted)
    {
        Header memory header = ring.header;
        uint8 cardinality = header.cardinality;
        if (cardinality == 0) {
            cardinality = 1;
        } else {
            Observation memory last = ring.observations[header.newest];
            uint32 elapsed;
            unchecked {
                // Wraps across 2106 by design: only the difference of two 32-bit timestamps is meaningful.
                elapsed = timestamp - last.timestamp;
            }
            require(elapsed != 0, DuplicateTimestamp(timestamp));
            restarted = elapsed > maxGap;
            if (restarted) {
                // A new history starts in slot 0 with a zero running sum (`index` and `answerCumulative` stay 0),
                // exactly like the very first observation; `consult` then needs a full window of new observations.
                cardinality = 1;
            } else {
                unchecked {
                    // `lastAnswer < 2^192` and `elapsed < 2^32`, so the product is below 2^224 and exact; the running
                    // sum then wraps modulo 2^224 by design, which is harmless because only differences are used.
                    answerCumulative = last.answerCumulative + uint224(header.lastAnswer) * elapsed;
                    // `newest < CAPACITY <= 255`, so `newest + 1` cannot overflow and the modulo keeps it below 64.
                    // casting to 'uint8' is safe because the value is below CAPACITY (64)
                    // forge-lint: disable-next-line(unsafe-typecast)
                    index = uint8((uint256(header.newest) + 1) % CAPACITY);
                }
                if (cardinality < CAPACITY) ++cardinality;
            }
        }
        ring.observations[index] = Observation(timestamp, answerCumulative);
        ring.header = Header(index, cardinality, answer);
    }

    /// @notice Forgets every observation. Slots are not zeroed; they become unreachable because `cardinality` is 0.
    /// @param ring The ring.
    /// @return hadHistory Whether at least one observation existed.
    function reset(Ring storage ring) internal returns (bool hadHistory) {
        hadHistory = ring.header.cardinality != 0;
        if (hadHistory) delete ring.header;
    }

    /// @notice Sum of `answer * seconds` over the `window` seconds that end at the newest observation.
    /// @dev Unavailable when the ring holds fewer than two observations, when the newest one is older than `window`
    ///      (the fallback may bridge at most one window of silence), or when the history is shorter than `window`.
    ///      The history only reaches back to the last restart (see `record`), so a window never straddles a gap
    ///      longer than `maxGap`. The start of the window usually falls between two observations; the sum there is
    ///      interpolated exactly, because between consecutive observations the answer is constant.
    /// @param ring The ring.
    /// @param currentTime Current block timestamp, truncated to 32 bits.
    /// @param window Window length in seconds, non-zero.
    /// @return available Whether a full, fresh window is covered.
    /// @return delta The time-weighted sum over the window (divide by `window` for the average answer).
    function consult(Ring storage ring, uint32 currentTime, uint32 window)
        internal
        view
        returns (bool available, uint256 delta)
    {
        Header memory header = ring.header;
        if (header.cardinality < 2) return (available, delta);

        Observation memory newest = ring.observations[header.newest];
        uint256 oldestSlot = header.cardinality < CAPACITY ? 0 : (uint256(header.newest) + 1) % CAPACITY;
        uint32 ageOfNewest;
        uint32 span;
        unchecked {
            // 32-bit differences: correct across the 2106 wrap (see the library notes).
            ageOfNewest = currentTime - newest.timestamp;
            span = newest.timestamp - ring.observations[oldestSlot].timestamp;
        }
        if (ageOfNewest > window || span < window) return (available, delta);

        // Binary search for the last observation at least `window` seconds older than the newest. Positions are
        // logical (0 = oldest, cardinality - 1 = newest). Invariant: offset(lo) >= window > offset(hi).
        uint256 lo = 0;
        uint256 hi = header.cardinality - 1;
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) >> 1;
            uint32 midTimestamp = ring.observations[(oldestSlot + mid) % CAPACITY].timestamp;
            uint32 offset;
            unchecked {
                offset = newest.timestamp - midTimestamp;
            }
            if (offset >= window) lo = mid;
            else hi = mid;
        }
        Observation memory before = ring.observations[(oldestSlot + lo) % CAPACITY];
        Observation memory next = ring.observations[(oldestSlot + lo + 1) % CAPACITY];

        unchecked {
            // All operands are differences of wrapping accumulators, exact modulo 2^224 (see the library notes).
            // `next` follows `before` directly, so their cumulative difference is exactly `answer * interval` and the
            // division recovers the constant answer of that interval without remainder. `interval > 0` because
            // `record` rejects duplicate timestamps. `offset(before) >= window`, so `intoInterval` does not wrap.
            uint32 interval = next.timestamp - before.timestamp;
            // slither-disable-next-line divide-before-multiply
            uint224 answer = (next.answerCumulative - before.answerCumulative) / interval;
            uint32 intoInterval = (newest.timestamp - before.timestamp) - window;
            // The division above is exact (no remainder), so multiplying its result loses no precision.
            // forge-lint: disable-next-line(divide-before-multiply)
            uint224 cumulativeAtStart = before.answerCumulative + answer * intoInterval;
            delta = uint256(newest.answerCumulative - cumulativeAtStart);
        }
        available = true;
    }

    /// @notice Seconds since the newest observation (32-bit wrapping difference).
    /// @param ring The ring.
    /// @param currentTime Current block timestamp, truncated to 32 bits.
    /// @return age The age; meaningless when the ring is empty.
    function newestAge(Ring storage ring, uint32 currentTime) internal view returns (uint32 age) {
        uint32 newestTimestamp = ring.observations[ring.header.newest].timestamp;
        unchecked {
            age = currentTime - newestTimestamp;
        }
    }
}
