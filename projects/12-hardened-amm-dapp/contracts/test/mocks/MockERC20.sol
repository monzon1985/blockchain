// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.37;

import {ERC20} from "solady/tokens/ERC20.sol";

/// @notice Well-behaved ERC-20 with configurable decimals and an open mint, for tests and the local demo.
contract MockERC20 is ERC20 {
    string private _name;
    string private _symbol;
    uint8 private immutable _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        _name = name_;
        _symbol = symbol_;
        _decimals = decimals_;
    }

    function name() public view override returns (string memory) {
        return _name;
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    /// @dev Tests and the local faucet only: anyone can mint.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @dev Plain allowances only; no implicit Permit2 allowance.
    function _givePermit2InfiniteAllowance() internal pure override returns (bool) {
        return false;
    }
}
