// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { BaseTest } from "../BaseTest.sol";
import { KestrelLending } from "kestrel/KestrelLending.sol";
import { PoolTwapOracle } from "shared/PoolTwapOracle.sol";

/// @notice Review regressions for the TWAP oracle the lending market depends on.
///         (1) Nobody can freeze the market by calling the permissionless {PoolTwapOracle.update}:
///             it only closes full periods, and consumers read the stored average.
///         (2) A stale average is never used: reads revert past `maxAge`, and an over-long window
///             is discarded instead of being averaged over days of history.
///         (3) Accounts without debt never depend on the oracle.
contract ReviewOracleLivenessRegression is BaseTest {
    function setUp() public override {
        super.setUp();
        _seedLending(500_000e18);
        _mintApprove(collateral, alice, 1000e18, address(lending));
        vm.prank(alice);
        lending.depositCollateral(1000e18);
    }

    function test_review_earlyUpdateCannotFreezeLending() public {
        // A griefer pokes the oracle right after a publication: it reverts and changes nothing.
        vm.expectRevert(abi.encodeWithSelector(PoolTwapOracle.PeriodNotElapsed.selector, 0, TWAP_PERIOD));
        oracle.update();

        // Borrowing and withdrawing keep working on the stored average.
        vm.startPrank(alice);
        lending.borrow(100e18);
        lending.withdrawCollateral(100e18);
        vm.stopPrank();

        // Re-griefing just before every period boundary changes nothing either.
        vm.warp(block.timestamp + TWAP_PERIOD - 1);
        vm.expectRevert(
            abi.encodeWithSelector(PoolTwapOracle.PeriodNotElapsed.selector, TWAP_PERIOD - 1, TWAP_PERIOD)
        );
        oracle.update();
        vm.prank(alice);
        lending.borrow(100e18);
        assertEq(lending.debtOf(alice), 200e18, "market stays usable");
    }

    function test_review_zeroDebtWithdrawalNeverTouchesTheOracle() public {
        // Let the published price go stale.
        vm.warp(block.timestamp + TWAP_MAX_AGE + 1);
        vm.expectRevert(
            abi.encodeWithSelector(PoolTwapOracle.StalePrice.selector, TWAP_MAX_AGE + 1, TWAP_MAX_AGE)
        );
        oracle.priceToken0In1();

        // A debt-free account still withdraws its collateral.
        vm.prank(alice);
        lending.withdrawCollateral(1000e18);
        assertEq(collateral.balanceOf(alice), 1000e18, "withdrawn without a price");
    }

    function test_review_staleAverageCannotBeBorrowedAgainst() public {
        // 30 days without a keeper, then the collateral crashes on the AMM (spot < 0.1).
        vm.warp(block.timestamp + 30 days);
        _mintApprove(collateral, bob, 2_300_000e18, address(pool));
        vm.prank(bob);
        pool.swap(address(collateral), 2_300_000e18, 0, bob);
        assertLt(pool.spotPrice0In1(), 0.1e18, "spot crashed");

        // The attacker buys cheap collateral and tries to borrow at the pre-crash average.
        _mintApprove(debt, attacker, 1000e18, address(pool));
        vm.startPrank(attacker);
        uint256 bought = pool.swap(address(debt), 1000e18, 0, attacker);
        collateral.approve(address(lending), bought);
        lending.depositCollateral(bought);
        vm.expectRevert(abi.encodeWithSelector(PoolTwapOracle.StalePrice.selector, 30 days, TWAP_MAX_AGE));
        lending.borrow(5000e18);
        vm.stopPrank();
        assertGt(bought, 10_000e18, "> 10k collateral for 1k debt");

        // Poking the oracle discards the 30-day window instead of publishing its average.
        assertFalse(oracle.update(), "over-long window discarded");
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(PoolTwapOracle.StalePrice.selector, 30 days, TWAP_MAX_AGE));
        lending.borrow(5000e18);

        // One period later the oracle publishes the post-crash price; the borrow is refused.
        vm.warp(block.timestamp + TWAP_PERIOD);
        assertTrue(oracle.update(), "fresh window published");
        assertLt(oracle.priceToken0In1(), 0.1e18, "average reflects the crash");
        uint256 maxDebt = lending.maxDebt(attacker);
        assertLt(maxDebt, 1000e18, "borrowing power at the real price");
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(KestrelLending.Undercollateralized.selector, 5000e18, maxDebt));
        lending.borrow(5000e18);
    }
}
