// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ERC20} from "@openzeppelin-contracts/token/ERC20/ERC20.sol";

/// @title TestToken
/// @notice Six-decimal ERC-20 with an open mint, used by the Foundry tests and by the Go
///         integration tests on anvil. Test-only: anyone can mint.
contract TestToken is ERC20 {
    /// @notice Creates the token with a name and symbol that make its test-only nature explicit.
    constructor() ERC20("Custody Test USD", "tUSD") {}

    /// @notice Six decimals, like the dollar stablecoins exchanges handle most.
    /// @return The number of decimals.
    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @notice Mints `amount` to `to`. Unrestricted on purpose: this contract only exists in tests.
    /// @param to The recipient.
    /// @param amount The amount to mint.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
