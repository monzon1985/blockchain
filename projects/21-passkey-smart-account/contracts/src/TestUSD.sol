// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @title TestUSD
/// @author Passkey Smart Account contributors
/// @notice A 6-decimal test stablecoin used to pay gas through {TokenPaymaster} on local chains.
/// @dev Technical demo token with no value and no peg. The owner is the local faucet.
contract TestUSD is ERC20, ERC20Permit, Ownable2Step {
    /// @notice Creates the token and hands minting rights to `owner_`.
    /// @param owner_ The faucet / minter.
    constructor(address owner_) ERC20("Test USD", "TUSD") ERC20Permit("Test USD") Ownable(owner_) {}

    /// @notice Mints test tokens.
    /// @param to Recipient.
    /// @param amount Amount in 6-decimal units.
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    /// @notice Token decimals.
    /// @return Always 6, like the stablecoins it imitates.
    function decimals() public pure override returns (uint8) {
        return 6;
    }
}
