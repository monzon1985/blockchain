// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {VaultFixture} from "../utils/VaultFixture.sol";

/// @notice Bounded fuzz tests run for 6-, 8- and 18-decimal assets, with non-zero fees and a randomized prior state
///         (deposits spread over strategies, unlocked profit, a loss, illiquidity). Rounding directions are checked
///         against OpenZeppelin's `Math.mulDiv` as an independent reference.
abstract contract VaultFuzzBase is VaultFixture {
    uint256 internal constant V = 1e6;

    function _initialPerformanceFee() internal pure override returns (uint256) {
        return 0.15e18;
    }

    function _initialManagementFee() internal pure override returns (uint256) {
        return 0.02e18;
    }

    /// @dev Builds a random but valid vault state and accrues it, so stored totals equal view totals.
    function _randomState(uint256 seed) internal {
        uint256 principal = bound(uint256(keccak256(abi.encode(seed, 0))), unit, 1e9 * unit);
        _deposit(bob, principal);
        _allocate(liquid, principal / 4);
        _allocate(lossy, principal / 4);
        _allocate(illiquid, principal / 4);

        uint256 profit = bound(uint256(keccak256(abi.encode(seed, 1))), 0, principal / 5);
        liquid.simulateYield(profit);
        vault.accrue();
        vm.warp(block.timestamp + bound(uint256(keccak256(abi.encode(seed, 2))), 0, 10 days));

        uint256 loss = bound(uint256(keccak256(abi.encode(seed, 3))), 0, principal / 8);
        lossy.simulateLoss(loss);
        illiquid.lend(bound(uint256(keccak256(abi.encode(seed, 4))), 0, principal / 4));
        vault.accrue();
    }

    function _totals() internal view returns (uint256 supplyPlusV, uint256 taPlusOne) {
        supplyPlusV = vault.totalSupply() + V;
        taPlusOne = vault.totalAssets() + 1;
    }

    function testFuzz_previewDeposit_roundsDown(uint256 seed, uint256 assets) public {
        _randomState(seed);
        assets = bound(assets, 0, 1e12 * unit);
        (uint256 s, uint256 t) = _totals();
        assertEq(vault.previewDeposit(assets), Math.mulDiv(assets, s, t, Math.Rounding.Floor));
        assertEq(vault.convertToShares(assets), Math.mulDiv(assets, s, t, Math.Rounding.Floor));
    }

    function testFuzz_previewMint_roundsUp(uint256 seed, uint256 shares) public {
        _randomState(seed);
        shares = bound(shares, 0, 1e12 * unit * V);
        (uint256 s, uint256 t) = _totals();
        assertEq(vault.previewMint(shares), Math.mulDiv(shares, t, s, Math.Rounding.Ceil));
    }

    function testFuzz_previewWithdraw_roundsUp(uint256 seed, uint256 assets) public {
        _randomState(seed);
        assets = bound(assets, 0, 1e12 * unit);
        (uint256 s, uint256 t) = _totals();
        assertEq(vault.previewWithdraw(assets), Math.mulDiv(assets, s, t, Math.Rounding.Ceil));
    }

    function testFuzz_previewRedeem_roundsDown(uint256 seed, uint256 shares) public {
        _randomState(seed);
        shares = bound(shares, 0, 1e12 * unit * V);
        (uint256 s, uint256 t) = _totals();
        assertEq(vault.previewRedeem(shares), Math.mulDiv(shares, t, s, Math.Rounding.Floor));
        assertEq(vault.convertToAssets(shares), Math.mulDiv(shares, t, s, Math.Rounding.Floor));
    }

    function testFuzz_depositThenRedeem_neverProfits(uint256 seed, uint256 assets) public {
        _randomState(seed);
        assets = bound(assets, unit / 100 + 1, 1e10 * unit);
        uint256 shares = _deposit(alice, assets);
        vm.assume(vault.maxRedeem(alice) == shares); // enough liquidity for a full exit
        vm.prank(alice);
        uint256 out = vault.redeem(shares, alice, alice);
        assertLe(out, assets);
    }

    function testFuzz_mintThenWithdraw_neverProfits(uint256 seed, uint256 shares) public {
        _randomState(seed);
        shares = bound(shares, V, 1e10 * unit * V);
        uint256 cost = vault.previewMint(shares);
        asset.mint(alice, cost);
        vm.startPrank(alice);
        asset.approve(address(vault), cost);
        assertEq(vault.mint(shares, alice), cost);
        uint256 maxOut = vault.maxWithdraw(alice);
        vm.assume(maxOut != 0);
        uint256 expectedBurn = vault.previewWithdraw(maxOut);
        uint256 burned = vault.withdraw(maxOut, alice, alice);
        vm.stopPrank();
        assertEq(burned, expectedBurn, "burns exactly the (rounded-up) preview");
        assertLe(burned, shares);
        assertEq(vault.balanceOf(alice), shares - burned);
        // What came out plus what is left must not exceed what was paid: a withdrawal that burned too few shares
        // would leave the remainder worth more than it should.
        assertLe(maxOut + vault.convertToAssets(vault.balanceOf(alice)), cost);
    }

    function testFuzz_maxWithdrawAndMaxRedeem_areAlwaysExecutable(uint256 seed, uint256 lendBps) public {
        _randomState(seed);
        illiquid.lend(illiquid.cash() * bound(lendBps, 0, 10_000) / 10_000);
        uint256 maxAssets = vault.maxWithdraw(bob);
        uint256 snapshot = vm.snapshotState();
        vm.prank(bob);
        vault.withdraw(maxAssets, bob, bob);
        vm.revertToState(snapshot);

        uint256 maxShares = vault.maxRedeem(bob);
        vm.prank(bob);
        uint256 out = vault.redeem(maxShares, bob, bob);
        assertLe(out, maxAssets + 1);
    }

    function testFuzz_profitUnlocksLinearly(uint256 principal, uint256 profit, uint256 dt) public {
        principal = bound(principal, unit, 1e12 * unit);
        profit = bound(profit, 1, principal);
        dt = bound(dt, 0, 14 days);
        _deposit(alice, principal);
        asset.mint(address(vault), profit);
        vault.accrue();
        uint256 t0 = block.timestamp;
        vm.warp(t0 + dt);
        uint256 unlocked = dt >= 7 days ? profit : profit * dt / 7 days;
        assertEq(vault.previewAccrual().totalAssets, principal + unlocked);
    }

    function testFuzz_loss_scalesEveryHolderEqually(uint256 a, uint256 b, uint256 loss) public {
        a = bound(a, unit, 4e11 * unit); // a + b stays under the 1e12-unit strategy cap
        b = bound(b, unit, 4e11 * unit);
        _deposit(alice, a);
        _deposit(carol, b);
        _allocate(lossy, a + b);
        loss = bound(loss, 0, a + b);
        uint256 aBefore = vault.convertToAssets(vault.balanceOf(alice));
        uint256 cBefore = vault.convertToAssets(vault.balanceOf(carol));
        lossy.simulateLoss(loss);
        vault.accrue();
        uint256 aAfter = vault.convertToAssets(vault.balanceOf(alice));
        uint256 cAfter = vault.convertToAssets(vault.balanceOf(carol));
        // aAfter / aBefore == cAfter / cBefore, up to one wei of rounding on each side.
        assertApproxEqAbs(aAfter * cBefore, cAfter * aBefore, aBefore + cBefore);
    }
}

contract VaultFuzz6DecimalsTest is VaultFuzzBase {
    function _assetDecimals() internal pure override returns (uint8) {
        return 6;
    }
}

contract VaultFuzz8DecimalsTest is VaultFuzzBase {
    function _assetDecimals() internal pure override returns (uint8) {
        return 8;
    }
}

contract VaultFuzz18DecimalsTest is VaultFuzzBase {
    function _assetDecimals() internal pure override returns (uint8) {
        return 18;
    }
}
