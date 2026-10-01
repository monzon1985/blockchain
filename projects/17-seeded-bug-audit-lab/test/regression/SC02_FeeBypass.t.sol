// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { BaseTest } from "../BaseTest.sol";
import { FeeBypassAttacker } from "../attacks/FeeBypassAttacker.sol";

/// @notice SC02 regression (fixed profile): the batch path charges the same fee as the single
///         path, so the same trade through {batchSwap} pays exactly the quote, no more.
contract SC02FeeBypassRegression is BaseTest {
    function test_regression_batchChargesTheFee() public {
        uint256 amountIn = 10_000e18;
        FeeBypassAttacker atk = new FeeBypassAttacker(pool);
        collateral.mint(address(atk), amountIn);

        (uint256 quoted, uint256 received) = atk.run(address(collateral), address(debt), amountIn);

        assertEq(received, quoted, "batch output equals the fee-charging quote");
    }

    /// @dev Fee parity holds for any trade size and direction.
    function testFuzz_regression_batchMatchesQuote(uint256 amountIn, bool zeroForOne) public {
        amountIn = bound(amountIn, 1e6, 200_000e18);
        address tokenIn = zeroForOne ? address(collateral) : address(debt);
        address tokenOut = zeroForOne ? address(debt) : address(collateral);
        FeeBypassAttacker atk = new FeeBypassAttacker(pool);
        if (zeroForOne) collateral.mint(address(atk), amountIn);
        else debt.mint(address(atk), amountIn);

        (uint256 quoted, uint256 received) = atk.run(tokenIn, tokenOut, amountIn);
        assertEq(received, quoted, "batch == single");
    }
}
