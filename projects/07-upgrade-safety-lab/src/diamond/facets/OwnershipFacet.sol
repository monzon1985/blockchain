// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IRegistryErrors} from "../../interfaces/IRegistry.sol";
import {LibOwnership} from "../libraries/LibOwnership.sol";

/// @title OwnershipFacet
/// @notice Two-step ownership of the diamond with OpenZeppelin `Ownable2Step` semantics: `transferOwnership`
///         only nominates, the nominee must call `acceptOwnership`, and renouncing is disabled.
contract OwnershipFacet is IRegistryErrors {
    /// @notice Current owner.
    /// @return The owner.
    function owner() external view returns (address) {
        return LibOwnership.ownershipStorage().owner;
    }

    /// @notice Account allowed to accept ownership, or zero.
    /// @return The pending owner.
    function pendingOwner() external view returns (address) {
        return LibOwnership.ownershipStorage().pendingOwner;
    }

    /// @notice Nominates a new owner (zero cancels a pending nomination).
    /// @param newOwner The account that must call `acceptOwnership`.
    function transferOwnership(address newOwner) external {
        LibOwnership.enforceIsOwner();
        LibOwnership.OwnershipStorage storage $ = LibOwnership.ownershipStorage();
        $.pendingOwner = newOwner;
        emit LibOwnership.OwnershipTransferStarted($.owner, newOwner);
    }

    /// @notice Completes a transfer; callable only by the pending owner.
    function acceptOwnership() external {
        if (LibOwnership.ownershipStorage().pendingOwner != msg.sender) {
            revert LibOwnership.OwnableUnauthorizedAccount(msg.sender);
        }
        LibOwnership.setOwner(msg.sender);
    }

    /// @notice Disabled: renouncing would make the diamond immutable and its plans unmanageable by accident.
    function renounceOwnership() external pure {
        revert RenounceDisabled();
    }
}
