// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";

import {IAllocatorVault} from "../interfaces/IAllocatorVault.sol";

/// @title VaultRoles
/// @notice Single source of truth for the AccessManager roles of an `AllocatorVault` and the selectors each role may
///         call. Deployment scripts and tests both wire the manager through `configure`, so they cannot drift apart.
/// @dev Role 0 (`ADMIN_ROLE` in AccessManager) administers the manager itself; it is not granted any vault selector.
library VaultRoles {
    /// @notice Curator: lists strategies, sets caps, removes strategies, sets fees and the fee recipient.
    uint64 internal constant CURATOR = 1;

    /// @notice Allocator: moves assets between idle and strategies and orders the withdraw queue.
    uint64 internal constant ALLOCATOR = 2;

    /// @notice Guardian: revokes anything pending and zeroes caps instantly. It can only make the vault more
    ///         conservative, never move funds.
    uint64 internal constant GUARDIAN = 3;

    /// @notice Selectors restricted to the curator.
    /// @return selectors The curator selectors.
    function curatorSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](5);
        selectors[0] = IAllocatorVault.submitCap.selector;
        selectors[1] = IAllocatorVault.submitStrategyRemoval.selector;
        selectors[2] = IAllocatorVault.removeStrategy.selector;
        selectors[3] = IAllocatorVault.submitFees.selector;
        selectors[4] = IAllocatorVault.setFeeRecipient.selector;
    }

    /// @notice Selectors restricted to the allocator.
    /// @return selectors The allocator selectors.
    function allocatorSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](2);
        selectors[0] = IAllocatorVault.reallocate.selector;
        selectors[1] = IAllocatorVault.setWithdrawQueue.selector;
    }

    /// @notice Selectors restricted to the guardian.
    /// @return selectors The guardian selectors.
    function guardianSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](4);
        selectors[0] = IAllocatorVault.revokePendingCap.selector;
        selectors[1] = IAllocatorVault.revokePendingRemoval.selector;
        selectors[2] = IAllocatorVault.revokePendingFees.selector;
        selectors[3] = IAllocatorVault.zeroCap.selector;
    }

    /// @notice Labels the roles and maps every restricted vault selector to its role.
    /// @dev Must be called by an account holding the manager's admin role. Granting the roles to accounts is left to
    ///      the caller, so the same wiring serves tests, scripts and multisig proposals.
    /// @param manager The AccessManager that is the vault's authority.
    /// @param vault The vault.
    function configure(AccessManager manager, address vault) internal {
        manager.labelRole(CURATOR, "CURATOR");
        manager.labelRole(ALLOCATOR, "ALLOCATOR");
        manager.labelRole(GUARDIAN, "GUARDIAN");
        manager.setTargetFunctionRole(vault, curatorSelectors(), CURATOR);
        manager.setTargetFunctionRole(vault, allocatorSelectors(), ALLOCATOR);
        manager.setTargetFunctionRole(vault, guardianSelectors(), GUARDIAN);
    }
}
