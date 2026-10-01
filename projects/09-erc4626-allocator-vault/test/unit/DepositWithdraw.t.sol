// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

import {IAllocatorVault} from "../../src/interfaces/IAllocatorVault.sol";
import {VaultFixture} from "../utils/VaultFixture.sol";

contract DepositWithdrawTest is VaultFixture {
    function test_deposit_mintsOneMillionSharesPerAssetUnitOnEmptyVault() public {
        uint256 assets = 1000 * _unit();
        asset.mint(alice, assets);
        vm.startPrank(alice);
        asset.approve(address(vault), assets);
        vm.expectEmit(address(vault));
        emit IERC4626.Deposit(alice, alice, assets, assets * 1e6);
        uint256 shares = vault.deposit(assets, alice);
        vm.stopPrank();

        assertEq(shares, assets * 1e6);
        assertEq(vault.balanceOf(alice), shares);
        assertEq(vault.totalAssets(), assets);
        assertEq(vault.lastTotalAssets(), assets);
        assertEq(asset.balanceOf(address(vault)), assets);
    }

    function test_deposit_toOtherReceiver() public {
        asset.mint(alice, 10 * _unit());
        vm.startPrank(alice);
        asset.approve(address(vault), 10 * _unit());
        uint256 shares = vault.deposit(10 * _unit(), bob);
        vm.stopPrank();
        assertEq(vault.balanceOf(bob), shares);
        assertEq(vault.balanceOf(alice), 0);
    }

    function test_deposit_zeroAssetsMintsZeroShares() public {
        vm.prank(alice);
        assertEq(vault.deposit(0, alice), 0);
    }

    function test_deposit_revertsWhenItWouldMintZeroShares() public {
        // Donate 1e6 wei to the empty vault and let it unlock: one wei is now worth less than one share.
        asset.mint(address(vault), 1e6);
        vault.accrue();
        vm.warp(block.timestamp + vault.PROFIT_UNLOCK_PERIOD());
        asset.mint(alice, 1);
        vm.startPrank(alice);
        asset.approve(address(vault), 1);
        vm.expectRevert(abi.encodeWithSelector(IAllocatorVault.ZeroShares.selector, 1));
        vault.deposit(1, alice);
        vm.stopPrank();
    }

    function test_mint_pullsAssetsRoundedUp() public {
        _deposit(bob, 1000 * _unit());
        // Make the price non-integer per share: 333 units of yield, unlocked.
        asset.mint(address(vault), 333 * _unit());
        vault.accrue();
        vm.warp(block.timestamp + 7 days);

        uint256 shares = 7;
        uint256 preview = vault.previewMint(shares);
        asset.mint(alice, preview);
        vm.startPrank(alice);
        asset.approve(address(vault), preview);
        uint256 assets = vault.mint(shares, alice);
        vm.stopPrank();
        assertEq(assets, preview);
        assertEq(vault.balanceOf(alice), shares);
        assertGe(assets, 1, "minting shares always costs at least one wei");
    }

    function test_withdraw_burnsSharesRoundedUp() public {
        _deposit(alice, 1000 * _unit());
        asset.mint(address(vault), 1); // an odd donation makes the price non-integer
        vault.accrue();
        vm.warp(block.timestamp + 7 days);

        uint256 preview = vault.previewWithdraw(1);
        vm.prank(alice);
        uint256 burned = vault.withdraw(1, alice, alice);
        assertEq(burned, preview);
        assertGt(burned, 0, "withdrawing one wei always burns shares");
        assertEq(asset.balanceOf(alice), 1);
    }

    function test_redeem_paysAssetsRoundedDown() public {
        _deposit(alice, 1000 * _unit());
        uint256 shares = vault.balanceOf(alice) / 3;
        uint256 preview = vault.previewRedeem(shares);
        vm.prank(alice);
        uint256 assets = vault.redeem(shares, alice, alice);
        assertEq(assets, preview);
        assertEq(asset.balanceOf(alice), assets);
    }

    function test_withdraw_byApprovedCallerSpendsAllowance() public {
        uint256 shares = _deposit(alice, 100 * _unit());
        vm.prank(alice);
        vault.approve(bob, shares);
        vm.prank(bob);
        uint256 burned = vault.withdraw(50 * _unit(), carol, alice);
        assertEq(asset.balanceOf(carol), 50 * _unit());
        assertEq(vault.allowance(alice, bob), shares - burned);
    }

    function test_withdraw_revertsWithoutAllowance() public {
        _deposit(alice, 100 * _unit());
        uint256 shares = vault.previewWithdraw(10 * _unit());
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, shares));
        vault.withdraw(10 * _unit(), bob, alice);
    }

    function test_redeem_revertsWithoutAllowance() public {
        uint256 shares = _deposit(alice, 100 * _unit());
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, shares));
        vault.redeem(shares, bob, alice);
    }

    function test_withdraw_revertsAboveBalance() public {
        _deposit(alice, 100 * _unit());
        uint256 tooMuch = 100 * _unit() + 1;
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxWithdraw.selector, alice, tooMuch, 100 * _unit())
        );
        vault.withdraw(tooMuch, alice, alice);
    }

    function test_redeem_revertsAboveBalance() public {
        uint256 shares = _deposit(alice, 100 * _unit());
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxRedeem.selector, alice, shares + 1, shares));
        vault.redeem(shares + 1, alice, alice);
    }

    function test_withdraw_pullsFromStrategiesInQueueOrder() public {
        _deposit(alice, 1000 * _unit());
        _allocate(liquid, 400 * _unit());
        _allocate(lossy, 400 * _unit());
        // Idle is 200: a 500 withdrawal takes 200 idle, then 300 from `liquid` (first in the queue), none from `lossy`.
        vm.prank(alice);
        vault.withdraw(500 * _unit(), alice, alice);
        assertEq(asset.balanceOf(address(vault)), 0);
        assertEq(_strategyValue(liquid), 100 * _unit());
        assertEq(_strategyValue(lossy), 400 * _unit());
        assertEq(vault.lastTotalAssets(), 500 * _unit());
    }

    function test_withdraw_takesPartialLiquidityFromIlliquidStrategy() public {
        _deposit(alice, 1000 * _unit());
        _allocate(illiquid, 1000 * _unit());
        illiquid.lend(700 * _unit()); // only 300 cash left in the market
        assertEq(vault.availableLiquidity(), 300 * _unit());
        assertEq(vault.maxWithdraw(alice), 300 * _unit());
        assertEq(vault.maxRedeem(alice), vault.convertToShares(300 * _unit()));

        vm.prank(alice);
        vault.withdraw(300 * _unit(), alice, alice);
        assertEq(asset.balanceOf(alice), 300 * _unit());
        assertEq(vault.maxWithdraw(alice), 0);
    }

    function test_withdraw_revertsWhenLiquidityIsShort() public {
        _deposit(alice, 1000 * _unit());
        _allocate(illiquid, 1000 * _unit());
        illiquid.lend(700 * _unit());
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAllocatorVault.InsufficientLiquidity.selector, 301 * _unit(), 300 * _unit())
        );
        vault.withdraw(301 * _unit(), alice, alice);
    }

    function test_redeem_allSharesAcrossIdleAndStrategies() public {
        _deposit(alice, 1000 * _unit());
        _allocate(liquid, 300 * _unit());
        _allocate(illiquid, 300 * _unit());
        uint256 assets = _redeemAll(alice);
        assertEq(assets, 1000 * _unit());
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.totalAssets(), 0);
    }

    function test_maxWithdraw_equalsOwnerAssetsWhenLiquid() public {
        _deposit(alice, 1000 * _unit());
        _allocate(liquid, 600 * _unit());
        assertEq(vault.maxWithdraw(alice), 1000 * _unit());
        assertEq(vault.maxRedeem(alice), vault.balanceOf(alice));
    }

    function test_views_matchStateAfterAccrue() public {
        _deposit(alice, 1000 * _unit());
        _allocate(liquid, 500 * _unit());
        liquid.simulateYield(50 * _unit());
        vm.warp(block.timestamp + 2 days);

        IAllocatorVault.Accrual memory preview = vault.previewAccrual();
        uint256 totalAssetsBefore = vault.totalAssets();
        vault.accrue();
        assertEq(vault.lastTotalAssets(), preview.grossAssets);
        assertEq(vault.totalAssets(), preview.totalAssets);
        assertEq(totalAssetsBefore, preview.totalAssets, "view already includes the pending accrual");
    }

    /// @dev Regression for a finding of the a16z suite: idle liquidity can hold a huge donation that is still locked,
    ///      and converting that liquidity to shares against the unlocked totalAssets overflowed, so maxRedeem reverted.
    function test_maxRedeem_doesNotRevertWithHugeLockedDonation() public {
        uint256 shares = _deposit(alice, 1);
        asset.mint(address(vault), type(uint256).max / 2);
        assertEq(vault.maxRedeem(alice), shares);
        assertEq(vault.maxWithdraw(alice), 1);
        vm.prank(alice);
        assertEq(vault.redeem(shares, alice, alice), 1);
    }
}
