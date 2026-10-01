// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { BaseTest } from "../BaseTest.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { KestrelLending } from "kestrel/KestrelLending.sol";
import { KestrelPool } from "kestrel/KestrelPool.sol";
import { IPriceOracle } from "shared/IPriceOracle.sol";

/// @notice Unit tests for {KestrelLending}: happy paths and every revert path.
contract LendingUnit is BaseTest {
    function setUp() public override {
        super.setUp();
        _seedLending(500_000e18);
    }

    function _pledge(address who, uint256 amount) internal {
        _mintApprove(collateral, who, amount, address(lending));
        vm.prank(who);
        lending.depositCollateral(amount);
    }

    function test_constructor_rejectsPoolMismatch() public {
        vm.expectRevert(KestrelLending.PoolMismatch.selector);
        new KestrelLending(IERC20(address(collateral)), pool, vault, IPriceOracle(address(oracle)), config);
    }

    function test_supplyAndUnsupply() public {
        uint256 before = debt.balanceOf(lender);
        vm.prank(lender);
        lending.unsupply(100_000e18);
        assertEq(debt.balanceOf(lender) - before, 100_000e18);
        assertEq(lending.supplied(lender), 400_000e18);
        assertEq(lending.totalSupplied(), 400_000e18);
    }

    function test_lenderReverts() public {
        vm.expectRevert(KestrelLending.ZeroAmount.selector);
        lending.supply(0);
        vm.expectRevert(KestrelLending.ZeroAmount.selector);
        lending.unsupply(0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(KestrelLending.ExceedsBalance.selector, 1, 0));
        lending.unsupply(1);

        _pledge(alice, 1_000_000e18);
        vm.prank(alice);
        lending.borrow(450_000e18);
        vm.prank(lender);
        vm.expectRevert(
            abi.encodeWithSelector(KestrelLending.InsufficientLiquidity.selector, 100_000e18, 50_000e18)
        );
        lending.unsupply(100_000e18);
    }

    function test_borrowRepayAndWithdraw() public {
        _pledge(alice, 1000e18);
        vm.startPrank(alice);
        lending.borrow(500e18);
        assertEq(lending.debtOf(alice), 500e18);
        assertEq(lending.totalDebt(), 500e18);
        debt.approve(address(lending), type(uint256).max);
        lending.repay(500e18);
        assertEq(lending.debtOf(alice), 0);
        lending.withdrawCollateral(1000e18);
        vm.stopPrank();
        assertEq(collateral.balanceOf(alice), 1000e18);
    }

    function test_borrowerReverts() public {
        vm.expectRevert(KestrelLending.ZeroAmount.selector);
        lending.depositCollateral(0);
        vm.expectRevert(KestrelLending.ZeroAmount.selector);
        lending.depositVaultCollateral(0);
        vm.expectRevert(KestrelLending.ZeroAmount.selector);
        lending.withdrawCollateral(0);
        vm.expectRevert(KestrelLending.ZeroAmount.selector);
        lending.withdrawVaultCollateral(0);
        vm.expectRevert(KestrelLending.ZeroAmount.selector);
        lending.borrow(0);
        vm.expectRevert(KestrelLending.ZeroAmount.selector);
        lending.repay(0);

        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(KestrelLending.ExceedsBalance.selector, 1, 0));
        lending.withdrawCollateral(1);
        vm.expectRevert(abi.encodeWithSelector(KestrelLending.ExceedsBalance.selector, 1, 0));
        lending.withdrawVaultCollateral(1);
        vm.expectRevert(abi.encodeWithSelector(KestrelLending.ExceedsBalance.selector, 1, 0));
        lending.repay(1);
        vm.expectRevert(
            abi.encodeWithSelector(KestrelLending.InsufficientLiquidity.selector, 500_001e18, 500_000e18)
        );
        lending.borrow(500_001e18);
        vm.stopPrank();
    }

    function test_borrowRevertsWhenUndercollateralized() public {
        _pledge(alice, 1000e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(KestrelLending.Undercollateralized.selector, 751e18, 750e18));
        lending.borrow(751e18);
    }

    function test_withdrawRevertsWhenItWouldBreakHealth() public {
        _pledge(alice, 1000e18);
        vm.startPrank(alice);
        lending.borrow(700e18);
        vm.expectRevert(abi.encodeWithSelector(KestrelLending.Undercollateralized.selector, 700e18, 75e18));
        lending.withdrawCollateral(900e18);
        vm.stopPrank();
    }

    function test_vaultShareCollateralLifecycle() public {
        uint256 shares = _vaultDeposit(alice, 100 ether);
        vm.startPrank(alice);
        IERC20(address(vault)).approve(address(lending), shares);
        lending.depositVaultCollateral(shares);
        // ~100 ETH * 2000 * 75% = ~150k borrowing power.
        lending.borrow(100_000e18);
        vm.expectRevert(abi.encodeWithSelector(KestrelLending.Undercollateralized.selector, 100_000e18, 0));
        lending.withdrawVaultCollateral(shares);
        debt.approve(address(lending), type(uint256).max);
        lending.repay(100_000e18);
        lending.withdrawVaultCollateral(shares);
        vm.stopPrank();
        assertEq(lending.vaultCollateralOf(alice), 0);
        assertEq(vault.balanceOf(alice), shares);
    }

    function test_collateralValueCountsBothTypes() public {
        uint256 shares = _vaultDeposit(alice, 10 ether);
        vm.startPrank(alice);
        IERC20(address(vault)).approve(address(lending), shares);
        lending.depositVaultCollateral(shares);
        vm.stopPrank();
        _pledge(alice, 1000e18);
        uint256 expected = 1000e18 + shares * ETH_USD / 1e18;
        assertEq(lending.collateralValue(alice), expected, "1,000 at TWAP 1.0 + shares at 2,000");
        assertEq(lending.maxDebt(alice), expected * LTV_BPS / 10_000);
    }

    function test_referencePriceIsTheTwap() public view {
        assertEq(lending.referencePrice(), 1e18, "published average of a 1:1 pool");
        assertEq(lending.collateralValue(alice), 0, "no collateral, no oracle read");
    }
}
