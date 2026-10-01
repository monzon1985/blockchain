// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import { ERC20Votes } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import { ERC20FlashMint } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20FlashMint.sol";
import { Nonces } from "@openzeppelin/contracts/utils/Nonces.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/// @title GovToken
/// @notice Governance token for the Kestrel protocol: an ERC-20 with EIP-2612 permits,
///         checkpointed voting power (ERC-5805, block-number clock) and ERC-3156 flash
///         minting.
/// @dev    Flash loans are fee-free (OpenZeppelin default). Voting power must be delegated
///         (self-delegation included) before it is checkpointed.
contract GovToken is ERC20, ERC20Permit, ERC20Votes, ERC20FlashMint, Ownable {
    /// @notice Deploy the token and mint the genesis supply to `recipient`.
    /// @param recipient Account that receives the initial mint.
    /// @param initialSupply Genesis amount, in wei-denominated token units.
    constructor(address recipient, uint256 initialSupply)
        ERC20("Kestrel Governance", "kGOV")
        ERC20Permit("Kestrel Governance")
        Ownable(msg.sender)
    {
        _mint(recipient, initialSupply);
    }

    /// @notice Mint new governance tokens.
    /// @dev Owner-gated; used only to seed test fixtures and demos.
    /// @param to Recipient of the freshly minted tokens.
    /// @param amount Amount to mint, in wei-denominated token units.
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    /// @inheritdoc ERC20Votes
    /// @dev Resolves the diamond between {ERC20} and {ERC20Votes}.
    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        super._update(from, to, value);
    }

    /// @inheritdoc ERC20Permit
    /// @dev Resolves the diamond between {ERC20Permit} and {Nonces}.
    function nonces(address owner) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }
}
