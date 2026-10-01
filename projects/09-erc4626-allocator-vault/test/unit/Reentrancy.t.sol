// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {MockReentrantStrategy} from "../mocks/MockReentrantStrategy.sol";
import {VaultFixture} from "../utils/VaultFixture.sol";

/// @notice A hostile strategy cannot read a half-updated price (read-only reentrancy) through any price view, or
///         re-enter any entry point. Every probe must revert with exactly `ReentrancyGuardReentrantCall`, so removing
///         the guard from any single view or entry point makes these tests fail.
contract ReentrancyTest is VaultFixture {
    MockReentrantStrategy internal hostile;
    bytes internal constant REENTRANT =
        abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);

    function setUp() public override {
        super.setUp();
        hostile = new MockReentrantStrategy(IERC20(address(asset)));
        _listStrategy(IERC4626(address(hostile)), _cap());
        IERC4626[] memory q = new IERC4626[](4);
        q[0] = hostile;
        q[1] = liquid;
        q[2] = lossy;
        q[3] = illiquid;
        vm.prank(allocator);
        vault.setWithdrawQueue(q);
        hostile.arm(vault);
        _deposit(alice, 1000 * unit);
    }

    function _assertEveryProbeBlocked() internal view {
        assertGt(hostile.rounds(), 0, "the hostile strategy was called");
        assertEq(hostile.probes(), 28);
        for (uint256 i; i < hostile.probes(); ++i) {
            string memory name = hostile.probeName(i);
            assertFalse(hostile.succeeded(i), name);
            assertEq(hostile.lastRevert(i), REENTRANT, name);
        }
    }

    function test_reentrancy_viewsAndEntryPointsBlockedDuringAllocation() public {
        _allocate(hostile, 500 * unit);
        _assertEveryProbeBlocked();
    }

    function test_reentrancy_viewsBlockedMidWithdrawal() public {
        _allocate(hostile, 1000 * unit);
        // Mid-withdrawal the shares are burned but the assets still sit in the strategy: a naive view would report
        // an inflated price here.
        vm.prank(alice);
        vault.withdraw(400 * unit, alice, alice);
        _assertEveryProbeBlocked();
        assertEq(asset.balanceOf(alice), 400 * unit);
    }

    function test_reentrancy_viewsWorkOutsideVaultCalls() public view {
        assertEq(vault.convertToAssets(1e6), 1);
        assertEq(vault.maxDeposit(alice), type(uint256).max);
    }
}
