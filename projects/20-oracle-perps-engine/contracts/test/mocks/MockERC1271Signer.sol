// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @title MockERC1271Signer
/// @notice Contract-wallet oracle signer (ERC-1271) whose owner EOA signs on its behalf. Used by the Foundry oracle
///         tests and, through the Go bindings, by the keeper tests that run a contract signer in the signer set.
///         Not for production.
contract MockERC1271Signer is IERC1271 {
    /// @notice EOA whose ECDSA signatures the wallet accepts.
    address public immutable owner;

    /// @param owner_ EOA that signs for the wallet.
    constructor(address owner_) {
        owner = owner_;
    }

    /// @notice ERC-1271: accepts `signature` when it is the owner's ECDSA signature of `hash`.
    /// @param hash Digest that was signed.
    /// @param signature 65-byte ECDSA signature.
    /// @return The ERC-1271 magic value on success, zero otherwise.
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(hash, signature);
        return err == ECDSA.RecoverError.NoError && recovered == owner ? IERC1271.isValidSignature.selector : bytes4(0);
    }
}
