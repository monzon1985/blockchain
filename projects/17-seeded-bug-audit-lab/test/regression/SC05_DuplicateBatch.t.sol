// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { BaseTest } from "../BaseTest.sol";
import { FixedTreeErrors } from "../helpers/FixedTreeErrors.sol";
import { DuplicateBatchAttacker } from "../attacks/DuplicateBatchAttacker.sol";

/// @notice SC05 regression (fixed profile): {batchSwap} rejects a duplicated asset, so the same
///         double-count attack reverts.
contract SC05DuplicateBatchRegression is BaseTest {
    function test_regression_duplicateAssetRejected() public {
        uint256 y = 50_000e18;
        DuplicateBatchAttacker atk = new DuplicateBatchAttacker(pool);
        debt.mint(address(atk), 2 * y);

        vm.expectRevert(abi.encodeWithSelector(FixedTreeErrors.DuplicateAsset.selector, address(collateral)));
        atk.attack(y, attacker);

        assertEq(pool.reserve0(), collateral.balanceOf(address(pool)), "reserves match balances");
    }
}
