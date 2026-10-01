// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";

import {Deploy} from "../../script/Deploy.s.sol";

contract DeployScriptTest is Test {
    function test_deployConfiguresTheGrid() public {
        Deploy script = new Deploy();
        address multisig = makeAddr("multisig");
        address keeper = makeAddr("keeper");
        vm.setEnv("OWNER", vm.toString(multisig));
        vm.setEnv("KEEPER", vm.toString(keeper));
        Deploy.Deployment memory d = script.run();

        assertTrue(d.engine.isIrmEnabled(address(d.irm)));
        assertEq(d.irm.ENGINE(), address(d.engine));
        assertEq(address(d.liquidator.ENGINE()), address(d.engine));
        assertEq(d.liquidator.owner(), keeper);
        assertTrue(d.engine.liquidationConfig(0.86e18).enabled);
        assertEq(d.engine.liquidationConfig(0.86e18).maxBonus, 0.02e18);
        assertTrue(d.engine.liquidationConfig(0.945e18).enabled);
        // Ownership is offered to the multisig and only moves when it accepts.
        assertEq(d.engine.pendingOwner(), multisig);
        vm.prank(multisig);
        d.engine.acceptOwnership();
        assertEq(d.engine.owner(), multisig);
    }
}
