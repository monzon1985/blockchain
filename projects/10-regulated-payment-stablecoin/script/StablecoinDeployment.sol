// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Roles} from "../src/access/Roles.sol";
import {TestPaymentDollarV1} from "../src/TestPaymentDollarV1.sol";
import {TestPaymentDollarV2} from "../src/TestPaymentDollarV2.sol";
import {MintController} from "../src/modules/MintController.sol";
import {ComplianceControls} from "../src/modules/ComplianceControls.sol";
import {ReserveGate} from "../src/modules/ReserveGate.sol";
import {IERC7802} from "@openzeppelin/contracts/interfaces/draft-IERC7802.sol";

/// @notice The UUPS entry point, declared as an external interface so its selector can be taken at compile time
///         (`upgradeToAndCall` is `public` in OpenZeppelin's `UUPSUpgradeable`).
interface IUUPSUpgradeable {
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
}

/**
 * @title StablecoinDeployment
 * @notice Single source of truth for deploying and wiring the Test Payment Dollar. Used by `Deploy.s.sol`, by every
 *         test fixture and by the Medusa harness, so the tests exercise exactly the production wiring.
 * @dev Internal library functions run in the caller's context: in a broadcast script every external call below is a
 *      transaction from the broadcaster, which must be `cfg.deployer` (the initial AccessManager admin).
 *
 *      Whatever the configuration, the wiring ends with governance holding ADMIN behind `cfg.governanceDelay` and
 *      no other ADMIN member: a separate governance address receives ADMIN and the deployer renounces it, and a
 *      deployer that is itself governance re-grants its own ADMIN membership with the delay.
 */
library StablecoinDeployment {
    /// @notice The configuration would leave ADMIN without an execution delay.
    error GovernanceDelayRequired();

    /// @notice Who holds which role, and the governance limits the token starts with.
    struct Config {
        address deployer;
        address governance;
        address masterMinter;
        address pauser;
        address blocklister;
        address complianceOfficer;
        address bridge;
        address upgrader;
        address attestor;
        address[] minters;
        uint32 governanceDelay;
        uint208 minterLimitCeiling;
        uint208 bridgeMintLimit;
        uint208 bridgeBurnLimit;
    }

    /// @notice Addresses produced by {deploy}.
    struct Deployment {
        AccessManager manager;
        TestPaymentDollarV1 token;
        address implementation;
    }

    /// @notice One row of the selector -> role wiring table.
    struct SelectorRole {
        bytes4 selector;
        uint64 roleId;
        string name;
    }

    /// @notice Deploys AccessManager, the v1 implementation and its ERC-1967 proxy, then wires every role.
    /// @param cfg Role holders and limits.
    /// @return d The deployed contracts.
    function deploy(Config memory cfg) internal returns (Deployment memory d) {
        d.manager = new AccessManager(cfg.deployer);
        d.implementation = address(new TestPaymentDollarV1());
        bytes memory init = abi.encodeCall(
            TestPaymentDollarV1.initialize,
            (TestPaymentDollarV1.InitParams({
                    authority: address(d.manager),
                    attestor: cfg.attestor,
                    minterLimitCeiling: cfg.minterLimitCeiling,
                    bridgeMintLimit: cfg.bridgeMintLimit,
                    bridgeBurnLimit: cfg.bridgeBurnLimit
                }))
        );
        d.token = TestPaymentDollarV1(address(new ERC1967Proxy(d.implementation, init)));
        wire(d.manager, address(d.token), cfg);
    }

    /// @notice Labels roles, maps every restricted selector, sets guardians, grants roles with their delays and
    ///         finally puts ADMIN behind the governance delay: governance is granted ADMIN with that delay and the
    ///         deployer renounces its own undelayed ADMIN, or, when the deployer is governance, re-grants itself
    ///         ADMIN with the delay.
    /// @dev Reverts with {GovernanceDelayRequired} for a zero `cfg.governanceDelay`. AccessManager applies an
    ///      increased execution delay immediately (only decreases wait for a setback), so in the deployer-is-governance
    ///      case the very next ADMIN action already needs a 2-day schedule.
    /// @param manager The AccessManager (the caller must currently hold ADMIN with no delay).
    /// @param token The token proxy.
    /// @param cfg Role holders and delays.
    function wire(AccessManager manager, address token, Config memory cfg) internal {
        require(cfg.governanceDelay != 0, GovernanceDelayRequired());
        manager.labelRole(Roles.MASTER_MINTER, "MASTER_MINTER");
        manager.labelRole(Roles.MINTER, "MINTER");
        manager.labelRole(Roles.PAUSER, "PAUSER");
        manager.labelRole(Roles.BLOCKLISTER, "BLOCKLISTER");
        manager.labelRole(Roles.COMPLIANCE_OFFICER, "COMPLIANCE_OFFICER");
        manager.labelRole(Roles.BRIDGE, "BRIDGE");
        manager.labelRole(Roles.UPGRADER, "UPGRADER");

        SelectorRole[] memory table = v1SelectorRoles();
        for (uint256 i; i < table.length; ++i) {
            bytes4[] memory one = new bytes4[](1);
            one[0] = table[i].selector;
            manager.setTargetFunctionRole(token, one, table[i].roleId);
        }

        // The pauser (incident responder) can cancel a scheduled upgrade during the 2-day window.
        manager.setRoleGuardian(Roles.UPGRADER, Roles.PAUSER);

        manager.grantRole(Roles.MASTER_MINTER, cfg.masterMinter, 0);
        manager.grantRole(Roles.PAUSER, cfg.pauser, 0);
        manager.grantRole(Roles.BLOCKLISTER, cfg.blocklister, 0);
        manager.grantRole(Roles.COMPLIANCE_OFFICER, cfg.complianceOfficer, 0);
        manager.grantRole(Roles.BRIDGE, cfg.bridge, 0);
        manager.grantRole(Roles.UPGRADER, cfg.upgrader, cfg.governanceDelay);
        for (uint256 i; i < cfg.minters.length; ++i) {
            manager.grantRole(Roles.MINTER, cfg.minters[i], 0);
        }

        // Last step: from here on every ADMIN action needs a schedule. For an existing member (deployer ==
        // governance) `grantRole` updates the execution delay, and an increase takes effect at once.
        manager.grantRole(Roles.ADMIN, cfg.governance, cfg.governanceDelay);
        if (cfg.governance != cfg.deployer) manager.renounceRole(Roles.ADMIN, cfg.deployer);
    }

    /// @notice The canonical v1 wiring. Selectors not listed here stay ADMIN-only (AccessManager default), which
    ///         covers `setReserveAttestor`, `setMinterLimitCeiling` and `setBridgeLimits`.
    /// @return table Selector, role and human-readable name for each restricted v1 entry point.
    function v1SelectorRoles() internal pure returns (SelectorRole[] memory table) {
        table = new SelectorRole[](15);
        table[0] = SelectorRole(MintController.configureMinter.selector, Roles.MASTER_MINTER, "configureMinter");
        table[1] = SelectorRole(MintController.removeMinter.selector, Roles.MASTER_MINTER, "removeMinter");
        table[2] = SelectorRole(MintController.mint.selector, Roles.MINTER, "mint");
        table[3] = SelectorRole(MintController.burn.selector, Roles.MINTER, "burn");
        table[4] = SelectorRole(ComplianceControls.pause.selector, Roles.PAUSER, "pause");
        table[5] = SelectorRole(ComplianceControls.unpause.selector, Roles.PAUSER, "unpause");
        table[6] = SelectorRole(ComplianceControls.blocklist.selector, Roles.BLOCKLISTER, "blocklist");
        table[7] = SelectorRole(ComplianceControls.unBlocklist.selector, Roles.BLOCKLISTER, "unBlocklist");
        table[8] = SelectorRole(ComplianceControls.freeze.selector, Roles.COMPLIANCE_OFFICER, "freeze");
        table[9] = SelectorRole(ComplianceControls.unfreeze.selector, Roles.COMPLIANCE_OFFICER, "unfreeze");
        table[10] = SelectorRole(ComplianceControls.seize.selector, Roles.COMPLIANCE_OFFICER, "seize");
        table[11] = SelectorRole(ComplianceControls.burnFrozen.selector, Roles.COMPLIANCE_OFFICER, "burnFrozen");
        table[12] = SelectorRole(IERC7802.crosschainMint.selector, Roles.BRIDGE, "crosschainMint");
        table[13] = SelectorRole(IERC7802.crosschainBurn.selector, Roles.BRIDGE, "crosschainBurn");
        table[14] = SelectorRole(IUUPSUpgradeable.upgradeToAndCall.selector, Roles.UPGRADER, "upgradeToAndCall");
    }

    /// @notice Selectors that must stay ADMIN-only (checked explicitly by the role-graph verification).
    /// @return selectors The governance selectors of v1.
    function v1AdminSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](3);
        selectors[0] = ReserveGate.setReserveAttestor.selector;
        selectors[1] = MintController.setMinterLimitCeiling.selector;
        selectors[2] = MintController.setBridgeLimits.selector;
    }

    /// @notice Extra wiring introduced by v2 (scheduled by governance alongside the upgrade).
    /// @return table The v2-only selector -> role rows.
    function v2SelectorRoles() internal pure returns (SelectorRole[] memory table) {
        table = new SelectorRole[](1);
        table[0] = SelectorRole(
            TestPaymentDollarV2.setTransferCapFlag.selector, Roles.COMPLIANCE_OFFICER, "setTransferCapFlag"
        );
    }

    /// @notice Calldata governance schedules on the AccessManager to wire the v2 selectors.
    /// @param token The token proxy.
    /// @return The `setTargetFunctionRole` calldata.
    function v2WiringCalldata(address token) internal pure returns (bytes memory) {
        SelectorRole[] memory table = v2SelectorRoles();
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = table[0].selector;
        return abi.encodeCall(AccessManager.setTargetFunctionRole, (token, selectors, table[0].roleId));
    }

    /// @notice Calldata the upgrader schedules on the token (through the AccessManager) for the v1 -> v2 upgrade.
    /// @param v2Implementation The deployed v2 implementation.
    /// @return The `upgradeToAndCall(v2, initializeV2())` calldata.
    function v2UpgradeCalldata(address v2Implementation) internal pure returns (bytes memory) {
        return abi.encodeCall(
            IUUPSUpgradeable.upgradeToAndCall, (v2Implementation, abi.encodeCall(TestPaymentDollarV2.initializeV2, ()))
        );
    }
}
