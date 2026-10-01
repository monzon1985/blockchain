// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @dev ERC-7201 base slot of the diamond's ownership state.
uint256 constant OWNERSHIP_STORAGE_LOCATION = erc7201("upgradelab.storage.DiamondOwnership");

/// @title LibOwnership
/// @notice Two-step ownership of the registry diamond. Errors and events reuse OpenZeppelin's `Ownable2Step`
///         signatures so the UUPS registry and the diamond revert and log identically.
library LibOwnership {
    /// @notice Current and pending owner.
    /// @param owner Account allowed to cut the diamond and administer plans.
    /// @param pendingOwner Account allowed to accept ownership, or zero.
    /// @custom:storage-location erc7201:upgradelab.storage.DiamondOwnership
    struct OwnershipStorage {
        address owner;
        address pendingOwner;
    }

    /// @notice Ownership changed (same signature as OpenZeppelin `Ownable`).
    /// @param previousOwner Owner before the change.
    /// @param newOwner Owner after the change.
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /// @notice A two-step transfer started (same signature as OpenZeppelin `Ownable2Step`).
    /// @param previousOwner Current owner.
    /// @param newOwner Account that must accept.
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);

    /// @notice The caller is not allowed (same signature as OpenZeppelin `Ownable`).
    /// @param account The rejected caller.
    error OwnableUnauthorizedAccount(address account);

    /// @notice The zero address cannot own the diamond (same signature as OpenZeppelin `Ownable`).
    /// @param owner The rejected owner.
    error OwnableInvalidOwner(address owner);

    /// @notice Returns a storage pointer to the ownership state.
    /// @return $ The ERC-7201 namespace `upgradelab.storage.DiamondOwnership`.
    function ownershipStorage() internal pure returns (OwnershipStorage storage $) {
        uint256 location = OWNERSHIP_STORAGE_LOCATION;
        // Only assigns the slot of a storage pointer; no memory or storage is touched.
        assembly {
            $.slot := location
        }
    }

    /// @notice Reverts unless `msg.sender` is the owner.
    function enforceIsOwner() internal view {
        if (msg.sender != ownershipStorage().owner) revert OwnableUnauthorizedAccount(msg.sender);
    }

    /// @notice Sets the owner and clears any pending transfer.
    /// @param newOwner The new owner.
    function setOwner(address newOwner) internal {
        OwnershipStorage storage $ = ownershipStorage();
        address previousOwner = $.owner;
        delete $.pendingOwner;
        $.owner = newOwner;
        emit OwnershipTransferred(previousOwner, newOwner);
    }
}
