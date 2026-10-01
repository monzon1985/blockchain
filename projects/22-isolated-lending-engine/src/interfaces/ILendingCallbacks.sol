// SPDX-License-Identifier: GPL-2.0-or-later
// Adapted from Morpho Blue by Morpho Labs, https://github.com/morpho-org/morpho-blue (GPL-2.0-or-later),
// src/interfaces/IMorphoCallbacks.sol: the callback shapes follow the original (renamed); the NatSpec is new. Modified
// for this project in 2026; see the README's License section.
pragma solidity 0.8.37;

/// @title ILendingCallbacks
/// @notice Callbacks the engine invokes on `msg.sender` when a non-empty `data` payload is passed.
/// @dev Every callback except `onFlashLoan` runs while the target market is locked: any call that touches the same
///      market reverts with `MarketLocked`. Other markets remain usable, which is what lets a callback compose
///      positions across markets. The engine pulls the owed tokens with `transferFrom` after the callback returns.
interface ISupplyCallback {
    /// @notice Called after the supply position is credited and before the loan token is pulled.
    /// @param assets Amount of loan token the engine will pull from the caller.
    /// @param data Arbitrary payload forwarded from `supply`.
    function onSupply(uint256 assets, bytes calldata data) external;
}

/// @notice Callback for `repay`.
interface IRepayCallback {
    /// @notice Called after the debt is reduced and before the loan token is pulled.
    /// @param assets Amount of loan token the engine will pull from the caller.
    /// @param data Arbitrary payload forwarded from `repay`.
    function onRepay(uint256 assets, bytes calldata data) external;
}

/// @notice Callback for `supplyCollateral`.
interface ISupplyCollateralCallback {
    /// @notice Called after the collateral is credited and before the collateral token is pulled.
    /// @param assets Amount of collateral token the engine will pull from the caller.
    /// @param data Arbitrary payload forwarded from `supplyCollateral`.
    function onSupplyCollateral(uint256 assets, bytes calldata data) external;
}

/// @notice Callback for `liquidate`.
interface ILiquidateCallback {
    /// @notice Called after the seized collateral is sent and before the repaid loan token is pulled.
    /// @param repaidAssets Amount of loan token the engine will pull from the liquidator.
    /// @param data Arbitrary payload forwarded from `liquidate`.
    function onLiquidate(uint256 repaidAssets, bytes calldata data) external;
}

/// @notice Callback for `flashLoan`.
interface IFlashLoanCallback {
    /// @notice Called after the borrowed tokens are sent; the engine pulls `assets` back when it returns.
    /// @param assets Amount lent (and to be returned, fee-free).
    /// @param data Arbitrary payload forwarded from `flashLoan`.
    function onFlashLoan(uint256 assets, bytes calldata data) external;
}
