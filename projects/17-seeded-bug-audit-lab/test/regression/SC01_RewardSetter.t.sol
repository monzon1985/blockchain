// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { BaseTest } from "../BaseTest.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { RewardRateAttacker } from "../attacks/RewardRateAttacker.sol";

/// @notice SC01 regression (fixed profile): the reward-rate setter is owner-gated, so the same
///         attack cannot change emissions and earns nothing.
contract SC01RewardSetterRegression is BaseTest {
    function test_regression_rewardRateIsOwnerGated() public {
        uint256 reserveAmount = 1000e18;
        reward.mint(deployer, reserveAmount);
        reward.approve(address(pool), type(uint256).max);
        pool.fundRewards(reserveAmount);

        RewardRateAttacker atk = new RewardRateAttacker(pool);
        collateral.mint(address(atk), 1000e18);
        debt.mint(address(atk), 1000e18);
        atk.stake(1000e18, 1000e18);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(atk)));
        atk.crank(1e30);

        vm.warp(block.timestamp + 100);
        assertEq(atk.harvest(attacker), 0, "no emissions without the owner");
        assertEq(pool.rewardReserve(), reserveAmount, "reserve intact");
        assertEq(pool.rewardRate(), 0, "rate unchanged");
    }
}
