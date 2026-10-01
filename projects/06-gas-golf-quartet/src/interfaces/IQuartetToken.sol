// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

/// @title IQuartetToken
/// @notice The exact external surface shared by the four Gas Golf Quartet implementations:
///         ERC-20 (with metadata) plus EIP-2612 `permit`, `nonces` and `DOMAIN_SEPARATOR`.
/// @dev Semantics are pinned to OpenZeppelin Contracts 5.7 `ERC20Permit` (check order, zero-address
///      rules, infinite-allowance handling, ECDSA malleability rule). Every implementation must be
///      observationally equivalent on this surface: same return data, same revert class, same logs
///      and the same resulting balances, allowances, nonces and supply. Revert *encodings* may differ;
///      `test/utils/RevertClassifier.sol` maps each encoding to one class.
interface IQuartetToken is IERC20Metadata, IERC20Permit {}

/// @title IQuartetGolfErrors
/// @notice Selector-only custom errors used by the inline-assembly and Yul implementations.
/// @dev Deliberate trade-off (docs/TRICKS.md, "selector-only errors"): a 4-byte revert costs less
///      bytecode than an ERC-6093 error that carries values. The idiomatic Solidity implementation keeps
///      the ERC-6093 errors so integrators that decode revert arguments have a reference to use.
interface IQuartetGolfErrors {
    /// @notice The sender's balance is lower than the amount being moved.
    error InsufficientBalance();
    /// @notice The spender's allowance is lower than the amount being moved.
    error InsufficientAllowance();
    /// @notice Tokens cannot be moved out of the zero address.
    error InvalidSender();
    /// @notice Tokens cannot be sent to the zero address.
    error InvalidReceiver();
    /// @notice The zero address cannot own an allowance.
    error InvalidApprover();
    /// @notice The zero address cannot be approved as a spender.
    error InvalidSpender();
    /// @notice `block.timestamp` is past the permit deadline.
    error PermitExpired();
    /// @notice The permit signature is malleable (high `s`), unrecoverable, or not signed by `owner`.
    error InvalidPermit();
}
