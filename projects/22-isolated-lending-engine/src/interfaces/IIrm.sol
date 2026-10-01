// SPDX-License-Identifier: GPL-2.0-or-later
// Adapted from Morpho Blue by Morpho Labs, https://github.com/morpho-org/morpho-blue (GPL-2.0-or-later),
// src/interfaces/IIrm.sol: the interface shape follows the original; the NatSpec is new. Modified for this project in
// 2026; see the README's License section.
pragma solidity 0.8.37;

import {Market, MarketParams} from "./ILendingEngine.sol";

/// @title IIrm
/// @notice Interest rate model interface. Rates are per second, scaled by 1e18.
interface IIrm {
    /// @notice Returns the borrow rate for the elapsed period and updates any internal state of the model.
    /// @dev Called by the engine on every accrual with the market state *before* interest is applied.
    /// @param marketParams The market being accrued.
    /// @param market The market's storage snapshot.
    /// @return The average borrow rate per second over `[market.lastUpdate, block.timestamp]`, WAD-scaled.
    function borrowRate(MarketParams calldata marketParams, Market calldata market) external returns (uint256);

    /// @notice Same as `borrowRate` without mutating state.
    /// @param marketParams The market being queried.
    /// @param market The market's storage snapshot.
    /// @return The average borrow rate per second, WAD-scaled.
    function borrowRateView(MarketParams calldata marketParams, Market calldata market) external view returns (uint256);
}
