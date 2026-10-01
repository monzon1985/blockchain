// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @title OZReference
/// @notice Unmodified OpenZeppelin Contracts 5.7 `ERC20Permit`, configured like the quartet. It is the
///         canonical oracle of the differential tests: the four implementations must agree with it.
/// @dev Test-only. It carries extra surface the quartet does not implement (ERC-5267 `eip712Domain()`,
///      storage-backed name and symbol), so it appears in the gas tables as context, not as a competitor.
contract OZReference is ERC20, ERC20Permit {
    /// @param holder Receiver of the initial supply.
    /// @param supply Total supply to mint.
    constructor(address holder, uint256 supply) ERC20("Gas Golf Quartet", "GOLF") ERC20Permit("Gas Golf Quartet") {
        _mint(holder, supply);
    }
}
