// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {VaultFixture} from "../utils/VaultFixture.sol";

/// @notice Trust assumption 2 of docs/THREAT_MODEL.md, made exact. Share prices are kept in RAY (1e27) and the virtual
///         shares put at least 1e6 share units against the vault's assets, so every price fits in 256 bits as long as
///         total assets stay below 2^256 / 1e21 (about 2^186, or 1e56 base units), whatever the supply. Up to that bound
///         every view and the accrual keep working; far beyond it (only reachable with an asset whose supply is close
///         to 2^256) the price computation overflows and they revert. The a16z time-and-fees configuration found this
///         edge with a donation of ~2^255 that, unlike in the other configurations, unlocks into the price.
contract AssetBoundTest is VaultFixture {
    /// @dev The worst case for the price: the smallest possible supply (1 wei deposited, 1e6 share units) and a
    ///      donation that has fully unlocked.
    function _unlockedDonation(uint256 amount) internal {
        _deposit(alice, 1);
        asset.mint(address(vault), amount);
        vault.accrue();
        vm.warp(block.timestamp + 7 days);
    }

    function test_assetBound_everyViewWorksUpToTheBound() public {
        _unlockedDonation(2 ** 186);
        assertEq(vault.totalAssets(), 2 ** 186 + 1);
        assertEq(vault.maxWithdraw(alice), vault.convertToAssets(vault.balanceOf(alice)));
        assertEq(vault.maxRedeem(alice), vault.balanceOf(alice));
        assertGt(vault.sharePrice(), 0);
        assertLe(vault.safeSharePrice(), vault.sharePrice());
        vault.previewAccrual();
        vault.accrue();
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        assertEq(vault.redeem(shares, alice, alice), (2 ** 186 + 2) / 2, "half goes to the 1e6 virtual shares");
    }

    /// @dev The same bound with fees on, the largest supply the bound allows (2^186 assets deposited 1:1e6), and a
    ///      year of management fee and an unlocked donation to mint fee shares from.
    function test_assetBound_feeSharesFitAtTheBound() public {
        vm.prank(curator);
        vault.submitFees(0.5e18, 0.05e18); // the maximums, through the timelock
        vm.warp(block.timestamp + 3 days);
        vault.acceptFees();
        _deposit(alice, 2 ** 185);
        asset.mint(address(vault), 2 ** 185);
        vault.accrue();
        vm.warp(block.timestamp + 365 days);
        vault.accrue();
        assertGt(vault.balanceOf(feeRecipient), 0);
        assertLe(vault.totalSupply(), 2 ** 186 * 1e6);
    }

    function test_assetBound_pricesOverflowFarBeyondTheBound() public {
        _unlockedDonation(2 ** 200);
        vm.expectRevert(FixedPointMathLib.FullMulDivFailed.selector);
        vault.totalAssets();
    }
}
