// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

/// @notice Plain OpenZeppelin ERC-4626 vault with a configurable decimals offset. Used to isolate the effect of the
///         virtual-share offset in the donation-attack ablation and as the gas baseline.
contract OzVault is ERC4626 {
    uint8 private immutable _offset;

    constructor(IERC20 asset_, uint8 offset_) ERC4626(asset_) ERC20("OZ Vault", "ozV") {
        _offset = offset_;
    }

    function _decimalsOffset() internal view override returns (uint8) {
        return _offset;
    }
}
