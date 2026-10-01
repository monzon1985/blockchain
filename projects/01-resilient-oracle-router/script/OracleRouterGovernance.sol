// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {OracleRouter} from "../src/OracleRouter.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";

/// @title OracleRouterGovernance
/// @notice The permission layout of a production router, shared by the deployment script and the governance tests.
/// @dev Roles:
///      - `CONFIG_ROLE` (governance, 2-day execution delay): `setAssetConfig`, `setSequencerConfig`. New members also
///        wait 2 days (grant delay). The router itself refuses these calls with a shorter delay.
///      - `GUARDIAN_ROLE` (no delay): `forceStrict`, and cancelling scheduled `CONFIG_ROLE` operations during their
///        2-day window (it is the role guardian of `CONFIG_ROLE`).
///      - `ADMIN_ROLE` of the AccessManager: handed to governance with a 2-day execution delay; the deployer renounces
///        it, so every permission change is also scheduled and publicly visible for 2 days.
library OracleRouterGovernance {
    /// @notice Role allowed to change asset and sequencer configuration (with delay).
    uint64 internal constant CONFIG_ROLE = 1;

    /// @notice Role allowed to force strict mode and veto scheduled configuration changes.
    uint64 internal constant GUARDIAN_ROLE = 2;

    /// @notice Wires `router` into `manager` and hands the manager over to `governance`.
    /// @dev The caller must currently hold `ADMIN_ROLE` without delay (the deployer). The call ends with the deployer
    ///      renouncing that role, so it must be the last administrative action of the deployment.
    /// @param manager The AccessManager that is `router`'s authority.
    /// @param router The router.
    /// @param governance Multisig or timelock that configures assets.
    /// @param guardian Fast-response account that can only tighten.
    /// @param deployer The account currently holding `ADMIN_ROLE` (renounced at the end).
    function wire(AccessManager manager, OracleRouter router, address governance, address guardian, address deployer)
        internal
    {
        uint32 delay = router.CONFIG_DELAY();

        bytes4[] memory configSelectors = new bytes4[](2);
        configSelectors[0] = OracleRouter.setAssetConfig.selector;
        configSelectors[1] = OracleRouter.setSequencerConfig.selector;
        manager.setTargetFunctionRole(address(router), configSelectors, CONFIG_ROLE);

        bytes4[] memory guardianSelectors = new bytes4[](1);
        guardianSelectors[0] = OracleRouter.forceStrict.selector;
        manager.setTargetFunctionRole(address(router), guardianSelectors, GUARDIAN_ROLE);

        manager.labelRole(CONFIG_ROLE, "ORACLE_CONFIG");
        manager.labelRole(GUARDIAN_ROLE, "ORACLE_GUARDIAN");
        manager.setRoleGuardian(CONFIG_ROLE, GUARDIAN_ROLE);

        manager.grantRole(CONFIG_ROLE, governance, delay);
        manager.grantRole(GUARDIAN_ROLE, guardian, 0);
        manager.setGrantDelay(CONFIG_ROLE, delay);
        manager.setTargetAdminDelay(address(router), delay);

        manager.grantRole(manager.ADMIN_ROLE(), governance, delay);
        manager.renounceRole(manager.ADMIN_ROLE(), deployer);
    }
}
