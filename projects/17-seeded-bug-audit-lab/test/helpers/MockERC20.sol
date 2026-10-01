// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Minimal mintable ERC-20 with configurable decimals, for tests only.
contract MockERC20 is ERC20 {
    uint8 private immutable _decimals;

    /// @param name_ Token name.
    /// @param symbol_ Token symbol.
    /// @param decimals_ Token decimals.
    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    /// @inheritdoc ERC20
    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    /// @notice Mint `amount` to `to`.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
