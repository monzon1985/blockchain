// SPDX-License-Identifier: GPL-2.0-or-later
// Adapted from Morpho Blue by Morpho Labs, https://github.com/morpho-org/morpho-blue (GPL-2.0-or-later),
// src/libraries/SharesMathLib.sol: the virtual shares and assets and the four conversions follow the original; the
// NatSpec is new. Modified for this project in 2026; see the README's License section.
pragma solidity 0.8.37;

import {MathLib} from "./MathLib.sol";

/// @title SharesMathLib
/// @notice Conversions between assets and shares with virtual liquidity.
/// @dev The virtual offset (1e6 shares backed by 1 asset) makes the first depositor unable to inflate the share
///      price: donating `d` assets moves the price by at most `d / 1e6` per share, so the classic ERC-4626 inflation
///      attack costs the attacker a million times what it steals. Callers pick the rounding direction; the engine
///      always picks the one that favors the protocol (see `LendingEngine`). The Halmos suite
///      `SharesMathSymbolic` proves the three round-trip properties this relies on.
library SharesMathLib {
    using MathLib for uint256;

    /// @notice Virtual shares added to every total supply of shares.
    uint256 internal constant VIRTUAL_SHARES = 1e6;

    /// @notice Virtual assets added to every total of assets.
    uint256 internal constant VIRTUAL_ASSETS = 1;

    /// @notice Assets to shares, rounded down.
    /// @param assets Amount of assets.
    /// @param totalAssets Total assets of the pool.
    /// @param totalShares Total shares of the pool.
    /// @return The number of shares.
    function toSharesDown(uint256 assets, uint256 totalAssets, uint256 totalShares) internal pure returns (uint256) {
        return assets.mulDivDown(totalShares + VIRTUAL_SHARES, totalAssets + VIRTUAL_ASSETS);
    }

    /// @notice Shares to assets, rounded down.
    /// @param shares Amount of shares.
    /// @param totalAssets Total assets of the pool.
    /// @param totalShares Total shares of the pool.
    /// @return The number of assets.
    function toAssetsDown(uint256 shares, uint256 totalAssets, uint256 totalShares) internal pure returns (uint256) {
        return shares.mulDivDown(totalAssets + VIRTUAL_ASSETS, totalShares + VIRTUAL_SHARES);
    }

    /// @notice Assets to shares, rounded up.
    /// @param assets Amount of assets.
    /// @param totalAssets Total assets of the pool.
    /// @param totalShares Total shares of the pool.
    /// @return The number of shares.
    function toSharesUp(uint256 assets, uint256 totalAssets, uint256 totalShares) internal pure returns (uint256) {
        return assets.mulDivUp(totalShares + VIRTUAL_SHARES, totalAssets + VIRTUAL_ASSETS);
    }

    /// @notice Shares to assets, rounded up.
    /// @param shares Amount of shares.
    /// @param totalAssets Total assets of the pool.
    /// @param totalShares Total shares of the pool.
    /// @return The number of assets.
    function toAssetsUp(uint256 shares, uint256 totalAssets, uint256 totalShares) internal pure returns (uint256) {
        return shares.mulDivUp(totalAssets + VIRTUAL_ASSETS, totalShares + VIRTUAL_SHARES);
    }
}
