// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title IPriceOracle
/// @notice Non-reverting price interface of the resilient oracle router (project 01 of this repository).
/// @dev Vendored, not imported: every project in the monorepo is self-contained. The router normalizes every
///      feed to 1e18 (USD per whole token) and rounds according to the caller's intent: `Collateral` rounds
///      down and `Debt` rounds up, so a consumer never overvalues collateral or undervalues debt.
interface IPriceOracle {
    /// @notice Why the caller wants the price; selects the rounding direction and the conservative side.
    enum Intent {
        Collateral,
        Debt
    }

    /// @notice Health of the returned price. The router returns a non-zero price only with `OK`, `FALLBACK_USED`,
    ///         or `DEVIATION` for an asset in its soft deviation mode (the conservative side of two disagreeing
    ///         feeds). `RouterOracleAdapter` deliberately accepts only `OK` and `FALLBACK_USED` and treats a
    ///         `DEVIATION` quote as a reason to switch to its independent secondary source.
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

    /// @notice Returns the price of `asset` in USD (1e18 = 1 USD per whole token) without ever reverting.
    /// @param asset The token whose price is requested.
    /// @param intent Rounding direction requested by the consumer.
    /// @return price The normalized price; meaningful only when `status` is `OK` or `FALLBACK_USED`.
    /// @return status Why the price can or cannot be trusted.
    function tryGetPrice(address asset, Intent intent) external view returns (uint256 price, Status status);
}
