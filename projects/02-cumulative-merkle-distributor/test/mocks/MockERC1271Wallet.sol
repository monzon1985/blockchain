// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @notice Minimal smart-contract wallet: approves a digest when its owner key signed it, unless approvals are revoked.
///         The wallet has no private key of its own, so only the ERC-1271 path can authorize it.
contract MockERC1271Wallet is IERC1271 {
    address public immutable owner;
    bool public revoked;

    constructor(address owner_) {
        owner = owner_;
    }

    function setRevoked(bool revoked_) external {
        require(msg.sender == owner, "not owner");
        revoked = revoked_;
    }

    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(hash, signature);
        if (!revoked && err == ECDSA.RecoverError.NoError && recovered == owner) {
            return IERC1271.isValidSignature.selector;
        }
        return 0xffffffff;
    }
}

/// @notice ERC-1271 wallet that always answers with the wrong magic value.
contract WrongMagicWallet {
    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        return 0x1626ba7f;
    }
}

/// @notice ERC-1271 wallet whose hook always reverts.
contract RevertingWallet {
    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        revert("no signatures here");
    }
}
