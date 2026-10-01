// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {DeploySchnorrVault} from "../script/DeploySchnorrVault.s.sol";
import {SchnorrVault} from "../src/SchnorrVault.sol";
import {SchnorrTestBase} from "./utils/SchnorrTestBase.sol";

/// @notice The deployment script wires the environment into the constructor.
contract DeployScriptTest is SchnorrTestBase {
    function test_scriptDeploysWithEnvironmentConfiguration() public {
        Key memory key = makeKey(0xDE9);
        address guardian = makeAddr("guardian");
        vm.setEnv("GROUP_KEY_X", vm.toString(key.x));
        vm.setEnv("GROUP_KEY_PARITY", vm.toString(uint256(key.parity)));
        vm.setEnv("GUARDIAN", vm.toString(guardian));
        vm.setEnv("ETH_DAILY_LIMIT", "1000000000000000000");
        SchnorrVault vault = new DeploySchnorrVault().run();
        (uint256 x, uint8 parity, uint64 epoch) = vault.groupKey();
        assertEq(x, key.x);
        assertEq(parity, key.parity);
        assertEq(epoch, 0);
        assertEq(vault.guardian(), guardian);
        assertEq(vault.dailyLimit(address(0)), 1 ether);
    }
}
