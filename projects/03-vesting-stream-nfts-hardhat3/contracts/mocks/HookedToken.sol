// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Receiver callback of {HookedToken}, in the spirit of ERC-777 `tokensReceived` / ERC-1363.
interface ITokenReceiver {
    function onTokenReceived(address from, uint256 amount) external;
}

/// @notice Test-only ERC-20 that notifies contract receivers with `onTokenReceived` after every transfer, handing
/// them control flow in the middle of the vesting contract's operations. Like an optional notification, a failing
/// callback does not fail the transfer (receivers that do not implement it, such as the vesting contract, are fine).
contract HookedToken is ERC20 {
    constructor() ERC20("Hooked Token", "HOOK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (from != address(0) && to.code.length != 0) {
            (bool ok,) = to.call(abi.encodeCall(ITokenReceiver.onTokenReceived, (from, value)));
            ok; // failures are deliberately ignored
        }
    }
}
