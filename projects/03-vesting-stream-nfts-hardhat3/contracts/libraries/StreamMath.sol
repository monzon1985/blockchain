// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Milestone} from "../types/StreamTypes.sol";

/// @title StreamMath
/// @notice Pure vesting-curve math for the three stream shapes.
/// @dev Every division rounds toward zero, so the vested amount is never overstated: rounding always goes against
/// the recipient and in favour of the sender's refund. All three curves are non-decreasing in `t` and reach exactly
/// the deposit at the last milestone (see the README rounding table).
library StreamMath {
    /// @notice Amount vested at time `t` for a linear stream with an optional cliff.
    /// @dev Precondition (enforced at creation): `start < end` and `cliff == 0 || start < cliff < end`.
    /// Rounds down: `floor(deposit * (t - start) / (end - start))`.
    /// @param deposit Total escrowed amount.
    /// @param start Vesting start.
    /// @param cliff Cliff time, zero when the stream has no cliff.
    /// @param end Time at which everything has vested.
    /// @param t Evaluation time.
    /// @return vested Amount vested at `t`, in `[0, deposit]`.
    function linear(uint128 deposit, uint40 start, uint40 cliff, uint40 end, uint40 t)
        internal
        pure
        returns (uint128 vested)
    {
        if (t < start || t < cliff) return 0;
        if (t >= end) return deposit;
        // `deposit < 2^128` and `t - start < 2^40`, so the product fits in 168 bits; the quotient is below
        // `deposit` because `t - start < end - start`, so the downcast cannot truncate.
        vested = uint128((uint256(deposit) * (t - start)) / (end - start));
    }

    /// @notice Amount vested at time `t` for a tranched stream: every tranche unlocks in full at its timestamp.
    /// @dev Exact (no division). Tranches are sorted by timestamp and sum to the deposit (checked at creation).
    /// @param tranches Tranches with strictly increasing timestamps.
    /// @param t Evaluation time.
    /// @return vested Sum of the tranches whose timestamp is `<= t`.
    function tranched(Milestone[] memory tranches, uint40 t) internal pure returns (uint128 vested) {
        uint256 count = tranches.length;
        for (uint256 i; i < count; ++i) {
            if (tranches[i].timestamp > t) break;
            vested += tranches[i].amount;
        }
    }

    /// @notice Amount vested at time `t` for a piecewise-linear stream.
    /// @dev Segment `i` streams `amount_i` linearly between the previous milestone (or `start` for `i == 0`) and
    /// its own timestamp. Completed segments count in full; the active one rounds down. A zero-amount segment is a
    /// plateau.
    /// @param segments Segments with strictly increasing timestamps, the first strictly after `start`.
    /// @param start Vesting start.
    /// @param t Evaluation time.
    /// @return vested Amount vested at `t`, in `[0, sum of amounts]`.
    function segmented(Milestone[] memory segments, uint40 start, uint40 t) internal pure returns (uint128 vested) {
        if (t <= start) return 0;
        uint40 previous = start;
        uint256 count = segments.length;
        for (uint256 i; i < count; ++i) {
            Milestone memory segment = segments[i];
            if (t >= segment.timestamp) {
                vested += segment.amount;
                previous = segment.timestamp;
                continue;
            }
            // `previous <= t < segment.timestamp`, so the ratio is below one and the partial amount is below
            // `segment.amount`; the product fits in 168 bits.
            vested += uint128((uint256(segment.amount) * (t - previous)) / (segment.timestamp - previous));
            break;
        }
    }
}
