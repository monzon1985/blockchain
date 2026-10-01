// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";

import {Deploy} from "../../script/Deploy.s.sol";
import {PasskeyAccountFactory} from "../../src/PasskeyAccountFactory.sol";
import {TestUSD} from "../../src/TestUSD.sol";
import {TokenPaymaster} from "../../src/TokenPaymaster.sol";

contract DeployScriptTest is Test {
    function test_Run_WiresEverythingToTheEntryPoint() public {
        address ep = makeAddr("entryPoint");
        address admin = makeAddr("admin");
        vm.setEnv("ENTRY_POINT", vm.toString(ep));
        vm.setEnv("ADMIN", vm.toString(admin));
        vm.setEnv("TOKEN_PER_NATIVE", "2500000000");
        (PasskeyAccountFactory factory, TestUSD usd, TokenPaymaster paymaster) = new Deploy().run();
        assertEq(address(factory.ACCOUNT_IMPLEMENTATION().entryPoint()), ep);
        assertEq(factory.ACCOUNT_IMPLEMENTATION().FACTORY(), address(factory));
        assertEq(usd.owner(), admin);
        assertEq(paymaster.owner(), admin);
        assertEq(address(paymaster.entryPoint()), ep);
        assertEq(address(paymaster.TOKEN()), address(usd));
        assertEq(paymaster.tokenPerNative(), 2500e6);
    }
}
