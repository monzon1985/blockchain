// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ERC20} from "@openzeppelin-contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin-contracts/token/ERC20/extensions/ERC4626.sol";

/// @title FixtureVault
/// @notice Plain OpenZeppelin ERC-4626 vault over a `FixtureToken`, used by the indexer's integration
///         tests to exercise `Deposit` / `Withdraw` decoding and the derived share-price history.
/// @dev `totalAssets()` is the vault's balance of the asset (OpenZeppelin's default), so a plain
///      asset transfer to the vault is a "donation" that raises the share price without any vault
///      event. The indexer derives total assets from the asset token's `Transfer` logs, which is
///      why it sees donations too. A 3-decimal virtual-share offset mitigates the classic
///      first-depositor inflation attack; it is a test fixture, never deployed with value.
contract FixtureVault is ERC4626 {
    /// @notice Deploys the vault.
    /// @param asset_ Underlying ERC-20.
    /// @param name_ Share token name.
    /// @param symbol_ Share token symbol.
    constructor(IERC20 asset_, string memory name_, string memory symbol_)
        ERC20(name_, symbol_)
        ERC4626(asset_)
    {}

    /// @notice Virtual-share decimal offset (shares have `asset decimals + 3` decimals).
    /// @return Always 3.
    function _decimalsOffset() internal pure override returns (uint8) {
        return 3;
    }
}
