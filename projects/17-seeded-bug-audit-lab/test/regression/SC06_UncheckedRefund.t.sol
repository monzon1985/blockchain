// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { BaseTest } from "../BaseTest.sol";
import { FixedTreeErrors } from "../helpers/FixedTreeErrors.sol";
import { RefundStrander } from "../attacks/RefundStrander.sol";

/// @notice SC06 regression (fixed profile): a failed refund reverts the whole sponsored swap, so
///         no ETH is ever stranded and `pool.balance == nativeFeesCollected` holds.
contract SC06UncheckedRefundRegression is BaseTest {
    function test_regression_failedRefundReverts() public {
        RefundStrander strander = new RefundStrander(pool);
        uint256 amountIn = 1000e18;
        collateral.mint(address(strander), amountIn);

        uint256 value = NATIVE_FEE + 5 ether;
        vm.deal(address(this), value);

        vm.expectRevert(FixedTreeErrors.RefundFailed.selector);
        strander.sponsoredSwap{ value: value }(address(collateral), amountIn);

        assertEq(address(pool).balance, 0, "no ETH stranded");
        assertEq(pool.nativeFeesCollected(), 0, "nothing accounted");
    }

    /// @dev The exact fee needs no refund, so a non-receiving caller can still use the path.
    function test_regression_exactFeeNeedsNoRefund() public {
        RefundStrander strander = new RefundStrander(pool);
        collateral.mint(address(strander), 1000e18);
        vm.deal(address(this), NATIVE_FEE);

        strander.sponsoredSwap{ value: NATIVE_FEE }(address(collateral), 1000e18);

        assertEq(address(pool).balance, pool.nativeFeesCollected(), "balance == collected fees");
    }
}
