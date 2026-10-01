// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockUSD
/// @notice Freely mintable stablecoin used as collateral in tests, the replay and the local demo. Not for production.
contract MockUSD is ERC20 {
    uint8 private immutable _decimals;

    /// @param decimals_ Token decimals (the market requires 18; other values exercise the constructor check).
    constructor(uint8 decimals_) ERC20("Mock USD", "mUSD") {
        _decimals = decimals_;
    }

    /// @notice Mints `amount` to `to`. Unrestricted: test token only.
    /// @param to Recipient.
    /// @param amount Amount in base units.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @inheritdoc ERC20
    function decimals() public view override returns (uint8) {
        return _decimals;
    }
}
