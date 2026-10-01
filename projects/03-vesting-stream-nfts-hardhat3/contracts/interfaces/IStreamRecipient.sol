// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title IStreamRecipient
/// @notice Optional hook for contracts that hold stream NFTs and want to react when a stream is canceled.
/// @dev The hook is called with a fixed gas stipend inside `try/catch`. It can never block the cancellation: if it
/// reverts or runs out of gas, `VestingStreams` emits `RecipientHookFailed` and carries on. Recipients must not
/// rely on the hook for anything safety-critical; the stream state is the source of truth.
interface IStreamRecipient {
    /// @notice Called after `sender` canceled stream `streamId` held by this contract.
    /// @param streamId The canceled stream.
    /// @param sender The stream's sender, who received `refunded`.
    /// @param refunded Unvested tokens returned to the sender.
    /// @param withdrawable Vested tokens that remain withdrawable by the NFT owner.
    function onStreamCanceled(uint256 streamId, address sender, uint128 refunded, uint128 withdrawable) external;
}
