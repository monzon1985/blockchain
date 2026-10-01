// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { BaseTest } from "../BaseTest.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { FixedTreeErrors } from "../helpers/FixedTreeErrors.sol";
import { ReadOnlyReentrancyAttacker } from "../attacks/ReadOnlyReentrancyAttacker.sol";

/// @notice SC08 regression (fixed profile): the vault settles `totalManaged` before the ETH
///         transfer and its price views revert mid-operation, so the reentrant borrow fails with
///         `ReentrantRead` and no debt is created.
contract SC08ReadOnlyReentrancyRegression is BaseTest {
    function test_regression_readOnlyReentrancyBlocked() public {
        _seedLending(500_000e18);
        _vaultDeposit(alice, 100 ether);

        ReadOnlyReentrancyAttacker atk = new ReadOnlyReentrancyAttacker(vault, lending, IERC20(address(debt)));
        vm.deal(address(atk), 300 ether);
        atk.depositToVault(300 ether);
        atk.pledge(100 ether);

        atk.run(200 ether, 250_000e18);

        assertTrue(atk.attempted(), "the callback tried to borrow");
        assertFalse(atk.borrowed(), "the borrow failed");
        assertEq(
            atk.lastError(),
            abi.encodeWithSelector(FixedTreeErrors.ReentrantRead.selector),
            "blocked by the guard"
        );
        assertEq(lending.debtOf(address(atk)), 0, "no debt created");
        assertEq(lending.maxDebt(address(atk)), 150_000e18, "valuation unchanged after the redemption");
    }
}
