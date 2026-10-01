// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";

import {SharesMathLib} from "../../src/libraries/SharesMathLib.sol";

/// @notice Halmos proofs that every asset/share conversion in the engine rounds in the protocol's favor, for all
///         `uint128` inputs (the width the engine stores totals and positions in).
/// @dev Each property is stated against the exact rational share price `(totalAssets + 1) / (totalShares + 1e6)`,
///      so it says "the caller never gets more than the exact value" rather than just "round trips don't profit".
///
///      Method: SMT solvers cannot bit-blast symbolic 256-bit division in reasonable time (even `q * d <= n` for
///      16-bit inputs times out with yices and z3), so each proof states two facts about EVM arithmetic as explicit
///      assumptions and lets Halmos prove the rest over uninterpreted multiplication and division:
///        (A1) Euclidean division: `(n / d) * d + n % d == n` and `n % d < d` for `d != 0`;
///        (A2) distributivity: `(q + 1) * d == q * d + d`.
///      Both hold for every input on which the checked arithmetic does not revert, so assuming them excludes no
///      real execution. Paths that overflow revert in the engine and are not counterexamples.
///
///      Run with `halmos --match-contract SharesMathSymbolic`.
contract SharesMathSymbolic is Test {
    using SharesMathLib for uint256;

    /// @dev Assumes the Euclidean division identity (A1) for `n / d`.
    function _assumeDivision(uint256 n, uint256 d) internal pure {
        vm.assume((n / d) * d + n % d == n);
        vm.assume(n % d < d);
    }

    /// Property 1: `toSharesDown` never credits more shares than the assets are worth.
    /// Used when supplying by assets (supply shares minted) and repaying by assets (debt shares burned).
    function check_toSharesDownNeverOvercredits(uint128 assets, uint128 totalAssets, uint128 totalShares) public pure {
        uint256 n = uint256(assets) * (uint256(totalShares) + SharesMathLib.VIRTUAL_SHARES);
        uint256 d = uint256(totalAssets) + SharesMathLib.VIRTUAL_ASSETS;
        _assumeDivision(n, d);

        uint256 shares = uint256(assets).toSharesDown(totalAssets, totalShares);
        // shares * (totalAssets + 1) <= assets * (totalShares + 1e6)
        assert(shares * d <= n);
    }

    /// Property 2: `toSharesUp` always charges at least the shares the assets are worth.
    /// Used when withdrawing by assets (supply shares burned) and borrowing by assets (debt shares minted).
    function check_toSharesUpAlwaysCovers(uint128 assets, uint128 totalAssets, uint128 totalShares) public pure {
        uint256 n = uint256(assets) * (uint256(totalShares) + SharesMathLib.VIRTUAL_SHARES);
        uint256 d = uint256(totalAssets) + SharesMathLib.VIRTUAL_ASSETS;
        _assumeDivision(n, d);
        vm.assume((n / d + 1) * d == (n / d) * d + d); // (A2)

        uint256 shares = uint256(assets).toSharesUp(totalAssets, totalShares);
        // shares * (totalAssets + 1) >= assets * (totalShares + 1e6)
        assert(shares * d >= n);
    }

    /// Property 3: share-denominated operations round assets against the caller in both directions.
    /// `toAssetsDown` (withdraw or borrow by shares) pays out at most the exact value; `toAssetsUp` (supply or repay
    /// by shares) charges at least the exact value.
    function check_toAssetsRoundAgainstCaller(uint128 shares, uint128 totalAssets, uint128 totalShares) public pure {
        uint256 n = uint256(shares) * (uint256(totalAssets) + SharesMathLib.VIRTUAL_ASSETS);
        uint256 d = uint256(totalShares) + SharesMathLib.VIRTUAL_SHARES;
        _assumeDivision(n, d);
        vm.assume((n / d + 1) * d == (n / d) * d + d); // (A2)

        uint256 paidOut = uint256(shares).toAssetsDown(totalAssets, totalShares);
        uint256 charged = uint256(shares).toAssetsUp(totalAssets, totalShares);
        // paidOut * (totalShares + 1e6) <= shares * (totalAssets + 1) <= charged * (totalShares + 1e6)
        assert(paidOut * d <= n);
        assert(charged * d >= n);
    }
}
