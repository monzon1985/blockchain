// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Script} from "forge-std/Script.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";

import {Roles} from "../src/access/Roles.sol";
import {TestPaymentDollarV1} from "../src/TestPaymentDollarV1.sol";
import {StablecoinDeployment} from "./StablecoinDeployment.sol";

/**
 * @title DeploymentIO
 * @notice Shared plumbing for the deployment scripts: role holders from the environment, the deployment record in
 *         `demo-out/deployment.json` (override with DEPLOYMENT_FILE) and the upgrade record in
 *         `demo-out/upgrade.json` (override with UPGRADE_FILE).
 */
abstract contract DeploymentIO is Script {
    /// @notice Addresses recorded by `Deploy.s.sol`.
    struct Recorded {
        AccessManager manager;
        TestPaymentDollarV1 token;
        address implementationV1;
        address deployer;
        uint256 deployBlock;
    }

    /// @notice Path of the deployment record written by `Deploy.s.sol`.
    /// @return The path (DEPLOYMENT_FILE, default `demo-out/deployment.json`).
    function deploymentFile() public view returns (string memory) {
        return vm.envOr("DEPLOYMENT_FILE", string("demo-out/deployment.json"));
    }

    /// @notice Path of the upgrade record written by `UpgradeToV2.s.sol` (the v2 implementation address).
    /// @return The path (UPGRADE_FILE, default `demo-out/upgrade.json`).
    function upgradeFile() public view returns (string memory) {
        return vm.envOr("UPGRADE_FILE", string("demo-out/upgrade.json"));
    }

    /// @notice Reads the role holders and limits from the environment (see `Deploy.s.sol`).
    /// @return cfg The configuration; `deployer` is left empty (the broadcaster or the deployment record fills it).
    function configFromEnv() public view returns (StablecoinDeployment.Config memory cfg) {
        cfg.governance = vm.envAddress("GOVERNANCE");
        cfg.masterMinter = vm.envAddress("MASTER_MINTER");
        cfg.pauser = vm.envAddress("PAUSER");
        cfg.blocklister = vm.envAddress("BLOCKLISTER");
        cfg.complianceOfficer = vm.envAddress("COMPLIANCE_OFFICER");
        cfg.bridge = vm.envAddress("BRIDGE");
        cfg.upgrader = vm.envAddress("UPGRADER");
        cfg.attestor = vm.envAddress("ATTESTOR");
        cfg.minters = vm.envAddress("MINTERS", ",");
        cfg.governanceDelay = Roles.GOVERNANCE_DELAY;
        cfg.minterLimitCeiling = uint208(vm.envOr("MINTER_LIMIT_CEILING", uint256(5_000_000e6)));
        cfg.bridgeMintLimit = uint208(vm.envOr("BRIDGE_MINT_LIMIT", uint256(2_000_000e6)));
        cfg.bridgeBurnLimit = uint208(vm.envOr("BRIDGE_BURN_LIMIT", uint256(2_000_000e6)));
    }

    /// @notice Reads the deployment record.
    /// @return r The recorded addresses and deployment block.
    function readDeployment() public view returns (Recorded memory r) {
        string memory json = vm.readFile(deploymentFile());
        r.manager = AccessManager(vm.parseJsonAddress(json, ".manager"));
        r.token = TestPaymentDollarV1(vm.parseJsonAddress(json, ".token"));
        r.implementationV1 = vm.parseJsonAddress(json, ".implementationV1");
        r.deployer = vm.parseJsonAddress(json, ".deployer");
        r.deployBlock = vm.parseJsonUint(json, ".deployBlock");
    }

    /// @notice Reads the v2 implementation recorded by `UpgradeToV2.s.sol schedule()`.
    /// @return The recorded v2 implementation, or the zero address when no upgrade was ever scheduled.
    function recordedImplementationV2() public view returns (address) {
        string memory path = upgradeFile();
        if (!vm.exists(path)) return address(0);
        return vm.parseJsonAddress(vm.readFile(path), ".implementationV2");
    }
}
