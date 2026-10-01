// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {NaiveAllocatorVault} from "../naive/NaiveAllocatorVault.sol";
import {VaultFixture} from "../utils/VaultFixture.sol";

/// @title 1-wei deposit/withdraw loop (rounding extraction)
/// @notice With the share price at 1.5, the attacker deposits 1 wei and withdraws 1 wei, 1,000 times.
///         - naive with caller-favoring rounding: each deposit rounds 0.67 shares up to 1 and each withdrawal rounds
///           0.67 shares down to 0, so every round trip keeps a free share (worth 1.5 wei) paid by the other holders;
///         - AllocatorVault: deposits round down, withdrawals round up, so no round trip ever pays the attacker: each one
///           leaves at least one share unit (worth less than a wei here) in the vault, and P&L stays at 0 or below.
contract OneWeiRoundingLoopTest is VaultFixture {
    uint256 internal constant ITERATIONS = 1000;

    function _loop(IERC4626 target) internal returns (int256 pnl) {
        uint256 before = asset.balanceOf(attacker) + target.convertToAssets(target.balanceOf(attacker));
        vm.startPrank(attacker);
        asset.approve(address(target), type(uint256).max);
        for (uint256 i; i < ITERATIONS; ++i) {
            target.deposit(1, attacker);
            target.withdraw(1, attacker, attacker);
        }
        vm.stopPrank();
        uint256 afterLoop = asset.balanceOf(attacker) + target.convertToAssets(target.balanceOf(attacker));
        pnl = int256(afterLoop) - int256(before);
    }

    function test_oneWeiLoop_naive_extractsValueEveryIteration() public {
        NaiveAllocatorVault naive = new NaiveAllocatorVault(IERC20(address(asset)), true);
        asset.mint(alice, 1000e18);
        vm.startPrank(alice);
        asset.approve(address(naive), 1000e18);
        naive.deposit(1000e18, alice);
        vm.stopPrank();
        asset.mint(address(naive), 500e18); // yield: price 1.5
        uint256 aliceBefore = naive.convertToAssets(naive.balanceOf(alice));

        asset.mint(attacker, 10);
        int256 pnl = _loop(naive);
        uint256 aliceAfter = naive.convertToAssets(naive.balanceOf(alice));

        emit log_named_int("naive: attacker P&L after 1000 loops (wei)", pnl);
        emit log_named_uint("naive: attacker free shares", naive.balanceOf(attacker));
        assertEq(naive.balanceOf(attacker), ITERATIONS, "one free share per iteration");
        assertGe(pnl, int256(ITERATIONS), "at least 1 wei per iteration");
        assertLt(aliceAfter, aliceBefore, "paid for by the honest holder");
    }

    function test_oneWeiLoop_hardened_neverProfits() public {
        _deposit(alice, 1000e18);
        asset.mint(address(vault), 500e18); // yield: price 1.5, once unlocked
        vault.accrue();
        vm.warp(block.timestamp + 7 days);
        assertApproxEqRel(vault.convertToAssets(1e6 * 1e18), 1.5e18, 1e12);

        _deposit(attacker, 1e18); // needs a position: 1 wei alone does not buy the shares a 1-wei withdraw burns
        asset.mint(attacker, 10);
        uint256 aliceBefore = vault.convertToAssets(vault.balanceOf(alice));
        uint256 sharesBefore = vault.balanceOf(attacker);

        int256 pnl = _loop(vault);
        uint256 aliceAfter = vault.convertToAssets(vault.balanceOf(alice));

        emit log_named_int("hardened: attacker P&L after 1000 loops (wei)", pnl);
        emit log_named_uint("hardened: attacker shares lost to rounding", sharesBefore - vault.balanceOf(attacker));
        assertLe(pnl, 0, "never profitable");
        assertGe(sharesBefore - vault.balanceOf(attacker), ITERATIONS, "at least one share unit lost per iteration");
        assertGe(aliceAfter, aliceBefore, "honest holders never pay");
    }
}
