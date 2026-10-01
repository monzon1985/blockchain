// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {PasskeyAccount} from "../../src/PasskeyAccount.sol";
import {PasskeyAccountFactory} from "../../src/PasskeyAccountFactory.sol";
import {IPasskeyAccount} from "../../src/interfaces/IPasskeyAccount.sol";
import {BaseTest} from "../utils/BaseTest.sol";

contract PasskeyAccountFactoryTest is BaseTest {
    function test_CreateAccount_MatchesCounterfactualAddress() public {
        IPasskeyAccount.InitParams memory p = _initParams(PASSKEY_PK, _noGuardians(), 0);
        address predicted = factory.getAddress(p, bytes32("salt"));
        vm.expectEmit(address(factory));
        emit PasskeyAccountFactory.AccountCreated(predicted, p.passkey.qx, p.passkey.qy, bytes32("salt"));
        address deployed = factory.createAccount(p, bytes32("salt"));
        assertEq(deployed, predicted);
        assertTrue(PasskeyAccount(payable(deployed)).initialized());
        assertEq(PasskeyAccount(payable(deployed)).passkey().qx, p.passkey.qx);
    }

    function test_CreateAccount_IsIdempotent() public {
        IPasskeyAccount.InitParams memory p = _initParams(PASSKEY_PK, _noGuardians(), 0);
        address first = factory.createAccount(p, 0);
        vm.recordLogs();
        address second = factory.createAccount(p, 0);
        assertEq(first, second);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function test_Address_CommitsToEveryParameter() public {
        address[] memory g = new address[](1);
        g[0] = makeAddr("g");
        address a = factory.getAddress(_initParams(PASSKEY_PK, _noGuardians(), 0), 0);
        address b = factory.getAddress(_initParams(PASSKEY_PK, g, 1), 0);
        address c = factory.getAddress(_initParams(PASSKEY_PK_2, _noGuardians(), 0), 0);
        address d = factory.getAddress(_initParams(PASSKEY_PK, _noGuardians(), 0), bytes32(uint256(1)));
        assertTrue(a != b && a != c && a != d && b != c && b != d && c != d);
    }

    function test_FrontRunningCreateAccountIsHarmless() public {
        // Anyone can call createAccount, but the address commits to the parameters: a front-runner deploys exactly
        // the account the user asked for.
        IPasskeyAccount.InitParams memory p = _initParams(PASSKEY_PK, _noGuardians(), 0);
        vm.prank(makeAddr("frontrunner"));
        address deployed = factory.createAccount(p, 0);
        assertEq(PasskeyAccount(payable(deployed)).passkey().qx, p.passkey.qx);
    }

    function test_RogueCloneCannotBeInitializedByOthers() public {
        // A clone of the implementation not created by the factory stays uninitialized and unusable.
        address rogue = Clones.clone(address(implementation));
        IPasskeyAccount.InitParams memory p = _initParams(ATTACKER_PASSKEY_PK, _noGuardians(), 0);
        vm.expectRevert(abi.encodeWithSelector(IPasskeyAccount.InitializerUnauthorized.selector, address(this)));
        PasskeyAccount(payable(rogue)).initialize(p);
    }

    function test_Implementation_IsBoundToEntryPointAndFactory() public view {
        assertEq(address(implementation.entryPoint()), address(entryPoint));
        assertEq(implementation.FACTORY(), address(factory));
    }

    function testFuzz_GetAddress_MatchesDeployment(bytes32 salt, uint256 pkSeed) public {
        uint256 pk = bound(pkSeed, 1, 1e70);
        IPasskeyAccount.InitParams memory p = _initParams(pk, _noGuardians(), 0);
        assertEq(factory.createAccount(p, salt), factory.getAddress(p, salt));
    }
}
