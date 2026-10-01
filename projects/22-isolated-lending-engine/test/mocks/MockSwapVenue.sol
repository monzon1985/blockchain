// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IOracle} from "../../src/interfaces/IOracle.sol";
import {ISwapVenue} from "../../src/periphery/ISwapVenue.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Test double for a DEX: buys collateral at the market oracle price minus a fixed spread, paying out of a
///         pre-funded loan-token inventory. Used by unit tests and by the keeper's anvil end-to-end test.
contract MockSwapVenue is ISwapVenue {
    using SafeERC20 for IERC20;

    error UnsupportedPair(address tokenIn, address tokenOut);
    error Slippage(uint256 amountOut, uint256 minAmountOut);

    IOracle public immutable ORACLE;
    address public immutable COLLATERAL_TOKEN;
    address public immutable LOAN_TOKEN;
    uint256 public spreadBps;

    constructor(IOracle oracle, address collateralToken, address loanToken, uint256 initialSpreadBps) {
        ORACLE = oracle;
        COLLATERAL_TOKEN = collateralToken;
        LOAN_TOKEN = loanToken;
        spreadBps = initialSpreadBps;
    }

    function setSpreadBps(uint256 newSpreadBps) external {
        spreadBps = newSpreadBps;
    }

    function quote(uint256 amountIn) public view returns (uint256) {
        return amountIn * ORACLE.price() / 1e36 * (10_000 - spreadBps) / 10_000;
    }

    function swapExactIn(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut, address recipient)
        external
        returns (uint256 amountOut)
    {
        require(tokenIn == COLLATERAL_TOKEN && tokenOut == LOAN_TOKEN, UnsupportedPair(tokenIn, tokenOut));
        amountOut = quote(amountIn);
        require(amountOut >= minAmountOut, Slippage(amountOut, minAmountOut));
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenOut).safeTransfer(recipient, amountOut);
    }
}
