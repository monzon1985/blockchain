// SPDX-License-Identifier: GPL-2.0-or-later
// Adapted from Morpho Blue by Morpho Labs, https://github.com/morpho-org/morpho-blue (GPL-2.0-or-later),
// src/interfaces/IOracle.sol: the interface shape and its 1e36 price scale follow the original; the NatSpec is new.
// Modified for this project in 2026; see the README's License section.
pragma solidity 0.8.37;

/// @title IOracle
/// @notice Market oracle consumed by the lending engine.
/// @dev `price()` quotes one base unit of the collateral token in base units of the loan token, scaled by
///      `1e36` (`ORACLE_PRICE_SCALE`). Token decimals are therefore already folded into the price. The engine
///      calls it on every borrow, collateral withdrawal and liquidation; it must revert rather than return a
///      value it cannot stand behind.
interface IOracle {
    /// @notice Price of one collateral base unit in loan base units, scaled by 1e36.
    /// @return The current price. Reverts when no trustworthy price exists.
    function price() external view returns (uint256);
}
