// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Math} from "@openzeppelin-contracts/utils/math/Math.sol";

/// @title DutchDecay
/// @notice Linear descending price curve used on the destination chain after the exclusivity window.
/// @dev The output owed to the user is `startAmount` up to and including `decayStart`, then falls linearly to
///      `endAmount` at `decayEnd` and stays there. The decrease is rounded down, so the amount owed is rounded up:
///      rounding never works against the user. The function is monotonically non-increasing in `timestamp` and
///      always returns a value in [endAmount, startAmount] (see test/unit/DutchDecay.t.sol).
library DutchDecay {
    /// @notice Thrown when the curve would increase over time.
    /// @param startAmount Amount at the start of the curve.
    /// @param endAmount Amount at the end of the curve.
    error DecayIncreasing(uint256 startAmount, uint256 endAmount);

    /// @notice Amount owed at `timestamp`.
    /// @param startAmount Amount owed until `decayStart`.
    /// @param endAmount Amount owed from `decayEnd` on; must not exceed `startAmount`.
    /// @param decayStart Timestamp at which the decay starts.
    /// @param decayEnd Timestamp at which the decay ends. If not after `decayStart` the curve is flat at `startAmount`.
    /// @param timestamp Point at which to evaluate the curve.
    /// @return amount The amount owed.
    function amountAt(uint256 startAmount, uint256 endAmount, uint256 decayStart, uint256 decayEnd, uint256 timestamp)
        internal
        pure
        returns (uint256 amount)
    {
        require(endAmount <= startAmount, DecayIncreasing(startAmount, endAmount));
        if (timestamp <= decayStart || decayEnd <= decayStart) return startAmount;
        if (timestamp >= decayEnd) return endAmount;
        // decayStart < timestamp < decayEnd here, so both subtractions are positive and `elapsed < duration`,
        // which keeps the mulDiv result strictly below `startAmount - endAmount`.
        uint256 decrease = Math.mulDiv(startAmount - endAmount, timestamp - decayStart, decayEnd - decayStart);
        return startAmount - decrease;
    }
}
