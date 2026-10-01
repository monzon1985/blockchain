// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Script, console2} from "forge-std/Script.sol";

import {MockUSD} from "../test/mocks/MockUSD.sol";
import {PerpsDeployment} from "./PerpsDeployment.sol";

/// @title Deploy
/// @notice Deploys and wires the system from a keystore account (no raw private keys):
///
///     export SIGNERS=0xS1,0xS2,0xS3 KEEPERS=0xK1
///     forge script script/Deploy.s.sol --rpc-url $RPC --account deployer --broadcast
///
///         Optional: COLLATERAL (an existing 18-decimal stable; on chain 31337 a MockUSD is deployed when unset),
///         MARKET_NAME (default ETH-USD), RISK_ADMIN / ORACLE_ADMIN / GUARDIAN (default: the deployer),
///         GOVERNOR (final AccessManager admin, default: the deployer; production would use a multisig). The
///         governor holds the admin role with a 1-day execution delay, so every admin operation is timelocked.
contract Deploy is Script {
    /// @notice Runs the deployment and logs the addresses.
    /// @return s The deployed system.
    function run() external returns (PerpsDeployment.System memory s) {
        address[] memory signers = vm.envAddress("SIGNERS", ",");
        address[] memory keepers = vm.envAddress("KEEPERS", ",");
        string memory marketName = vm.envOr("MARKET_NAME", string("ETH-USD"));

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        address collateral = vm.envOr("COLLATERAL", address(0));
        if (collateral == address(0)) {
            require(block.chainid == 31_337, "COLLATERAL is required outside a local chain");
            collateral = address(new MockUSD(18));
        }
        s = PerpsDeployment.deploy(
            IERC20(collateral),
            PerpsDeployment.Config({
                admin: deployer,
                governor: vm.envOr("GOVERNOR", deployer),
                signers: signers,
                minSigners: 2,
                maxReportAge: 60,
                maxSpreadBps: 50,
                keepers: keepers,
                riskAdmin: vm.envOr("RISK_ADMIN", deployer),
                oracleAdmin: vm.envOr("ORACLE_ADMIN", deployer),
                guardian: vm.envOr("GUARDIAN", deployer),
                marketId: keccak256(bytes(marketName)),
                params: PerpsDeployment.defaultRiskParams()
            })
        );
        vm.stopBroadcast();

        console2.log("collateral    ", collateral);
        console2.log("accessManager ", address(s.manager));
        console2.log("oracle        ", address(s.oracle));
        console2.log("market        ", address(s.market));
        console2.log("orderBook     ", address(s.orderBook));
        console2.log("vault         ", address(s.vault));
    }
}
