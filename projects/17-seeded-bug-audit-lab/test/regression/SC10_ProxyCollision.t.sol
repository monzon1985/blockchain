// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { BaseTest } from "../BaseTest.sol";
import { KestrelConfig } from "shared/KestrelConfig.sol";
import { ConfigReinitAttacker } from "../attacks/ConfigReinitAttacker.sol";

/// @notice SC10 regression (fixed profile): the proxy keeps its admin at the EIP-1967 admin slot,
///         so slot 0 holds the implementation's real initializer flags and a second
///         {KestrelConfig.initialize} reverts.
contract SC10ProxyCollisionRegression is BaseTest {
    /// @dev EIP-1967 admin slot.
    bytes32 internal constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    function test_regression_reinitializeReverts() public {
        _seedLending(500_000e18);
        ConfigReinitAttacker atk = new ConfigReinitAttacker(address(proxy), vault, lending);
        vm.deal(address(atk), 1 ether);

        vm.expectRevert(KestrelConfig.AlreadyInitialized.selector);
        atk.attack{ value: 1 ether }(9000, 1e36, 500_000e18, attacker);

        assertEq(KestrelConfig(address(proxy)).owner(), riskOwner, "risk owner unchanged");
        assertEq(config.ethPrice(), ETH_USD, "price unchanged");
    }

    function test_regression_adminLivesAtEip1967Slot() public view {
        assertEq(
            address(uint160(uint256(vm.load(address(proxy), ADMIN_SLOT)))),
            proxyAdmin,
            "admin at EIP-1967 slot"
        );
        // Slot 0 holds only the implementation's flags: `_initialized = 1`, `_initializing = 0`.
        assertEq(uint256(vm.load(address(proxy), bytes32(0))), 1, "slot 0 == initialized flag only");
    }
}
