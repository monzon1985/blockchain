// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Test asset with configurable decimals and unrestricted mint/burn (the a16z suite needs both).
contract MockERC20 is ERC20 {
    uint8 private immutable _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

/// @notice Fee-on-transfer variant: every transfer (not mint or burn) burns `feeBps` of the amount. The fee can be
///         switched on after deployment, like USDT's dormant fee switch.
contract MockFeeOnTransferERC20 is MockERC20 {
    uint256 public feeBps;

    constructor(string memory name_, string memory symbol_, uint8 decimals_, uint256 feeBps_)
        MockERC20(name_, symbol_, decimals_)
    {
        feeBps = feeBps_;
    }

    function setFeeBps(uint256 feeBps_) external {
        feeBps = feeBps_;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0) || feeBps == 0) {
            super._update(from, to, value);
            return;
        }
        uint256 fee = value * feeBps / 10_000;
        super._update(from, address(0), fee);
        super._update(from, to, value - fee);
    }
}
