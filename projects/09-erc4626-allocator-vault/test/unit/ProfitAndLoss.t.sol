// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IAllocatorVault} from "../../src/interfaces/IAllocatorVault.sol";
import {VaultFixture} from "../utils/VaultFixture.sol";

/// @notice Linear profit unlocking over 7 days, immediate loss recognition, and loss socialization.
/// @dev Exact-number tests realize profit as a donation to the vault's idle balance: strategy yield is valued through
///      the (OpenZeppelin, offset 0) mock strategy's own virtual share, which keeps a wei of it.
contract ProfitAndLossTest is VaultFixture {
    function setUp() public override {
        super.setUp();
        _deposit(alice, 1000 * unit);
        _allocate(liquid, 500 * unit);
        _allocate(lossy, 500 * unit);
    }

    function _profit(uint256 assets) internal {
        asset.mint(address(vault), assets);
    }

    function test_profit_isLockedInTheBlockItAppears() public {
        _profit(70 * unit);
        assertEq(vault.totalAssets(), 1000 * unit, "view: profit is not in the price yet");

        uint256 unlockEnd = block.timestamp + 7 days;
        vm.expectEmit(address(vault));
        emit IAllocatorVault.ProfitLocked(70 * unit, 70 * unit, unlockEnd);
        vault.accrue();
        assertEq(vault.totalAssets(), 1000 * unit);
        assertEq(vault.lastTotalAssets(), 1070 * unit);
        IAllocatorVault.Accrual memory a = vault.previewAccrual();
        assertEq(a.lockedProfit, 70 * unit);
        assertEq(a.unlockEnd, unlockEnd);
    }

    function test_profit_unlocksLinearlyOverSevenDays() public {
        _profit(70 * unit);
        vault.accrue();
        uint256 t0 = block.timestamp;

        vm.warp(t0 + 1 days);
        assertEq(vault.totalAssets(), 1010 * unit);
        vm.warp(t0 + 3.5 days);
        assertEq(vault.totalAssets(), 1035 * unit);
        vault.accrue(); // re-anchoring the schedule mid-way changes nothing
        vm.warp(t0 + 6 days);
        assertEq(vault.totalAssets(), 1060 * unit);
        vm.warp(t0 + 7 days);
        assertEq(vault.totalAssets(), 1070 * unit);
        vm.warp(t0 + 30 days);
        assertEq(vault.totalAssets(), 1070 * unit);
    }

    function test_profit_unlockRoundsTheLockedPartUp() public {
        _profit(7); // 7 wei over 7 days: 1 wei per day
        vault.accrue();
        vm.warp(block.timestamp + 1 days - 1);
        // floor(7 * 86399 / 604800) = 0 unlocked: totalAssets never runs ahead of the schedule.
        assertEq(vault.totalAssets(), 1000 * unit);
        vm.warp(block.timestamp + 1);
        assertEq(vault.totalAssets(), 1000 * unit + 1);
    }

    function test_profit_newProfitRestartsTheScheduleForAllLockedProfit() public {
        _profit(70 * unit);
        vault.accrue();
        uint256 t0 = block.timestamp;
        vm.warp(t0 + 3.5 days); // 35 locked, 3.5 days remaining
        _profit(35 * unit);
        vm.expectEmit(address(vault));
        emit IAllocatorVault.ProfitLocked(35 * unit, 70 * unit, t0 + 10.5 days);
        vault.accrue();
        IAllocatorVault.Accrual memory a = vault.previewAccrual();
        assertEq(a.lockedProfit, 70 * unit);
        assertEq(a.unlockEnd, t0 + 3.5 days + 7 days, "a full period from now, for old and new profit alike");
        assertEq(vault.totalAssets(), 1035 * unit);
        vm.warp(t0 + 7 days);
        assertEq(vault.totalAssets(), 1070 * unit, "the old profit now unlocks more slowly: 35 of 70 after 3.5 days");
        vm.warp(t0 + 10.5 days);
        assertEq(vault.totalAssets(), 1105 * unit);
    }

    function test_profit_unlockStartsAtTheFirstAccrualThatSeesIt() public {
        _profit(100 * unit);
        vm.warp(block.timestamp + 30 days);
        assertEq(vault.totalAssets(), 1000 * unit, "unobserved profit does not unlock on its own");
        vault.accrue();
        vm.warp(block.timestamp + 7 days);
        assertEq(vault.totalAssets(), 1100 * unit);
    }

    function test_profit_strategyYieldIsLockedToo() public {
        liquid.simulateYield(100 * unit);
        uint256 profit = _grossAssets() - 1000 * unit;
        assertApproxEqAbs(profit, 100 * unit, 1, "the mock strategy's virtual share keeps at most a wei");
        vault.accrue();
        assertEq(vault.totalAssets(), 1000 * unit);
        vm.warp(block.timestamp + 7 days);
        assertEq(vault.totalAssets(), 1000 * unit + profit);
    }

    function test_loss_isRecognizedInTheSameTransaction() public {
        lossy.simulateLoss(100 * unit);
        assertEq(vault.totalAssets(), 900 * unit, "view reflects the loss before anyone touches the vault");
        vm.expectEmit(address(vault));
        emit IAllocatorVault.LossRealized(100 * unit, 0);
        vault.accrue();
        assertEq(vault.totalAssets(), 900 * unit);
        assertEq(vault.maxWithdraw(alice), 900 * unit);
    }

    function test_loss_isAbsorbedByLockedProfitFirst() public {
        _profit(100 * unit);
        vault.accrue();
        uint256 priceBefore = vault.sharePrice();

        lossy.simulateLoss(60 * unit);
        vm.expectEmit(address(vault));
        emit IAllocatorVault.LossRealized(60 * unit, 60 * unit);
        vault.accrue();
        assertEq(vault.sharePrice(), priceBefore, "a loss smaller than the locked profit never reaches the price");
        assertEq(vault.previewAccrual().lockedProfit, 40 * unit);

        vm.warp(block.timestamp + 7 days);
        assertEq(vault.totalAssets(), 1040 * unit);
    }

    function test_loss_excessOverLockedProfitHitsPrice() public {
        _profit(100 * unit);
        vault.accrue();
        vm.warp(block.timestamp + 3.5 days); // 50 unlocked, 50 locked
        assertEq(vault.totalAssets(), 1050 * unit);

        lossy.simulateLoss(80 * unit);
        vault.accrue();
        assertEq(vault.previewAccrual().lockedProfit, 0);
        assertEq(vault.totalAssets(), 1020 * unit, "50 absorbed, 30 lowered the price");
    }

    function test_loss_isSocializedEqually() public {
        _deposit(bob, 3000 * unit);
        uint256 aliceBefore = vault.convertToAssets(vault.balanceOf(alice));
        uint256 bobBefore = vault.convertToAssets(vault.balanceOf(bob));
        lossy.simulateLoss(400 * unit); // 10 % of 4000
        uint256 aliceAfter = vault.convertToAssets(vault.balanceOf(alice));
        uint256 bobAfter = vault.convertToAssets(vault.balanceOf(bob));
        assertApproxEqAbs(aliceAfter, aliceBefore * 9 / 10, 1);
        assertApproxEqAbs(bobAfter, bobBefore * 9 / 10, 1);
    }

    function test_previewAccrual_reportsProfitAndLossFields() public {
        _profit(10 * unit);
        IAllocatorVault.Accrual memory a = vault.previewAccrual();
        assertEq(a.profit, 10 * unit);
        assertEq(a.loss, 0);
        assertEq(a.grossAssets, 1010 * unit);
        vault.accrue();
        lossy.simulateLoss(15 * unit);
        a = vault.previewAccrual();
        assertEq(a.profit, 0);
        assertEq(a.loss, 15 * unit);
        assertEq(a.lossAbsorbed, 10 * unit);
    }
}
