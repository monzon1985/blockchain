// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IAllocatorVault} from "../../src/interfaces/IAllocatorVault.sol";
import {MockLiquidStrategy} from "../mocks/MockStrategies.sol";
import {VaultFixture} from "../utils/VaultFixture.sol";

/// @notice Strategy removal: forced deallocation, timelocked write-off, and loss realization in the same transaction.
contract StrategyRemovalTest is VaultFixture {
    function setUp() public override {
        super.setUp();
        _deposit(alice, 1000 * unit);
    }

    function _zeroCap(IERC4626 strategy) internal {
        vm.prank(guardian);
        vault.zeroCap(strategy);
    }

    function test_remove_emptyStrategyImmediately() public {
        _zeroCap(lossy);
        vm.expectEmit(address(vault));
        emit IAllocatorVault.StrategyRemoved(curator, lossy, 0, 0);
        vm.prank(curator);
        vault.removeStrategy(lossy);
        assertEq(vault.withdrawQueueLength(), 2);
        assertEq(address(vault.withdrawQueue(0)), address(liquid));
        assertEq(address(vault.withdrawQueue(1)), address(illiquid), "order of the others is preserved");
        assertFalse(vault.config(lossy).enabled);
    }

    function test_remove_liquidStrategyDeallocatesEverything() public {
        _allocate(liquid, 600 * unit);
        _zeroCap(liquid);
        vm.expectEmit(address(vault));
        emit IAllocatorVault.StrategyRemoved(curator, liquid, 600 * unit, 0);
        vm.prank(curator);
        vault.removeStrategy(liquid);
        assertEq(asset.balanceOf(address(vault)), 1000 * unit);
        assertEq(vault.totalAssets(), 1000 * unit, "no loss");
    }

    function test_remove_revertsWhenCapIsNotZero() public {
        uint256 cap = _cap();
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(IAllocatorVault.CapNotZero.selector, liquid, cap));
        vault.removeStrategy(liquid);
    }

    function test_remove_revertsForUnknownStrategy() public {
        MockLiquidStrategy stranger = new MockLiquidStrategy(IERC20(address(asset)));
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(IAllocatorVault.StrategyNotEnabled.selector, stranger));
        vault.removeStrategy(stranger);
    }

    function test_remove_illiquidRemainderNeedsForcedRemoval() public {
        _allocate(illiquid, 600 * unit);
        illiquid.lend(400 * unit);
        _zeroCap(illiquid);
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(IAllocatorVault.StrategyHasAssets.selector, illiquid, 400 * unit));
        vault.removeStrategy(illiquid);
    }

    function test_remove_forcedRemovalWaitsOutTimelock() public {
        _allocate(illiquid, 600 * unit);
        illiquid.lend(400 * unit);
        _zeroCap(illiquid);
        uint256 removableAt = block.timestamp + 3 days;
        vm.expectEmit(address(vault));
        emit IAllocatorVault.SubmitStrategyRemoval(curator, illiquid, removableAt);
        vm.prank(curator);
        vault.submitStrategyRemoval(illiquid);
        assertEq(vault.config(illiquid).removableAt, removableAt);

        vm.warp(removableAt - 1);
        vm.prank(curator);
        vm.expectRevert(
            abi.encodeWithSelector(IAllocatorVault.TimelockNotElapsed.selector, removableAt, removableAt - 1)
        );
        vault.removeStrategy(illiquid);
    }

    function test_remove_forcedRemovalWritesOffAndRealizesLossAtOnce() public {
        _deposit(bob, 1000 * unit);
        _allocate(illiquid, 600 * unit);
        illiquid.lend(400 * unit); // 400 stuck
        _zeroCap(illiquid);
        vm.prank(curator);
        vault.submitStrategyRemoval(illiquid); // redeems the 200 that can be redeemed
        vm.warp(block.timestamp + 3 days);

        vm.expectEmit(address(vault));
        emit IAllocatorVault.StrategyRemoved(curator, illiquid, 0, 400 * unit);
        vm.expectEmit(address(vault));
        emit IAllocatorVault.LossRealized(400 * unit, 0);
        vm.prank(curator);
        vault.removeStrategy(illiquid);

        assertEq(vault.totalAssets(), 1600 * unit);
        assertEq(vault.withdrawQueueLength(), 2);
        // Both holders bear the write-off pro rata.
        assertApproxEqAbs(vault.convertToAssets(vault.balanceOf(alice)), 800 * unit, 1);
        assertApproxEqAbs(vault.convertToAssets(vault.balanceOf(bob)), 800 * unit, 1);
    }

    /// @dev Regression for the review finding "the forced-removal window is a first-mover escape": the write-off of
    ///      what cannot be redeemed reaches the price when the removal is submitted, so a holder who exits during the
    ///      3-day window gets exactly what a holder who stays gets after the removal (it was 1,000 vs 600).
    function test_remove_forcedRemovalWindowGivesNoFirstMoverEscape() public {
        _deposit(bob, 1000 * unit);
        _allocate(illiquid, 600 * unit);
        illiquid.lend(400 * unit); // 400 cannot be redeemed
        _zeroCap(illiquid);
        assertEq(vault.totalAssets(), 2000 * unit, "illiquid is not lost: still counted in full");

        vm.expectEmit(address(vault));
        emit IAllocatorVault.Deallocate(curator, illiquid, 200 * unit, 200 * unit);
        vm.prank(curator);
        vault.submitStrategyRemoval(illiquid);
        assertEq(vault.totalAssets(), 1600 * unit, "the expected write-off is priced in at submission");
        assertEq(asset.balanceOf(address(vault)), 1600 * unit, "what was redeemable was redeemed at submission");
        assertEq(vault.strategyAssets(illiquid), 0, "the rest counts as 0");
        assertEq(address(vault.previewAccrual().impairedStrategy), address(illiquid));
        assertEq(vault.maxDeposit(carol), 0, "nobody can buy the markdown");

        uint256 aliceOut = _redeemAll(alice); // exits during the window
        vm.warp(block.timestamp + 3 days);
        vm.prank(curator);
        vault.removeStrategy(illiquid);
        uint256 bobOut = _redeemAll(bob);

        assertEq(aliceOut, 800 * unit, "first mover");
        assertApproxEqAbs(bobOut, aliceOut, 1, "last mover: same payout");
    }

    function test_remove_revokedRemovalRestoresTheValueAtOnce() public {
        _allocate(illiquid, 600 * unit);
        illiquid.lend(400 * unit);
        _zeroCap(illiquid);
        vm.prank(curator);
        vault.submitStrategyRemoval(illiquid);
        assertEq(vault.totalAssets(), 600 * unit);

        vm.prank(guardian);
        vault.revokePendingRemoval(illiquid);
        assertEq(vault.totalAssets(), 1000 * unit, "never booked as a loss, so nothing is re-locked");
        assertEq(address(vault.previewAccrual().impairedStrategy), address(0));
        vault.accrue();
        assertEq(vault.previewAccrual().lockedProfit, 0);
    }

    /// @dev Regression for the release-gate finding "flash liquidity reopens the first-mover escape": while the
    ///      removal is pending, a holder deposits flash-loaned liquidity into the strategy (so its `maxRedeem` covers
    ///      the vault's whole position), redeems, and takes the liquidity back out, all in one transaction. The
    ///      position no longer counts at anything the strategy reports live, so the exit price does not move (it was
    ///      1,000 vs 600 with the earlier `previewRedeem(min(shares, maxRedeem))` valuation).
    function test_remove_flashLiquidityCannotReopenTheFirstMoverEscape() public {
        _deposit(bob, 1000 * unit);
        _allocate(illiquid, 600 * unit);
        illiquid.lend(400 * unit);
        _zeroCap(illiquid);
        vm.prank(curator);
        vault.submitStrategyRemoval(illiquid);

        // Alice's single transaction: flash-borrow 400, deposit it into the strategy, redeem, withdraw it, repay.
        uint256 flash = 400 * unit;
        asset.mint(alice, flash);
        vm.startPrank(alice);
        asset.approve(address(illiquid), flash);
        illiquid.deposit(flash, alice);
        assertEq(illiquid.maxRedeem(address(vault)), illiquid.balanceOf(address(vault)), "fully redeemable now");
        assertEq(vault.totalAssets(), 1600 * unit, "but the exit price does not move");
        uint256 aliceOut = vault.redeem(vault.balanceOf(alice), alice, alice);
        illiquid.withdraw(flash, alice, alice);
        vm.stopPrank();
        asset.burn(alice, flash);

        vm.warp(block.timestamp + 3 days);
        vm.prank(curator);
        vault.removeStrategy(illiquid);
        uint256 bobOut = _redeemAll(bob);
        assertEq(aliceOut, 800 * unit);
        assertApproxEqAbs(bobOut, aliceOut, 1, "same payout");
    }

    /// @dev Borrowers repaying during the window do not move the price by themselves (that would be the same live
    ///      read a flash deposit can fake); the value comes back when it is actually recovered: here by the removal,
    ///      which then has nothing left to write off and needs no wait.
    function test_remove_repaymentDuringTheWindowIsRecoveredByTheRemoval() public {
        _allocate(illiquid, 600 * unit);
        illiquid.lend(400 * unit);
        _zeroCap(illiquid);
        vm.prank(curator);
        vault.submitStrategyRemoval(illiquid);
        assertEq(vault.totalAssets(), 600 * unit);

        illiquid.repay(400 * unit); // borrowers repay: everything is redeemable again
        assertEq(vault.totalAssets(), 600 * unit, "not counted until recovered");
        assertEq(vault.maxDeposit(carol), 0, "deposits stay paused until then");
        vm.prank(curator);
        vault.removeStrategy(illiquid); // nothing left to write off: no need to wait
        assertEq(vault.totalAssets(), 1000 * unit);
        assertEq(vault.previewAccrual().lockedProfit, 0, "never booked as a loss, so nothing is re-locked");
        assertEq(vault.maxDeposit(carol), type(uint256).max);
    }

    /// @dev The allocator can also recover repaid liquidity during the window; the price rises by what arrives.
    function test_remove_allocatorRecoversLiquidityDuringTheWindow() public {
        _allocate(illiquid, 600 * unit);
        illiquid.lend(400 * unit);
        _zeroCap(illiquid);
        vm.prank(curator);
        vault.submitStrategyRemoval(illiquid);
        illiquid.repay(150 * unit);

        IAllocatorVault.Allocation[] memory allocations = new IAllocatorVault.Allocation[](1);
        allocations[0] = IAllocatorVault.Allocation({strategy: illiquid, assets: 250 * unit});
        vm.prank(allocator);
        vault.reallocate(allocations);
        assertEq(vault.totalAssets(), 750 * unit, "recovered liquidity counts, the rest still does not");
        assertEq(address(vault.previewAccrual().impairedStrategy), address(illiquid));
    }

    function test_submitStrategyRemoval_booksProfitAndLossUpToNowFirst() public {
        _allocate(illiquid, 600 * unit);
        illiquid.simulateYield(60 * unit);
        illiquid.lend(400 * unit);
        _zeroCap(illiquid);
        vm.prank(curator);
        vault.submitStrategyRemoval(illiquid);
        // The yield was booked (and locked) at the full valuation before the 260 that was redeemable was redeemed and
        // the rest of the position started counting as 0.
        assertApproxEqAbs(vault.lastTotalAssets(), 1060 * unit, 1);
        assertApproxEqAbs(vault.previewAccrual().lockedProfit, 60 * unit, 1);
        // The 400 markdown first absorbs the 60 of profit that never reached the price; 340 reaches it.
        assertApproxEqAbs(vault.totalAssets(), 660 * unit, 2);
    }

    function test_remove_relistingWrittenOffStrategyReturnsValueAsLockedProfit() public {
        _allocate(illiquid, 600 * unit);
        illiquid.lend(400 * unit);
        _zeroCap(illiquid);
        vm.prank(curator);
        vault.submitStrategyRemoval(illiquid);
        vm.warp(block.timestamp + 3 days);
        vm.prank(curator);
        vault.removeStrategy(illiquid);
        assertEq(vault.totalAssets(), 600 * unit);

        // The loan is repaid; the curator re-lists the strategy after a new timelock.
        illiquid.repay(400 * unit);
        _listStrategy(illiquid, _cap());
        vault.accrue();
        assertEq(vault.totalAssets(), 600 * unit, "recovered value is profit: locked first");
        vm.warp(block.timestamp + 7 days);
        assertEq(vault.totalAssets(), 1000 * unit);
    }

    function test_submitStrategyRemoval_reverts() public {
        MockLiquidStrategy stranger = new MockLiquidStrategy(IERC20(address(asset)));
        uint256 cap = _cap();
        vm.startPrank(curator);
        vm.expectRevert(abi.encodeWithSelector(IAllocatorVault.StrategyNotEnabled.selector, stranger));
        vault.submitStrategyRemoval(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAllocatorVault.CapNotZero.selector, liquid, cap));
        vault.submitStrategyRemoval(liquid);
        vm.stopPrank();

        _zeroCap(liquid);
        vm.prank(curator);
        vault.submitCap(liquid, 1); // pending re-raise
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(IAllocatorVault.AlreadyPending.selector, block.timestamp + 3 days));
        vault.submitStrategyRemoval(liquid);

        vm.prank(guardian);
        vault.revokePendingCap(liquid);
        vm.prank(curator);
        vault.submitStrategyRemoval(liquid);
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(IAllocatorVault.AlreadyPending.selector, block.timestamp + 3 days));
        vault.submitStrategyRemoval(liquid);
    }

    function test_guardian_revokesPendingRemoval() public {
        _zeroCap(liquid);
        vm.prank(curator);
        vault.submitStrategyRemoval(liquid);
        vm.expectEmit(address(vault));
        emit IAllocatorVault.RevokePendingRemoval(guardian, liquid);
        vm.prank(guardian);
        vault.revokePendingRemoval(liquid);
        assertEq(vault.config(liquid).removableAt, 0);

        vm.prank(guardian);
        vm.expectRevert(IAllocatorVault.NoPendingValue.selector);
        vault.revokePendingRemoval(liquid);
    }

    function test_remove_dropsPendingCapOfRemovedStrategy() public {
        _zeroCap(lossy);
        vm.prank(curator);
        vault.submitCap(lossy, 1); // pending re-raise
        vm.expectEmit(address(vault));
        emit IAllocatorVault.RevokePendingCap(curator, lossy);
        vm.prank(curator);
        vault.removeStrategy(lossy);
        assertEq(vault.pendingCap(lossy).validAt, 0);
        vm.warp(block.timestamp + 3 days);
        vm.expectRevert(IAllocatorVault.NoPendingValue.selector);
        vault.acceptCap(lossy);
    }
}
