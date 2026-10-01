// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title DemoToken
/// @notice Plain 18-decimal ERC-20 deployed by the Ignition demo module. Not part of the protocol.
contract DemoToken is ERC20, Ownable {
    /// @param initialOwner Account allowed to mint; receives the initial supply.
    /// @param initialSupply Tokens minted to `initialOwner` at deployment.
    constructor(address initialOwner, uint256 initialSupply) ERC20("Demo Token", "DEMO") Ownable(initialOwner) {
        _mint(initialOwner, initialSupply);
    }

    /// @notice Mints `amount` tokens to `to`.
    /// @param to Receiver.
    /// @param amount Tokens to mint.
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }
}
