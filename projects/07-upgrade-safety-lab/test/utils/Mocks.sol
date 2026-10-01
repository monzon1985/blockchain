// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Plain ERC-20 with open minting, used as the payment token in tests.
contract MockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice ERC-20 that calls back into a target during `transferFrom`, like an ERC-777 style hook. Used to prove
///         that the reentrancy guard of `subscribe` holds in both architectures.
contract ReentrantERC20 is ERC20 {
    address public target;
    bytes public payload;
    bool public reentered;
    bytes public reentryError;

    constructor() ERC20("Reentrant", "REENT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(address target_, bytes calldata payload_) external {
        target = target_;
        payload = payload_;
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        if (target != address(0)) {
            address t = target;
            target = address(0);
            (bool ok, bytes memory err) = t.call(payload);
            reentered = ok;
            reentryError = err;
        }
        return super.transferFrom(from, to, value);
    }
}
