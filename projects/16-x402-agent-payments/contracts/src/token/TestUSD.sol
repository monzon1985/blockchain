// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {
    ERC20TransferAuthorization
} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20TransferAuthorization.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";
import {NoncesKeyed} from "@openzeppelin/contracts/utils/NoncesKeyed.sol";

/// @title TestUSD (LOCAL ONLY)
/// @author Project 16 - x402 agent payments
/// @notice A 6-decimal test dollar used exclusively on a local anvil chain. It has no value, no backing and no
///         issuer. The constructor refuses to deploy anywhere except chain id 31337.
/// @dev Implements EIP-2612 permits and EIP-3009 transfer/receive-with-authorization through OpenZeppelin's
///      `ERC20TransferAuthorization`, which interprets the 32-byte authorization nonce as a 192-bit key plus a
///      64-bit sequence (ERC-4337 semi-abstracted nonces). x402 payers therefore draw a fresh random 192-bit key
///      and use sequence 0. Key 0 is reserved: it aliases the ERC-2612 permit counter inherited from `Nonces`,
///      so an authorization on key 0 would silently consume (or be consumed by) a permit. This contract rejects it.
contract TestUSD is ERC20, ERC20Permit, ERC20TransferAuthorization, Ownable2Step {
    /// @notice The only chain id this token may be deployed on (anvil's default).
    uint256 public constant LOCAL_CHAIN_ID = 31_337;

    /// @notice Hard cap on total supply: 10^15 tUSD (10^21 base units). Keeps every amount inside `uint96`,
    ///         which is the width `SettlementLog` uses to pack receipts.
    uint256 public constant MAX_SUPPLY = 1e21;

    /// @notice Raised when the token is deployed on a chain other than {LOCAL_CHAIN_ID}.
    /// @param chainId The chain id the deployment was attempted on.
    error TestUSDNotLocalChain(uint256 chainId);

    /// @notice Raised when minting would push total supply above {MAX_SUPPLY}.
    /// @param requested The supply that would result from the mint.
    /// @param cap The supply cap.
    error TestUSDSupplyCapExceeded(uint256 requested, uint256 cap);

    /// @notice Raised when an EIP-3009 authorization uses nonce key 0, which is reserved for ERC-2612 permits.
    /// @param nonce The offending authorization nonce.
    error TestUSDReservedNonceKey(bytes32 nonce);

    /// @param initialOwner Account allowed to mint (the local deployer).
    constructor(address initialOwner)
        ERC20("TestUSD (local only)", "tUSD")
        ERC20Permit("TestUSD (local only)")
        Ownable(initialOwner)
    {
        require(block.chainid == LOCAL_CHAIN_ID, TestUSDNotLocalChain(block.chainid));
    }

    /// @notice Mints test dollars. Local faucet for the demo; owner only.
    /// @param to Recipient of the new tokens.
    /// @param amount Amount in base units (6 decimals).
    function mint(address to, uint256 amount) external onlyOwner {
        uint256 newSupply = totalSupply() + amount;
        require(newSupply <= MAX_SUPPLY, TestUSDSupplyCapExceeded(newSupply, MAX_SUPPLY));
        _mint(to, amount);
    }

    /// @notice Six decimals, matching the fiat-backed stablecoins x402 is usually priced in.
    /// @return The number of decimals (6).
    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @notice Returns the ERC-2612 permit nonce of `owner` (nonce key 0).
    /// @param owner The account whose permit nonce is queried.
    /// @return The next permit nonce.
    function nonces(address owner) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }

    /// @dev Rejects nonce key 0 before delegating to the keyed-sequential consumption of the parent.
    function _consumeNonce(address authorizer, bytes32 nonce) internal override {
        require(uint256(nonce) >> 64 != 0, TestUSDReservedNonceKey(nonce));
        super._consumeNonce(authorizer, nonce);
    }

    /// @dev Resolves the diamond between `Nonces` (permit) and `NoncesKeyed` (EIP-3009) in favour of the keyed
    ///      implementation, which itself falls back to `Nonces` for key 0.
    // slither-disable-next-line dead-code (reached through virtual dispatch from ERC20TransferAuthorization)
    function _useCheckedNonce(address owner, uint256 keyNonce) internal override(Nonces, NoncesKeyed) {
        super._useCheckedNonce(owner, keyNonce);
    }
}
