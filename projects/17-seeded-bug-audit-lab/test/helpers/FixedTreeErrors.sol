// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @notice Custom errors that exist only in the fixed tree (they are part of the fix hunks).
///         Declaring them here lets regression and unit tests assert the exact revert selector
///         while every test file still compiles under the vulnerable profile.
interface FixedTreeErrors {
    /// @notice {KestrelPool.batchSwap} listed an asset twice (SC05 fix).
    /// @param asset The repeated asset.
    error DuplicateAsset(address asset);
    /// @notice {KestrelPool.swapWithNativeSponsor} could not refund the caller (SC06 fix).
    error RefundFailed();
    /// @notice A vault price view was read mid-operation (SC08 fix).
    error ReentrantRead();
    /// @notice {KestrelRelayer.relaySwap} received a stale or future nonce (REPLAY fix).
    /// @param provided Nonce in the request.
    /// @param expected Current nonce.
    error InvalidNonce(uint256 provided, uint256 expected);
}
