// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title ISwapVenue
/// @notice Minimal exact-input swap interface the flash liquidator sells seized collateral through.
/// @dev Production deployments would wrap a DEX router or an aggregator; the anvil demo uses `MockSwapVenue`.
interface ISwapVenue {
    /// @notice Sells exactly `amountIn` of `tokenIn` for at least `minAmountOut` of `tokenOut`.
    /// @param tokenIn Token sold (pulled from `msg.sender` with `transferFrom`).
    /// @param tokenOut Token bought.
    /// @param amountIn Amount sold.
    /// @param minAmountOut Slippage bound; the swap reverts below it.
    /// @param recipient Receiver of `tokenOut`.
    /// @return amountOut Amount of `tokenOut` sent to `recipient`.
    function swapExactIn(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut, address recipient)
        external
        returns (uint256 amountOut);
}
