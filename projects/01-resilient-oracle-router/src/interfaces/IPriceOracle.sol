// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title IPriceOracle
/// @notice The consumer-facing, non-reverting price interface of the resilient oracle router.
/// @dev This is the whole surface a lending market, perps engine or stablecoin needs: one call that always returns,
///      a price normalized to 1e18 (USD per whole token) and a status that says whether and why it can be trusted.
///      Rounding follows the caller's intent: `Collateral` rounds down and `Debt` rounds up, so a consumer never
///      overvalues collateral or undervalues debt. The enum orders are part of the ABI and must never change.
interface IPriceOracle {
    /// @notice Why the caller wants the price. Selects the rounding direction and the conservative side of a
    ///         primary/secondary disagreement.
    enum Intent {
        Collateral,
        Debt
    }

    /// @notice Health of a quote.
    /// @dev A returned price is non-zero exactly when it is usable: status `OK`, `FALLBACK_USED`, or `DEVIATION` from
    ///      an asset in soft mode (which quotes the conservative side). Every other status comes with a zero price.
    enum Status {
        OK,
        STALE,
        ZERO,
        NEGATIVE,
        OUT_OF_BOUNDS,
        SEQUENCER_DOWN,
        GRACE_PERIOD,
        DEVIATION,
        FALLBACK_USED
    }

    /// @notice Returns the price of `asset` (1e18 = 1 USD per whole token) without reverting on any feed state.
    /// @param asset The token whose price is requested.
    /// @param intent Rounding direction and conservative side requested by the consumer.
    /// @return price The normalized price, or zero when no usable price exists.
    /// @return status Why the price can or cannot be trusted.
    function tryGetPrice(address asset, Intent intent) external view returns (uint256 price, Status status);
}
