// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin-contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {FundDeployment, FundContracts, FundConfig, GovernanceDelays} from "./FundDeployment.sol";

/// @title Deploy
/// @notice Keystore-based deployment of the demo fund. No private key is read by the script.
/// @dev forge script script/Deploy.s.sol --rpc-url $RPC_URL --account <keystore> --sender <address> --broadcast
///      Required env: FUND_ASSET, FUND_ADMIN, TRANSFER_AGENT, NAV_ORACLE, COMPLIANCE_OFFICER.
///      Optional env: FUND_NAME, FUND_SYMBOL, FUND_INITIAL_NAV, FUND_LOCKUP_SECONDS, FUND_CUSTODIAN,
///      FUND_GOVERNANCE (receives the AccessManager ADMIN role; the deployer then renounces it; defaults to the
///      deployer), and the AccessManager delays in seconds: GOVERNANCE_EXECUTION_DELAY (default 2 days),
///      ROLE_GRANT_DELAY (default 2 days), TARGET_ADMIN_DELAY (default 2 days), TRANSFER_AGENT_EXECUTION_DELAY
///      (default 0). Share decimals are read from the settlement asset (the vault also enforces equality).
contract Deploy is Script {
    function run() external returns (FundContracts memory c) {
        IERC20 asset = IERC20(vm.envAddress("FUND_ASSET"));
        FundConfig memory cfg = FundConfig({
            asset: asset,
            decimals: IERC20Metadata(address(asset)).decimals(),
            name: vm.envOr("FUND_NAME", string("Demo T-Bill Fund Share")),
            symbol: vm.envOr("FUND_SYMBOL", string("dTBILL")),
            initialNav: uint128(vm.envOr("FUND_INITIAL_NAV", uint256(1e18))),
            lockupPeriod: uint64(vm.envOr("FUND_LOCKUP_SECONDS", uint256(1 days))),
            fundAdmin: vm.envAddress("FUND_ADMIN"),
            transferAgent: vm.envAddress("TRANSFER_AGENT"),
            navOracle: vm.envAddress("NAV_ORACLE"),
            complianceOfficer: vm.envAddress("COMPLIANCE_OFFICER")
        });
        GovernanceDelays memory delays = GovernanceDelays({
            governanceExecution: uint32(vm.envOr("GOVERNANCE_EXECUTION_DELAY", uint256(2 days))),
            transferAgentExecution: uint32(vm.envOr("TRANSFER_AGENT_EXECUTION_DELAY", uint256(0))),
            roleGrant: uint32(vm.envOr("ROLE_GRANT_DELAY", uint256(2 days))),
            targetAdmin: uint32(vm.envOr("TARGET_ADMIN_DELAY", uint256(2 days)))
        });
        address custodian = vm.envOr("FUND_CUSTODIAN", address(0));

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        address governance = vm.envOr("FUND_GOVERNANCE", deployer);
        c = FundDeployment.deploy(cfg, deployer);
        if (custodian != address(0)) c.vault.setCustodian(custodian);
        // Last: once governance holds ADMIN behind its execution delay, admin calls must be scheduled.
        FundDeployment.handOverGovernance(c, cfg, governance, deployer, delays);
        vm.stopBroadcast();

        console2.log("AccessManager      ", address(c.manager));
        console2.log("IdentityRegistry   ", address(c.registry));
        console2.log("ComplianceEngine   ", address(c.engine));
        console2.log("DocumentRegistry   ", address(c.documents));
        console2.log("FundShareToken     ", address(c.share));
        console2.log("FundVault          ", address(c.vault));
        console2.log("DividendDistributor", address(c.distributor));
    }
}
