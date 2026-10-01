// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ERC20} from "@openzeppelin-contracts/token/ERC20/ERC20.sol";

/// @notice Freely mintable 18-decimals token for tests and local demos.
contract MockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    /// @notice Mints `amount` to `to`.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Token that burns 1% of every transfer, to exercise the received-amount check of the escrow.
contract FeeOnTransferToken is ERC20 {
    constructor() ERC20("Fee on transfer", "FOT") {}

    /// @notice Mints `amount` to `to`.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = value / 100;
            super._update(from, address(0), fee);
            value -= fee;
        }
        super._update(from, to, value);
    }
}
