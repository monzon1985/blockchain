// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// @title VaultMath
/// @notice Pure accounting math for `AllocatorVault`: profit unlocking, fees, share price and its rate limiter.
/// @dev Every rounding choice is made against the party that could exploit it (depositors for valuations, the fee
///      recipient for fees). Full-precision `mulDiv` comes from Solady's `FixedPointMathLib` (512-bit intermediate).
library VaultMath {
    /// @notice 1e18 fixed-point unit used for fee rates.
    uint256 internal constant WAD = 1e18;

    /// @notice 1e27 fixed-point unit used for share prices.
    uint256 internal constant RAY = 1e27;

    /// @notice Seconds per year used for annualized rates (365 days; leap years are ignored on purpose).
    uint256 internal constant YEAR = 365 days;

    /// @notice Profit still locked at time `t`, unlocking linearly from `lastUpdate` to `unlockEnd`.
    /// @dev The unlocked part rounds down, so the locked part rounds up and `totalAssets` never over-states.
    /// @param locked Locked profit recorded at `lastUpdate`.
    /// @param lastUpdate Timestamp at which `locked` was recorded.
    /// @param unlockEnd Timestamp at which the profit is fully unlocked.
    /// @param t Timestamp to evaluate at (`t >= lastUpdate`).
    /// @return Locked profit at `t`.
    function lockedProfitAt(uint256 locked, uint256 lastUpdate, uint256 unlockEnd, uint256 t)
        internal
        pure
        returns (uint256)
    {
        if (locked == 0 || t >= unlockEnd) return 0;
        if (t <= lastUpdate) return locked;
        // t < unlockEnd and t > lastUpdate, so the denominator is non-zero and the quotient is < locked.
        return locked - FixedPointMathLib.fullMulDiv(locked, t - lastUpdate, unlockEnd - lastUpdate);
    }

    /// @notice Adds newly observed `profit` to the locked profit and restarts the schedule: everything still locked
    ///         is released linearly over one full `period` from `t` (as in Yearn V2 and Euler Earn).
    /// @dev Restarting is the only single-segment schedule under which no profit is ever released faster than over
    ///      its own `period`. A profit-weighted unlock end (Yearn V3) lets new profit unlock in a fraction of `period`
    ///      while older profit is still unlocking, which breaks the harvest-sandwich bound (see
    ///      `test/attacks/HarvestSandwich.t.sol`). The price paid is that profit still locked is released more slowly
    ///      each time new profit arrives.
    /// @param locked Profit locked at `t` (already decayed to `t`).
    /// @param profit Newly observed profit.
    /// @param t Current timestamp.
    /// @param period Unlock period.
    /// @return newLocked Locked profit including `profit`.
    /// @return newUnlockEnd New unlock end, `t + period`.
    function lockProfit(uint256 locked, uint256 profit, uint256 t, uint256 period)
        internal
        pure
        returns (uint256 newLocked, uint256 newUnlockEnd)
    {
        newLocked = locked + profit;
        newUnlockEnd = t + period;
    }

    /// @notice Management fee owed on `totalAssets` for `elapsed` seconds at `feePerYear`, rounded down.
    /// @dev Capped at `totalAssets` so an absurdly long idle period cannot make the fee-share formula underflow.
    /// @param totalAssets Assets backing the shares.
    /// @param feePerYear Management fee (WAD per year).
    /// @param elapsed Seconds since the last accrual.
    /// @return Fee in assets.
    function managementFeeAssets(uint256 totalAssets, uint256 feePerYear, uint256 elapsed)
        internal
        pure
        returns (uint256)
    {
        if (feePerYear == 0 || elapsed == 0) return 0;
        return
            FixedPointMathLib.min(
                totalAssets, FixedPointMathLib.fullMulDiv(totalAssets, feePerYear * elapsed, WAD * YEAR)
            );
    }

    /// @notice Performance fee owed on the gain of `supply` shares above the high-water mark, rounded down.
    /// @param price Current share price (RAY).
    /// @param highWaterMark High-water mark (RAY).
    /// @param supply Real (non-virtual) share supply.
    /// @param fee Performance fee (WAD).
    /// @return Fee in assets.
    function performanceFeeAssets(uint256 price, uint256 highWaterMark, uint256 supply, uint256 fee)
        internal
        pure
        returns (uint256)
    {
        if (fee == 0 || price <= highWaterMark) return 0;
        uint256 gain = FixedPointMathLib.fullMulDiv(price - highWaterMark, supply, RAY);
        return FixedPointMathLib.fullMulDiv(gain, fee, WAD);
    }

    /// @notice Shares worth `feeAssets` once minted, rounded down (against the fee recipient).
    /// @dev Solves `s * (totalAssets + 1) / (supplyWithVirtual + s) = feeAssets` for `s`. Requires
    ///      `feeAssets <= totalAssets`, which both fee functions guarantee.
    /// @param feeAssets Fee in assets.
    /// @param supplyWithVirtual Share supply plus virtual shares, before minting.
    /// @param totalAssets Assets backing the shares.
    /// @return Fee shares.
    function feeShares(uint256 feeAssets, uint256 supplyWithVirtual, uint256 totalAssets)
        internal
        pure
        returns (uint256)
    {
        if (feeAssets == 0) return 0;
        return FixedPointMathLib.fullMulDiv(feeAssets, supplyWithVirtual, totalAssets + 1 - feeAssets);
    }

    /// @notice Share price `(totalAssets + 1) * RAY / (supply + virtualShares)`, rounded down.
    /// @param totalAssets Assets backing the shares.
    /// @param supply Real share supply.
    /// @param virtualShares Virtual shares (`10 ** decimalsOffset`).
    /// @return Price in RAY.
    function sharePrice(uint256 totalAssets, uint256 supply, uint256 virtualShares) internal pure returns (uint256) {
        return FixedPointMathLib.fullMulDiv(totalAssets + 1, RAY, supply + virtualShares);
    }

    /// @notice Highest price the rate limiter allows `elapsed` seconds after a `checkpoint` price, rounded down.
    /// @dev Linear in `elapsed`. The vault only moves the checkpoint while the limit does not bind, so frequent
    ///      accruals cannot compound it.
    /// @param checkpoint Last rate-limited price (RAY).
    /// @param growthPerYear Allowed growth (WAD per year).
    /// @param elapsed Seconds since the checkpoint.
    /// @return Price ceiling in RAY.
    function priceCeiling(uint256 checkpoint, uint256 growthPerYear, uint256 elapsed) internal pure returns (uint256) {
        return checkpoint + FixedPointMathLib.fullMulDiv(checkpoint, growthPerYear * elapsed, WAD * YEAR);
    }
}
