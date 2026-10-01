// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import {IERC7943Fungible} from "./IERC7943Fungible.sol";

/// @title IFundShareToken
/// @notice Surface of the permissioned fund share used by the vault and the dividend distributor.
interface IFundShareToken is IERC20, IERC7943Fungible {
    /// @notice Issues `amount` shares to `to` through the compliance path. Vault only.
    /// @param to Receiver.
    /// @param amount Shares.
    function mint(address to, uint256 amount) external;

    /// @notice Burns `amount` shares of `owner` for a redemption request. Vault only.
    /// @param owner Share owner.
    /// @param spender Account whose ERC-20 allowance is spent, or zero when the caller is owner/operator.
    /// @param amount Shares.
    function burnForRedemption(address owner, address spender, uint256 amount) external;

    /// @notice Wallet that currently represents `account`, following executed recoveries.
    /// @param account Original wallet.
    /// @return wallet `account` itself if never recovered, else the latest successor.
    function currentWalletOf(address account) external view returns (address wallet);

    /// @notice Pending lost-wallet recovery of `lost` (all zero if none).
    /// @param lost Wallet being recovered.
    /// @return successor Scheduled successor wallet.
    /// @return eta Earliest execution time.
    /// @return caseRef Off-chain case reference.
    function pendingRecovery(address lost) external view returns (address successor, uint64 eta, bytes32 caseRef);

    /// @notice Whether issuing `amount` new shares to `to` would currently pass eligibility and every compliance
    ///         module (holder caps, investor cap, ...). Never reverts.
    /// @param to Recipient of the new shares.
    /// @param amount Shares.
    /// @return allowed True if a mint would be accepted now.
    function canMint(address to, uint256 amount) external view returns (bool allowed);
}
