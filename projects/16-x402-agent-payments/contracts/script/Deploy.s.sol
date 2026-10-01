// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {AgentAccountFactory} from "../src/account/AgentAccountFactory.sol";
import {PaymentEscrow} from "../src/escrow/PaymentEscrow.sol";
import {BudgetExecutor} from "../src/modules/BudgetExecutor.sol";
import {IdentityRegistry} from "../src/registry/IdentityRegistry.sol";
import {ReputationRegistry} from "../src/registry/ReputationRegistry.sol";
import {ValidationRegistry} from "../src/registry/ValidationRegistry.sol";
import {SettlementLog} from "../src/settlement/SettlementLog.sol";
import {TestUSD} from "../src/token/TestUSD.sol";
import {Script} from "forge-std/Script.sol";

/// @title Deploy
/// @notice Deploys the full local x402 stack and writes an address book to `deployments/<DEPLOYMENT_NAME>.json`.
/// @dev Intended for anvil only (TestUSD refuses any other chain id). No private key is ever passed: run with an
///      unlocked anvil account, e.g.
///      `forge script script/Deploy.s.sol --rpc-url $RPC --broadcast --unlocked --sender $DEPLOYER`.
///      The settlement log is sealed in the same broadcast, so the deployer keeps no power over receipts.
contract Deploy is Script {
    /// @notice Addresses produced by one deployment.
    struct Deployment {
        address testUSD;
        address settlementLog;
        address budgetExecutor;
        address paymentEscrow;
        address accountFactory;
        address identityRegistry;
        address reputationRegistry;
        address validationRegistry;
    }

    /// @notice Script entry point.
    /// @return d The deployed addresses.
    function run() external returns (Deployment memory d) {
        address deployer = msg.sender;
        vm.startBroadcast(deployer);
        d = deployAll(deployer);
        vm.stopBroadcast();
        _write(d, deployer);
    }

    /// @notice Deploys and wires every contract. Shared with the Foundry test fixture.
    /// @param deployer Owner of TestUSD and (until sealing) of the settlement log.
    /// @return d The deployed addresses.
    function deployAll(address deployer) public returns (Deployment memory d) {
        TestUSD token = new TestUSD(deployer);
        SettlementLog log = new SettlementLog(address(token), deployer);
        BudgetExecutor executor = new BudgetExecutor(log);
        PaymentEscrow escrow = new PaymentEscrow(log);
        AgentAccountFactory factory = new AgentAccountFactory(address(executor));
        IdentityRegistry identity = new IdentityRegistry();
        ReputationRegistry reputation = new ReputationRegistry(identity, log);
        ValidationRegistry validation = new ValidationRegistry(identity);

        log.setRecorder(address(executor), true);
        log.setRecorder(address(escrow), true);
        log.seal();

        d = Deployment({
            testUSD: address(token),
            settlementLog: address(log),
            budgetExecutor: address(executor),
            paymentEscrow: address(escrow),
            accountFactory: address(factory),
            identityRegistry: address(identity),
            reputationRegistry: address(reputation),
            validationRegistry: address(validation)
        });
    }

    function _write(Deployment memory d, address deployer) private {
        string memory key = "deployment";
        vm.serializeUint(key, "chainId", block.chainid);
        vm.serializeAddress(key, "deployer", deployer);
        vm.serializeAddress(key, "testUSD", d.testUSD);
        vm.serializeAddress(key, "settlementLog", d.settlementLog);
        vm.serializeAddress(key, "budgetExecutor", d.budgetExecutor);
        vm.serializeAddress(key, "paymentEscrow", d.paymentEscrow);
        vm.serializeAddress(key, "accountFactory", d.accountFactory);
        vm.serializeAddress(key, "identityRegistry", d.identityRegistry);
        vm.serializeAddress(key, "reputationRegistry", d.reputationRegistry);
        string memory json = vm.serializeAddress(key, "validationRegistry", d.validationRegistry);
        string memory name = vm.envOr("DEPLOYMENT_NAME", string("local"));
        string memory dir = string.concat(vm.projectRoot(), "/deployments");
        vm.createDir(dir, true);
        vm.writeJson(json, string.concat(dir, "/", name, ".json"));
    }
}
