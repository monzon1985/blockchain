// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { KestrelPool } from "kestrel/KestrelPool.sol";

/// @notice SC06 helper: a contract with NO `receive`/`fallback`, so any ETH refund from
///         {KestrelPool.swapWithNativeSponsor} fails. On the vulnerable tree the failure is
///         swallowed and the ETH is stranded; on the fixed tree the swap reverts.
contract RefundStrander {
    KestrelPool public immutable pool;

    constructor(KestrelPool _pool) {
        pool = _pool;
    }

    /// @notice Perform a sponsored swap sending `msg.value` (fee + overpayment) with no way to
    ///         receive the refund.
    /// @param tokenIn Input token.
    /// @param amountIn Input amount (must be pre-funded and this contract must approve `pool`).
    function sponsoredSwap(address tokenIn, uint256 amountIn) external payable {
        IERC20(tokenIn).approve(address(pool), amountIn);
        pool.swapWithNativeSponsor{ value: msg.value }(tokenIn, amountIn, 0, address(this));
    }
}
