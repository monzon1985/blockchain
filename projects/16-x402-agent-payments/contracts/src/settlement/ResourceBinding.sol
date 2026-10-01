// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title ResourceBinding
/// @notice Derives EIP-3009 nonces that commit to the x402 resource (and, for escrow, the delivery terms).
/// @dev The standard `TransferWithAuthorization` signature covers `from`, `to`, `value`, the validity window and
///      the nonce, but not the resource being bought. Deriving the nonce as a hash commitment
///      `H(tag, resourceHash, salt)` lets a single, unmodified EIP-3009 signature also bind the resource: a relayer
///      that wants to re-attribute the payment to another resource would need a second preimage of the nonce.
///      The low 64 bits are cleared because OpenZeppelin's `ERC20TransferAuthorization` reads them as a sequence
///      number that must be 0 for a fresh 192-bit key. The random `salt` keeps nonces unique and unlinkable.
library ResourceBinding {
    /// @notice Domain tag for `exact` payments.
    bytes32 internal constant EXACT_TAG = keccak256("x402-local/exact/resource-binding/v1");

    /// @notice Domain tag for escrowed payments.
    bytes32 internal constant ESCROW_TAG = keccak256("x402-local/escrow/terms-binding/v1");

    /// @notice Mask that keeps the 192-bit nonce key and zeroes the 64-bit sequence.
    uint256 internal constant KEY_MASK = ~uint256(type(uint64).max);

    /// @notice Nonce for an `exact` payment bound to `resourceHash`.
    /// @param resourceHash keccak256 of the canonical resource string.
    /// @param salt 32 random bytes chosen by the payer.
    /// @return The EIP-3009 nonce (sequence 0 of a pseudorandom 192-bit key).
    function exactNonce(bytes32 resourceHash, bytes32 salt) internal pure returns (bytes32) {
        return bytes32(uint256(keccak256(abi.encode(EXACT_TAG, resourceHash, salt))) & KEY_MASK);
    }

    /// @notice Nonce for an escrowed payment bound to its payee, resource and delivery deadline.
    /// @param payee Final recipient once delivery is proven.
    /// @param resourceHash keccak256 of the canonical resource string.
    /// @param deliveryDeadline Timestamp after which the payer may reclaim the funds.
    /// @param salt 32 random bytes chosen by the payer.
    /// @return The EIP-3009 nonce (sequence 0 of a pseudorandom 192-bit key).
    function escrowNonce(address payee, bytes32 resourceHash, uint256 deliveryDeadline, bytes32 salt)
        internal
        pure
        returns (bytes32)
    {
        return
            bytes32(uint256(keccak256(abi.encode(ESCROW_TAG, payee, resourceHash, deliveryDeadline, salt))) & KEY_MASK);
    }
}
