// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {NaiveAllocatorVault} from "../naive/NaiveAllocatorVault.sol";
import {VaultFixture} from "../utils/VaultFixture.sol";

/// @title Harvest sandwich
/// @notice A harvest makes yield visible in the share price. The attacker (flash-loan sized, 10x the honest
///         depositor) deposits right before it and redeems right after.
///         - naive: the vault only sees strategy yield when its keeper calls `harvest()`; the attacker sandwiches that
///           call and takes ~10/11 of the yield;
///         - AllocatorVault values strategies live, so the event worth sandwiching is the strategy's own harvest (the
///           yield landing in the strategy). The attacker deposits before it and redeems after it: the profit is
///           locked and unlocks over 7 days, so the same-block attacker gets nothing back but rounding; holding for
///           `dt` earns, from that yield, at most `yield * dt / 7 days * attackerShare`, also when older profit is
///           still unlocking (all locked profit restarts a full 7-day line when new profit arrives).
contract HarvestSandwichTest is VaultFixture {
    uint256 internal constant HONEST = 1000e18;
    uint256 internal constant ATTACK = 10_000e18;
    uint256 internal constant YIELD = 100e18;

    function _depositTo(IERC4626 target, address user, uint256 assets) internal returns (uint256 shares) {
        asset.mint(user, assets);
        vm.startPrank(user);
        asset.approve(address(target), assets);
        shares = target.deposit(assets, user);
        vm.stopPrank();
    }

    function test_sandwich_naive_attackerCapturesMostOfTheHarvest() public {
        NaiveAllocatorVault naive = new NaiveAllocatorVault(IERC20(address(asset)), false);
        naive.addStrategy(liquid);
        _depositTo(naive, alice, HONEST);
        naive.allocate(liquid, HONEST);
        liquid.simulateYield(YIELD); // realized in the strategy, not yet harvested by the vault

        uint256 shares = _depositTo(naive, attacker, ATTACK); // front-run
        naive.harvest(); // the victim transaction
        vm.prank(attacker);
        uint256 out = naive.redeem(shares, attacker, attacker); // back-run

        int256 pnl = int256(out) - int256(ATTACK);
        emit log_named_decimal_int("naive: attacker P&L (tokens)", pnl, 18);
        assertGt(pnl, int256(YIELD * 90 / 100), "attacker takes > 90% of the harvest");
    }

    function test_sandwich_hardened_sameBlockAttackerGetsNothing() public {
        _deposit(alice, HONEST);
        _allocate(liquid, HONEST);

        uint256 shares = _deposit(attacker, ATTACK); // front-run
        liquid.simulateYield(YIELD); // the victim transaction: the strategy's harvest
        vault.accrue(); // (any keeper; redeeming below would accrue anyway)
        vm.prank(attacker);
        uint256 out = vault.redeem(shares, attacker, attacker); // back-run

        int256 pnl = int256(out) - int256(ATTACK);
        emit log_named_decimal_int("hardened: attacker P&L, same block (tokens)", pnl, 18);
        assertLe(pnl, 0, "the sandwich never profits in the same block");
        assertGe(pnl, -1, "and costs the attacker at most a wei of rounding");

        vm.warp(block.timestamp + 7 days);
        assertApproxEqAbs(vault.convertToAssets(vault.balanceOf(alice)), HONEST + YIELD, 2, "alice keeps the yield");
    }

    function test_sandwich_hardened_holdingEarnsOnlyTheTimeProRataShare() public {
        _deposit(alice, HONEST);
        _allocate(liquid, HONEST);

        uint256 shares = _deposit(attacker, ATTACK);
        liquid.simulateYield(YIELD);
        vault.accrue();
        uint256 hold = 1 hours;
        vm.warp(block.timestamp + hold);
        vm.prank(attacker);
        uint256 out = vault.redeem(shares, attacker, attacker);

        int256 pnl = int256(out) - int256(ATTACK);
        uint256 bound = YIELD * hold / 7 days * ATTACK / (ATTACK + HONEST);
        emit log_named_decimal_int("hardened: attacker P&L after 1 hour (tokens)", pnl, 18);
        emit log_named_decimal_uint("hardened: bound yield*dt/7d*share (tokens)", bound, 18);
        assertLe(pnl, int256(bound) + 1, "at most the unlocked slice pro rata");
    }

    function testFuzz_sandwich_hardened_profitBoundedByUnlockedSlice(uint256 attack, uint256 yield_, uint256 hold)
        public
    {
        attack = bound(attack, 1e18, 1e27);
        yield_ = bound(yield_, 1, 1e24);
        hold = bound(hold, 0, 14 days);
        _deposit(alice, HONEST);
        _allocate(liquid, HONEST);

        uint256 shares = _deposit(attacker, attack);
        liquid.simulateYield(yield_);
        vault.accrue();
        vm.warp(block.timestamp + hold);
        vm.prank(attacker);
        uint256 out = vault.redeem(shares, attacker, attacker);

        uint256 unlocked = hold >= 7 days ? yield_ : yield_ * hold / 7 days;
        uint256 bound_ = unlocked * attack / (attack + HONEST);
        assertLe(int256(out) - int256(attack), int256(bound_) + 1);
    }

    /// @dev Regression for the review finding: with older profit still unlocking, the old profit-weighted merge
    ///      released new yield in a fraction of 7 days (10,000 locked, 6 of 7 days in: 100 of new yield unlocked in
    ///      ~1.39 days, and the attacker took 51.09 against a 10.16 bound). Now all locked profit restarts a full
    ///      7-day line, so the attacker's gain attributable to the new yield (against an identical run without it)
    ///      stays within `yield * dt / 7 days * share`.
    function test_sandwich_hardened_lockedProfitDoesNotSpeedUpNewYield() public {
        _deposit(alice, HONEST);
        _allocate(liquid, HONEST);
        liquid.simulateYield(10_000e18); // an earlier, large harvest
        vault.accrue();
        vm.warp(block.timestamp + 6 days); // ~1,428.6 still locked, one day to go

        uint256 hold = 120_315; // how long the old merge took to release the new yield
        (int256 marginal, uint256 shareWad) = _marginalGain(ATTACK, YIELD, hold);
        uint256 bound_ = YIELD * hold / 7 days * shareWad / 1e18;
        emit log_named_decimal_int("hardened: gain from the new yield, 10,000 still unlocking (tokens)", marginal, 18);
        emit log_named_decimal_uint("hardened: bound yield*dt/7d*share (tokens)", bound_, 18);
        assertLe(marginal, int256(bound_) + 2);
    }

    /// @dev The time-proportional bound with a randomized amount of profit already locked and a randomized phase of
    ///      its unlock (the case the original fuzz test never reached).
    function testFuzz_sandwich_hardened_boundHoldsWithProfitAlreadyLocked(
        uint256 prior,
        uint256 phase,
        uint256 attack,
        uint256 yield_,
        uint256 hold
    ) public {
        prior = bound(prior, 0, 1e24);
        phase = bound(phase, 0, 7 days);
        attack = bound(attack, 1e18, 1e27);
        yield_ = bound(yield_, 1, 1e24);
        hold = bound(hold, 0, 14 days);
        _deposit(alice, HONEST);
        _allocate(liquid, HONEST);
        if (prior != 0) {
            liquid.simulateYield(prior);
            vault.accrue();
        }
        vm.warp(block.timestamp + phase);

        (int256 marginal, uint256 shareWad) = _marginalGain(attack, yield_, hold);
        uint256 unlocked = hold >= 7 days ? yield_ : yield_ * hold / 7 days;
        assertLe(marginal, int256(unlocked * shareWad / 1e18) + 2);
    }

    /// @dev Deposits `attack`, lets `yield_` land and be harvested, holds `hold` seconds and redeems; returns how much
    ///      more that paid than the same deposit and holding period without the yield, and the attacker's share of the
    ///      supply (WAD, rounded up).
    function _marginalGain(uint256 attack, uint256 yield_, uint256 hold)
        internal
        returns (int256 marginal, uint256 shareWad)
    {
        uint256 snapshot = vm.snapshotState();
        uint256 shares = _deposit(attacker, attack);
        shareWad = (shares * 1e18 + vault.totalSupply() - 1) / vault.totalSupply();
        liquid.simulateYield(yield_);
        vault.accrue();
        vm.warp(block.timestamp + hold);
        vm.prank(attacker);
        uint256 withYield = vault.redeem(shares, attacker, attacker);
        vm.revertToState(snapshot);

        shares = _deposit(attacker, attack);
        vault.accrue();
        vm.warp(block.timestamp + hold);
        vm.prank(attacker);
        uint256 withoutYield = vault.redeem(shares, attacker, attacker);
        marginal = int256(withYield) - int256(withoutYield);
    }
}
