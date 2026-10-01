// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title ITransferAuthorizationToken
/// @notice The subset of an EIP-3009 token (bytes-signature variant, as in OpenZeppelin's
///         `ERC20TransferAuthorization`) that the settlement contracts rely on.
interface ITransferAuthorizationToken is IERC20 {
    /// @notice Executes a transfer authorized by an EIP-712 `TransferWithAuthorization` signature of `from`.
    /// @param from Payer that signed the authorization.
    /// @param to Recipient bound by the signature.
    /// @param value Amount bound by the signature.
    /// @param validAfter The authorization is valid strictly after this timestamp.
    /// @param validBefore The authorization is valid strictly before this timestamp.
    /// @param nonce 32-byte authorization nonce (192-bit key, 64-bit sequence).
    /// @param signature ECDSA signature or ERC-1271 payload of `from`.
    function transferWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes memory signature
    ) external;

    /// @notice Same as {transferWithAuthorization} but only callable by `to` (front-running protection).
    /// @param from Payer that signed the authorization.
    /// @param to Recipient bound by the signature; must be the caller.
    /// @param value Amount bound by the signature.
    /// @param validAfter The authorization is valid strictly after this timestamp.
    /// @param validBefore The authorization is valid strictly before this timestamp.
    /// @param nonce 32-byte authorization nonce (192-bit key, 64-bit sequence).
    /// @param signature ECDSA signature or ERC-1271 payload of `from`.
    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes memory signature
    ) external;

    /// @notice Whether `nonce` has already been consumed for `authorizer`.
    /// @param authorizer The payer.
    /// @param nonce The authorization nonce.
    /// @return True once the nonce is used or cancelled.
    function authorizationState(address authorizer, bytes32 nonce) external view returns (bool);
}
