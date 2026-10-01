// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Script, console2} from "forge-std/Script.sol";
import {ZkGate} from "../src/ZkGate.sol";
import {CredentialVerifier} from "generated/CredentialVerifier.sol";
import {CredentialVerifierPlonk} from "generated/CredentialVerifierPlonk.sol";

/// @title Deploy
/// @notice Deploys the Groth16 + PLONK credential verifiers and a ZkGate. Keystore-based: no key ever
///         appears in this script or its environment. Sign with
///         `forge script script/Deploy.s.sol --rpc-url <rpc> --broadcast --keystore <file> --sender <addr>`
///         (or `--account <name>` for a cast-managed keystore). The broadcaster becomes the admin,
///         governor and date oracle.
/// @dev Configuration comes from the environment (roots from `node src/cli/world.ts roots`):
///        ZKG_ISSUER_ROOT, ZKG_REVOCATION_ROOT, ZKG_CURRENT_DATE  (required)
///        ZKG_SANCTIONED                 16 comma-separated ISO codes (required)
///        ZKG_ACTION_ID                  bytes32 (default keccak256("zk-kyc-gate:allowlist-v1"))
///        ZKG_EPOCH_DURATION             seconds (default 30 days)
///        ZKG_ISSUER_GRACE / ZKG_REVOCATION_GRACE   seconds (default 1 day / 1 hour)
contract Deploy is Script {
    /// @notice Deploy the verifiers and the gate.
    /// @return gate The deployed gate.
    function run() external returns (ZkGate gate) {
        uint256[] memory list = vm.envUint("ZKG_SANCTIONED", ",");
        require(list.length == 16, "ZKG_SANCTIONED needs 16 entries");
        uint256[16] memory sanctioned;
        for (uint256 i = 0; i < 16; i++) {
            sanctioned[i] = list[i];
        }

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        CredentialVerifier groth16 = new CredentialVerifier();
        CredentialVerifierPlonk plonk = new CredentialVerifierPlonk();
        gate = new ZkGate(
            ZkGate.GateConfig({
                groth16Verifier: address(groth16),
                plonkVerifier: address(plonk),
                admin: deployer,
                actionId: vm.envOr("ZKG_ACTION_ID", keccak256("zk-kyc-gate:allowlist-v1")),
                epochDuration: vm.envOr("ZKG_EPOCH_DURATION", uint256(30 days)),
                issuerRootGracePeriod: vm.envOr("ZKG_ISSUER_GRACE", uint256(1 days)),
                revocationRootGracePeriod: vm.envOr("ZKG_REVOCATION_GRACE", uint256(1 hours)),
                issuerRoot: vm.envUint("ZKG_ISSUER_ROOT"),
                revocationRoot: vm.envUint("ZKG_REVOCATION_ROOT"),
                currentDate: vm.envUint("ZKG_CURRENT_DATE"),
                sanctioned: sanctioned
            })
        );
        vm.stopBroadcast();

        console2.log("ZKGATE_ADDRESS", address(gate));
        console2.log("GROTH16_VERIFIER", address(groth16));
        console2.log("PLONK_VERIFIER", address(plonk));
    }
}
