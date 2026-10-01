// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Deploy} from "../../script/Deploy.s.sol";
import {PaymentEscrow} from "../../src/escrow/PaymentEscrow.sol";
import {BudgetExecutor} from "../../src/modules/BudgetExecutor.sol";
import {SettlementLog} from "../../src/settlement/SettlementLog.sol";
import {TestUSD} from "../../src/token/TestUSD.sol";
import {Test} from "forge-std/Test.sol";

contract DeployScriptTest is Test {
    function test_RunDeploysSealedStackAndWritesAddressBook() public {
        vm.setEnv("DEPLOYMENT_NAME", "forge-test");
        Deploy script = new Deploy();
        Deploy.Deployment memory d = script.run();

        SettlementLog log = SettlementLog(d.settlementLog);
        assertTrue(log.isSealed());
        assertEq(log.owner(), address(0));
        assertTrue(log.isRecorder(d.budgetExecutor));
        assertTrue(log.isRecorder(d.paymentEscrow));
        assertEq(log.asset(), d.testUSD);
        assertEq(address(BudgetExecutor(d.budgetExecutor).ASSET()), d.testUSD);
        assertEq(address(PaymentEscrow(d.paymentEscrow).ASSET()), d.testUSD);
        assertEq(TestUSD(d.testUSD).decimals(), 6);

        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/deployments/forge-test.json"));
        assertEq(vm.parseJsonAddress(json, ".settlementLog"), d.settlementLog);
        assertEq(vm.parseJsonAddress(json, ".validationRegistry"), d.validationRegistry);
        assertEq(vm.parseJsonUint(json, ".chainId"), block.chainid);
        vm.removeFile(string.concat(vm.projectRoot(), "/deployments/forge-test.json"));
    }
}
