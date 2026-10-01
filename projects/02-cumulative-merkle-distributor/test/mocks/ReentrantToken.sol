// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Hostile ERC-20 that calls back into `target` during every transfer (a stand-in for ERC-777-style hooks).
contract ReentrantToken is ERC20 {
    address public target;
    bytes public payload;
    bool public reentered;
    bytes public reentryError;

    constructor() ERC20("Reentrant", "REE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(address target_, bytes calldata payload_) external {
        target = target_;
        payload = payload_;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (target != address(0) && from == target) {
            address t = target;
            target = address(0);
            (bool ok, bytes memory ret) = t.call(payload);
            reentered = ok;
            reentryError = ret;
        }
    }
}
