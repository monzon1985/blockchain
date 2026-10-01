// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/Script.sol";

import {DeploymentIO} from "./DeploymentIO.sol";
import {RoleGraph} from "./RoleGraph.sol";
import {StablecoinDeployment} from "./StablecoinDeployment.sol";

/**
 * @title VerifyRoles
 * @notice Read-only post-deployment check of the proxy implementation and the role graph (members, current and
 *         pending execution delays, admins, guardians, grant delays, every selector mapping ever set on the token,
 *         and every operation still scheduled on the AccessManager). Reverts with the list of discrepancies.
 * @dev Uses the same environment as `Deploy.s.sol` for the expected role holders.
 *
 *      forge script script/VerifyRoles.s.sol --rpc-url $RPC
 */
contract VerifyRoles is DeploymentIO {
    /// @notice The live deployment differs from the configuration; each problem is logged before the revert.
    /// @param problems Number of discrepancies found.
    error RoleGraphMismatch(uint256 problems);

    /// @notice Verifies the deployment recorded in `deploymentFile()` against the role holders in the environment.
    /// @dev The expected wiring is chosen from the ERC-1967 implementation slot, never from the token's own
    ///      answers: the proxy must point at the recorded v1 implementation (v1 wiring expected) or at the v2
    ///      implementation recorded in `upgradeFile()` (v2 wiring expected). Any other implementation is reported
    ///      as a problem and the v1 wiring is checked. Reverts with {RoleGraphMismatch} if anything differs.
    function run() external view {
        Recorded memory r = readDeployment();
        StablecoinDeployment.Config memory cfg = configFromEnv();
        cfg.deployer = r.deployer;

        address live = RoleGraph.implementationOf(address(r.token));
        address implementationV2 = recordedImplementationV2();
        bool v2 = implementationV2 != address(0) && live == implementationV2;
        address expected = v2 ? implementationV2 : r.implementationV1;

        Vm.EthGetLogs[] memory raw = vm.eth_getLogs(r.deployBlock, block.number, address(r.manager), new bytes32[](0));
        string[] memory problems = RoleGraph.verify(r.manager, r.token, cfg, expected, v2, RoleGraph.fromRpc(raw));

        console2.log("proxy implementation ", live);
        console2.log("expected wiring      ", v2 ? "v2 (recorded upgrade)" : "v1 (recorded deployment)");
        console2.log("manager events read  ", raw.length);
        console2.log("expected memberships ", RoleGraph.expectedMembers(cfg).length);
        if (problems.length != 0) {
            for (uint256 i; i < problems.length; ++i) {
                console2.log("  PROBLEM:", problems[i]);
            }
            revert RoleGraphMismatch(problems.length);
        }
        console2.log(
            "role graph verified: implementation, members, delays, guardians, selectors match; nothing pending"
        );
    }
}
