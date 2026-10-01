// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";

import {SharesMathLib} from "../../src/libraries/SharesMathLib.sol";

/// @notice Bounded fuzz companion of the Halmos proofs in `test/halmos/SharesMathSymbolic.t.sol`, over the full
///         uint128 range the engine stores.
contract SharesMathFuzzTest is Test {
    using SharesMathLib for uint256;

    function _bounds(uint256 assets, uint256 totalAssets, uint256 totalShares)
        internal
        pure
        returns (uint256, uint256, uint256)
    {
        // Totals are stored as uint128 by the engine; keep 1e6 of headroom for the virtual offset.
        totalAssets = bound(totalAssets, 0, type(uint128).max - 1e6);
        totalShares = bound(totalShares, 0, type(uint128).max - 1e6);
        // The engine casts minted shares to uint128, so only amounts whose share value fits are reachable.
        uint256 maxAssets = uint256(type(uint128).max) * (totalAssets + 1) / (totalShares + 1e6);
        assets = bound(assets, 0, maxAssets < type(uint128).max ? maxAssets : type(uint128).max);
        return (assets, totalAssets, totalShares);
    }

    /// Supplying assets and withdrawing the minted shares never returns more than was supplied.
    function testFuzz_supplyThenWithdrawNeverProfits(uint256 assets, uint256 totalAssets, uint256 totalShares)
        public
        pure
    {
        (assets, totalAssets, totalShares) = _bounds(assets, totalAssets, totalShares);
        uint256 shares = assets.toSharesDown(totalAssets, totalShares);
        assertLe(shares.toAssetsDown(totalAssets, totalShares), assets);
    }

    /// Withdrawing `assets` burns shares worth at least `assets`.
    function testFuzz_withdrawBurnsEnoughShares(uint256 assets, uint256 totalAssets, uint256 totalShares) public pure {
        (assets, totalAssets, totalShares) = _bounds(assets, totalAssets, totalShares);
        uint256 shares = assets.toSharesUp(totalAssets, totalShares);
        assertGe(shares.toAssetsDown(totalAssets, totalShares), assets);
    }

    /// Borrowing `assets` mints debt worth at least `assets`.
    function testFuzz_borrowMintsEnoughDebt(uint256 assets, uint256 totalAssets, uint256 totalShares) public pure {
        (assets, totalAssets, totalShares) = _bounds(assets, totalAssets, totalShares);
        uint256 shares = assets.toSharesUp(totalAssets, totalShares);
        assertGe(shares.toAssetsUp(totalAssets, totalShares), assets);
    }

    /// Repaying `assets` never burns debt worth more than `assets`.
    function testFuzz_repayBurnsNoExcessDebt(uint256 assets, uint256 totalAssets, uint256 totalShares) public pure {
        (assets, totalAssets, totalShares) = _bounds(assets, totalAssets, totalShares);
        uint256 shares = assets.toSharesDown(totalAssets, totalShares);
        assertLe(shares.toAssetsUp(totalAssets, totalShares), assets);
    }

    /// Up and down conversions differ by at most one unit.
    function testFuzz_upAndDownDifferByAtMostOne(uint256 amount, uint256 totalAssets, uint256 totalShares) public pure {
        (amount, totalAssets, totalShares) = _bounds(amount, totalAssets, totalShares);
        uint256 down = amount.toAssetsDown(totalAssets, totalShares);
        uint256 up = amount.toAssetsUp(totalAssets, totalShares);
        assertLe(up - down, 1);
        down = amount.toSharesDown(totalAssets, totalShares);
        up = amount.toSharesUp(totalAssets, totalShares);
        assertLe(up - down, 1);
    }
}
