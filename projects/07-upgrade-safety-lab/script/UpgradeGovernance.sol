// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";

/// @title UpgradeGovernance
/// @notice The AccessManager configuration that gates every upgrade in the lab (the UUPS proxy from V2 on, and the
///         diamond once an AccessManager owns it). The deployment scripts and the tests apply this one function, so
///         what the tests prove is what the scripts deploy.
///
///         - UPGRADER may reach the target's upgrade function only through `schedule` then `execute`, after
///           `UPGRADE_DELAY`; GUARDIAN may cancel any scheduled upgrade.
///         - ADMIN, who could otherwise re-grant itself an undelayed UPGRADER role or move the target to a manager it
///           controls and upgrade in the same block, is itself put behind `UPGRADE_DELAY`, and every ADMIN operation
///           on the manager is cancellable by GUARDIAN. So every path to new code is announced on-chain
///           (`OperationScheduled`) at least `UPGRADE_DELAY` before it can run, and the guardian can veto it.
///         - Defence in depth, effective after the AccessManager's `minSetback` (5 days): a newly granted UPGRADER
///           waits `UPGRADE_DELAY` before its membership counts, and so does `updateAuthority` on the target.
library UpgradeGovernance {
    /// @notice OpenZeppelin AccessManager's ADMIN_ROLE.
    uint64 internal constant ADMIN_ROLE = 0;
    /// @notice May schedule and execute the target's upgrade function.
    uint64 internal constant UPGRADER_ROLE = 1;
    /// @notice May cancel scheduled upgrades and scheduled ADMIN operations.
    uint64 internal constant GUARDIAN_ROLE = 2;
    /// @notice Held by nobody. The manager's own ADMIN functions are assigned to it only so that its guardian can
    ///         cancel them: OpenZeppelin's AccessManager does not let ADMIN_ROLE itself have a guardian.
    uint64 internal constant ADMIN_OPERATIONS_ROLE = 3;
    /// @notice The public window of every upgrade path.
    uint32 internal constant UPGRADE_DELAY = 2 days;

    /// @notice The AccessManager functions restricted to ADMIN (or a role admin), i.e. every way to change the
    ///         permissions themselves.
    /// @return s Their selectors.
    function adminOperations() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](10);
        s[0] = AccessManager.labelRole.selector;
        s[1] = AccessManager.grantRole.selector;
        s[2] = AccessManager.revokeRole.selector;
        s[3] = AccessManager.setRoleAdmin.selector;
        s[4] = AccessManager.setRoleGuardian.selector;
        s[5] = AccessManager.setGrantDelay.selector;
        s[6] = AccessManager.setTargetFunctionRole.selector;
        s[7] = AccessManager.setTargetAdminDelay.selector;
        s[8] = AccessManager.setTargetClosed.selector;
        s[9] = AccessManager.updateAuthority.selector;
    }

    /// @notice Applies the configuration to a fresh manager.
    /// @dev Must be called (pranked or broadcast) by `admin`, the manager's ADMIN, while it still has no execution
    ///      delay. The last step puts that ADMIN behind `UPGRADE_DELAY`; an increase of an execution delay takes
    ///      effect immediately, so nothing can be slipped in after `configure` returns.
    /// @param manager The AccessManager.
    /// @param target The upgradeable contract (UUPS proxy or diamond).
    /// @param upgradeSelectors The target's upgrade functions (`upgradeToAndCall`, or `diamondCut`).
    /// @param upgrader UPGRADER member (execution delay `UPGRADE_DELAY`).
    /// @param guardian GUARDIAN member.
    /// @param admin The manager's ADMIN (the caller).
    function configure(
        AccessManager manager,
        address target,
        bytes4[] memory upgradeSelectors,
        address upgrader,
        address guardian,
        address admin
    ) internal {
        manager.setTargetFunctionRole(target, upgradeSelectors, UPGRADER_ROLE);
        manager.grantRole(UPGRADER_ROLE, upgrader, UPGRADE_DELAY);
        manager.setRoleGuardian(UPGRADER_ROLE, GUARDIAN_ROLE);
        manager.grantRole(GUARDIAN_ROLE, guardian, 0);

        manager.setRoleGuardian(ADMIN_OPERATIONS_ROLE, GUARDIAN_ROLE);
        manager.setTargetFunctionRole(address(manager), adminOperations(), ADMIN_OPERATIONS_ROLE);
        manager.setGrantDelay(UPGRADER_ROLE, UPGRADE_DELAY);
        manager.setTargetAdminDelay(target, UPGRADE_DELAY);

        // Last: from here on every ADMIN operation must be scheduled UPGRADE_DELAY ahead.
        manager.grantRole(ADMIN_ROLE, admin, UPGRADE_DELAY);
    }
}
