// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ERC3009} from "@openzeppelin/contracts/token/ERC20/extensions/draft-ERC3009.sol";

/// @notice Gas baseline: a bare OpenZeppelin ERC-20 with no issuer controls, not behind a proxy.
contract PlainERC20 is ERC20 {
    constructor() ERC20("Plain", "PLN") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Gas baseline: a bare OpenZeppelin ERC-3009 token with no issuer controls, not behind a proxy.
contract PlainERC3009 is ERC20, EIP712, ERC3009 {
    constructor() ERC20("Plain", "PLN") EIP712("Plain", "1") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
