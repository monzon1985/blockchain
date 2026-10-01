// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC165} from "@openzeppelin-contracts/utils/introspection/IERC165.sol";

/// @title IERC7943Fungible
/// @notice ERC-7943 ("uRWA") enforcement surface for ERC-20 based real-world-asset tokens.
/// @dev ABI-identical to the fungible interface of the ERC-7943 specification, so
///      `type(IERC7943Fungible).interfaceId == 0x3edbb4c4`. Earlier drafts of the ERC exposed a single
///      `canTransact(account)` predicate; the current text splits it into `canSend` and `canReceive`.
interface IERC7943Fungible is IERC165 {
    /// @notice Emitted when `amount` tokens are moved from `from` to `to` by an authorized enforcement action.
    /// @param from Account the tokens were taken from.
    /// @param to Account that received the tokens.
    /// @param amount Amount moved.
    event ForcedTransfer(address indexed from, address indexed to, uint256 amount);

    /// @notice Emitted whenever the absolute frozen amount of `account` changes.
    /// @param account Account whose frozen amount changed.
    /// @param amount New absolute frozen amount (may exceed the balance).
    event Frozen(address indexed account, uint256 amount);

    /// @notice `account` is not currently allowed to send tokens.
    /// @param account The rejected sender.
    error ERC7943CannotSend(address account);

    /// @notice `account` is not currently allowed to receive tokens.
    /// @param account The rejected recipient.
    error ERC7943CannotReceive(address account);

    /// @notice The transfer is rejected by a transfer-level rule.
    /// @param from Sender.
    /// @param to Recipient.
    /// @param amount Amount requested.
    error ERC7943CannotTransfer(address from, address to, uint256 amount);

    /// @notice `amount` fits in the balance of `account` but exceeds its unfrozen part.
    /// @param account Holder.
    /// @param amount Amount requested.
    /// @param unfrozen Balance that is not frozen.
    error ERC7943InsufficientUnfrozenBalance(address account, uint256 amount, uint256 unfrozen);

    /// @notice Moves `amount` from `from` to `to` as an authorized enforcement action.
    /// @param from Account the tokens are taken from.
    /// @param to Account that receives the tokens.
    /// @param amount Amount to move.
    /// @return result True on success; reverts otherwise.
    function forcedTransfer(address from, address to, uint256 amount) external returns (bool result);

    /// @notice Overwrites the absolute frozen amount of `account`.
    /// @param account Account whose tokens are frozen.
    /// @param amount New frozen amount; may exceed the current balance.
    /// @return result True on success; reverts otherwise.
    function setFrozenTokens(address account, uint256 amount) external returns (bool result);

    /// @notice Whether `account` may currently send tokens (account-level eligibility only).
    /// @param account Account to check.
    /// @return allowed True if the account may send.
    function canSend(address account) external view returns (bool allowed);

    /// @notice Whether `account` may currently receive tokens (account-level eligibility only).
    /// @param account Account to check.
    /// @return allowed True if the account may receive.
    function canReceive(address account) external view returns (bool allowed);

    /// @notice Absolute frozen amount of `account`; may exceed its balance.
    /// @param account Account to query.
    /// @return amount Frozen amount.
    function getFrozenTokens(address account) external view returns (uint256 amount);

    /// @notice Whether a transfer of `amount` from `from` to `to` would currently be permitted.
    /// @dev Never reverts. Does not fail on plain balance or allowance grounds, only on permission rules.
    /// @param from Sender.
    /// @param to Recipient.
    /// @param amount Amount.
    /// @return allowed True if permitted.
    function canTransfer(address from, address to, uint256 amount) external view returns (bool allowed);
}
