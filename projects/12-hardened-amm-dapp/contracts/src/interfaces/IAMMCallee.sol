// SPDX-License-Identifier: GPL-3.0-or-later
// Derived from Uniswap v2-core IUniswapV2Callee.sol (GPL-3.0-or-later); see the "License" section of the README.
pragma solidity 0.8.37;

/// @title IAMMCallee
/// @notice Flash-swap receiver. The pair only accepts the callback if it returns `CALLBACK_SUCCESS`.
/// @dev Implementations MUST check that `msg.sender` is a genuine pair (derive it from the factory) and that
///      `sender` is a caller they trust; the pair cannot do this on their behalf.
interface IAMMCallee {
    /// @notice Called by the pair after the outputs were sent and before k is checked.
    /// @param sender The address that called `swap` on the pair.
    /// @param amount0Out Token0 sent to the callee.
    /// @param amount1Out Token1 sent to the callee.
    /// @param data Arbitrary data forwarded from `swap`.
    /// @return magic Must equal keccak256("IAMMCallee.ammSwapCall").
    function ammSwapCall(address sender, uint256 amount0Out, uint256 amount1Out, bytes calldata data)
        external
        returns (bytes32 magic);
}
