// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {console2} from "forge-std/Script.sol";

import {DeploymentIO} from "./DeploymentIO.sol";
import {StablecoinDeployment} from "./StablecoinDeployment.sol";

/**
 * @title Deploy
 * @notice Deploys and wires the Test Payment Dollar (AccessManager + v1 implementation + ERC-1967 proxy) and writes
 *         the addresses to `demo-out/deployment.json`.
 * @dev Keystore-based: no private key ever appears in the repository or in environment variables. This is what
 *      `scripts/demo.sh` runs (the password file is created there with mode 600):
 *
 *      forge script script/Deploy.s.sol --rpc-url $ETH_RPC_URL --broadcast \
 *          --keystore demo-out/keystores/deployer --password-file demo-out/keystores/.password \
 *          --sender <deployer address>
 *
 *      Role holders come from the environment: GOVERNANCE, MASTER_MINTER, PAUSER, BLOCKLISTER, COMPLIANCE_OFFICER,
 *      BRIDGE, UPGRADER, ATTESTOR and MINTERS (comma-separated). Limits default to the values below and can be
 *      overridden with MINTER_LIMIT_CEILING, BRIDGE_MINT_LIMIT and BRIDGE_BURN_LIMIT (token units, 6 decimals).
 *      GOVERNANCE may be the broadcaster itself: the wiring then re-grants its ADMIN role with the 2-day delay.
 */
contract Deploy is DeploymentIO {
    /// @notice Deploys, wires and records the deployment; the broadcaster becomes `cfg.deployer`.
    /// @dev Every transaction is sent by the keystore passed to `forge script`. The record (manager, token, v1
    ///      implementation, deployer, deployment block) is what `VerifyRoles.s.sol` and `UpgradeToV2.s.sol` read.
    /// @return d The deployed AccessManager, token proxy and v1 implementation.
    function run() external returns (StablecoinDeployment.Deployment memory d) {
        StablecoinDeployment.Config memory cfg = configFromEnv();
        uint256 deployBlock = block.number;

        vm.startBroadcast();
        (, cfg.deployer,) = vm.readCallers();
        d = StablecoinDeployment.deploy(cfg);
        vm.stopBroadcast();

        string memory key = "deployment";
        vm.serializeAddress(key, "manager", address(d.manager));
        vm.serializeAddress(key, "implementationV1", d.implementation);
        vm.serializeAddress(key, "deployer", cfg.deployer);
        vm.serializeUint(key, "deployBlock", deployBlock);
        string memory json = vm.serializeAddress(key, "token", address(d.token));
        vm.writeJson(json, deploymentFile());

        console2.log("AccessManager     ", address(d.manager));
        console2.log("tPD proxy         ", address(d.token));
        console2.log("v1 implementation ", d.implementation);
    }
}
