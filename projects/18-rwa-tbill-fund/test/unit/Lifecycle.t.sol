// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {FundFixture} from "../utils/FundFixture.sol";

/// @notice End-to-end fund lifecycle across every component.
contract LifecycleTest is FundFixture {
    function test_fullLifecycle_subscribeTradeYieldRedeem() public {
        // Epoch 1: two subscriptions at NAV 1.00.
        _requestDeposit(alice, 100_000 * USDC);
        _requestDeposit(carol, 50_000 * USDC);
        assertEq(vault.pendingDepositRequest(0, alice), 100_000 * USDC);
        _closeAndSettle(NAV_ONE);
        assertEq(vault.claimableDepositRequest(0, alice), 100_000 * USDC);
        assertEq(vault.pendingDepositRequest(0, alice), 0);

        vm.prank(alice);
        uint256 aliceShares = vault.deposit(100_000 * USDC, alice, alice);
        vm.prank(carol);
        uint256 carolShares = vault.mint(50_000 * USDC, carol, carol);
        assertEq(aliceShares, 100_000 * USDC);
        assertEq(carolShares, 50_000 * USDC);
        assertEq(engine.holderCount(US), 1);
        assertEq(engine.holderCount(DE), 1);

        // Invest idle cash with the custodian.
        vm.prank(fundAdmin);
        vault.deployToCustodian(150_000 * USDC);
        assertEq(vault.idleAssets(), 0);

        // Lockup elapses; alice sells part of her position to bob.
        vm.warp(block.timestamp + LOCKUP + 1);
        vm.prank(alice);
        share.transfer(bob, 40_000 * USDC);
        assertEq(engine.holderCount(US), 2);
        assertEq(engine.totalHolders(), 3);

        // Epoch 2: bob redeems everything; NAV accrued 1 %.
        vm.prank(bob);
        vault.requestRedeem(40_000 * USDC, bob, bob);
        assertEq(engine.holderCount(US), 1);
        _close();
        // The fund recalls principal plus yield to pay the redemption.
        usdc.mint(custodian, 1500 * USDC);
        vm.prank(fundAdmin);
        vault.recallFromCustodian(41_500 * USDC);
        _postAndSettle(1.01e18);

        assertEq(vault.maxRedeem(bob), 40_000 * USDC);
        assertEq(vault.maxWithdraw(bob), 40_400 * USDC);
        vm.prank(bob);
        uint256 paid = vault.redeem(40_000 * USDC, bob, bob);
        assertEq(paid, 40_400 * USDC);
        assertEq(usdc.balanceOf(bob), 40_400 * USDC);
        assertEq(vault.totalAssets(), 110_000 * USDC * 101 / 100);
    }
}
