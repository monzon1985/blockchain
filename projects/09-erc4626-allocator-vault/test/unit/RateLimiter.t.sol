// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {VaultMath} from "../../src/libraries/VaultMath.sol";
import {VaultFixture} from "../utils/VaultFixture.sol";

/// @notice `safeSharePrice` / `safeConvertToAssets`: the collateral-grade price for integrators.
contract RateLimiterTest is VaultFixture {
    function setUp() public override {
        super.setUp();
        _deposit(alice, 1000 * unit);
        _allocate(liquid, 1000 * unit);
    }

    function test_safePrice_tracksPriceUnderNormalYield() public {
        liquid.simulateYield(1 * unit); // 0.1 % over a week: far below the 25 %/year limit
        vault.accrue();
        for (uint256 i; i < 7; ++i) {
            vm.warp(block.timestamp + 1 days);
            vault.accrue();
            assertEq(vault.safeSharePrice(), vault.sharePrice());
        }
    }

    function test_safePrice_capsDonationInflation() public {
        // Someone doubles the vault's assets with a donation and waits out the unlock.
        uint256 checkpoint = vault.safeSharePrice();
        asset.mint(address(vault), 1000 * unit);
        vault.accrue();
        vm.warp(block.timestamp + 7 days);

        uint256 price = vault.sharePrice();
        uint256 safe = vault.safeSharePrice();
        assertApproxEqRel(price, 2 * checkpoint, 1e9, "the real price doubled");
        assertEq(safe, VaultMath.priceCeiling(checkpoint, GROWTH_LIMIT, 7 days), "safe price grew at 25%/year");
        assertLt(safe, checkpoint * 1005 / 1000, "less than +0.5% in a week");

        uint256 shares = vault.balanceOf(alice);
        assertLt(vault.safeConvertToAssets(shares), vault.convertToAssets(shares));
        assertApproxEqRel(vault.safeConvertToAssets(shares), 1000 * unit * 1005 / 1000, 0.001e18);
    }

    function test_safePrice_followsLossesDownAtOnce() public {
        uint256 before = vault.safeSharePrice();
        _allocate(liquid, 500 * unit);
        _allocate(lossy, type(uint256).max);
        lossy.simulateLoss(250 * unit);
        assertEq(vault.safeSharePrice(), vault.sharePrice(), "a drop is never smoothed");
        assertApproxEqRel(vault.safeSharePrice(), before * 3 / 4, 1e9);
    }

    function test_safePrice_growthResumesFromLowerCheckpointAfterLoss() public {
        _allocate(liquid, 500 * unit);
        _allocate(lossy, type(uint256).max);
        lossy.simulateLoss(250 * unit);
        vault.accrue();
        uint256 low = vault.safeSharePrice();
        lossy.simulateYield(250 * unit); // full recovery
        vault.accrue();
        vm.warp(block.timestamp + 7 days);
        assertEq(vault.safeSharePrice(), VaultMath.priceCeiling(low, GROWTH_LIMIT, 7 days));
        assertLt(vault.safeSharePrice(), vault.sharePrice());
    }

    /// @dev Regression for the review finding: re-anchoring the checkpoint at the ceiling on every accrual compounded
    ///      the limit (1.2839x a year with a daily `accrue()` at 25 %/year). While the limit binds the checkpoint now
    ///      stays put, so the result is the same linear 1.25x however often anyone accrues.
    function test_safePrice_frequentAccrualsDoNotCompoundTheLimit() public {
        uint256 p0 = vault.safeSharePrice();
        asset.mint(address(vault), 100_000 * unit); // the price rises ~100x once unlocked, far above any ceiling
        vault.accrue();

        uint256 snapshot = vm.snapshotState();
        vm.warp(block.timestamp + 365 days);
        uint256 lazy = vault.safeSharePrice();
        vm.revertToState(snapshot);

        for (uint256 i; i < 365; ++i) {
            vm.warp(block.timestamp + 1 days);
            vault.accrue();
        }
        uint256 eager = vault.safeSharePrice();
        assertEq(lazy, VaultMath.priceCeiling(p0, GROWTH_LIMIT, 365 days));
        assertEq(eager, lazy, "daily accruals give exactly the linear 25 %");
        assertLt(eager, vault.sharePrice());
    }

    function test_safePrice_reanchorsWhileTheLimitDoesNotBind() public {
        liquid.simulateYield(1 * unit);
        vault.accrue();
        vm.warp(block.timestamp + 7 days);
        vault.accrue(); // unconstrained: the checkpoint moves to the (lower than ceiling) share price
        uint256 anchored = vault.sharePrice();
        asset.mint(address(vault), 1000 * unit);
        vault.accrue();
        vm.warp(block.timestamp + 30 days);
        assertEq(vault.safeSharePrice(), VaultMath.priceCeiling(anchored, GROWTH_LIMIT, 30 days));
    }

    function test_safeConvertToAssets_neverExceedsConvertToAssets() public {
        liquid.simulateYield(3 * unit);
        vault.accrue();
        vm.warp(block.timestamp + 3 days);
        uint256 shares = vault.balanceOf(alice);
        assertLe(vault.safeConvertToAssets(shares), vault.convertToAssets(shares));
        assertLe(vault.safeConvertToAssets(1), vault.convertToAssets(1));
    }

    /// @dev Resupply-class scenario: a lending market values this vault's shares as collateral. An attacker owns
    ///      nearly all of a tiny supply and donates to inflate the price 1000x.
    function test_safePrice_resupplyClassInflationIsBounded() public {
        _redeemAll(alice);
        _deposit(attacker, 1); // 1 wei -> 1e6 shares
        uint256 shares = vault.balanceOf(attacker);
        uint256 collateralBefore = vault.safeConvertToAssets(shares);

        asset.mint(address(vault), 1000 * unit); // donation
        vault.accrue();
        vm.warp(block.timestamp + 7 days);
        vault.accrue();

        uint256 raw = vault.convertToAssets(shares);
        uint256 safe = vault.safeConvertToAssets(shares);
        assertGt(raw, 400 * unit, "raw valuation explodes (half the donation goes to the virtual shares)");
        assertLe(safe, collateralBefore + 1, "rate-limited valuation stays at the pre-attack value");
    }
}
