// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IRegistryErrors, IRegistryEvents} from "../../interfaces/IRegistry.sol";
import {LibOwnership} from "../libraries/LibOwnership.sol";
import {LibRegistryDiamond} from "../libraries/LibRegistryDiamond.sol";

/// @title RegistryFacetBase
/// @notice Shared modifiers of the application facets. The pause errors and events reuse OpenZeppelin
///         `Pausable` signatures so the diamond reverts exactly like the UUPS registry.
abstract contract RegistryFacetBase is IRegistryEvents, IRegistryErrors {
    /// @notice New subscriptions were paused (same signature as OpenZeppelin `Pausable`).
    /// @dev Not indexed on purpose: indexing would change the log layout and break parity with the UUPS registry.
    /// @param account The owner that paused.
    event Paused(address account);

    /// @notice New subscriptions were resumed (same signature as OpenZeppelin `Pausable`).
    /// @param account The owner that unpaused.
    event Unpaused(address account);

    /// @notice The operation is not allowed while paused (same signature as OpenZeppelin `Pausable`).
    error EnforcedPause();

    /// @notice The operation requires the paused state (same signature as OpenZeppelin `Pausable`).
    error ExpectedPause();

    /// @dev Restricts a function to the diamond owner.
    modifier onlyOwner() {
        LibOwnership.enforceIsOwner();
        _;
    }

    /// @dev Reverts with `EnforcedPause` while paused.
    modifier whenNotPaused() {
        if (LibRegistryDiamond.registryStorage().paused) revert EnforcedPause();
        _;
    }

    /// @dev Reverts unless `planId` is in 1..planCount.
    function _requirePlan(LibRegistryDiamond.RegistryStorage storage $, uint256 planId) internal view {
        if (planId == 0 || planId > $.planCount) revert UnknownPlan(planId, $.planCount);
    }
}
