// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title IPriceOracle
/// @notice Manipulation-resistant price source for the lending market.
/// @dev The interface is deliberately minimal: a single decimal-normalized WAD price of pool
///      token0 denominated in token1. Implementations must return a price that a single
///      transaction cannot move.
interface IPriceOracle {
    /// @notice WAD price of token0 in units of token1, resistant to single-block manipulation.
    /// @return price token1 per 1e18 of token0, WAD-scaled.
    function priceToken0In1() external view returns (uint256 price);
}
