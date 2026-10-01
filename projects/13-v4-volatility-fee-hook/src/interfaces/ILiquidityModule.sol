// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @title ILiquidityModule
/// @notice Optional, non-essential extension (rewards, points, telemetry) that learns about every liquidity
/// modification in the hook's pools.
/// @dev The hook never calls the module while a liquidity operation is in progress. `afterAddLiquidity` and
/// `afterRemoveLiquidity` only store a commitment to the notification and emit it; the module receives it later,
/// in a separate call to `deliverNotification` that runs while the PoolManager is locked, with a fixed gas budget,
/// and whose failure is recorded instead of propagated. A module can therefore never block, tax or grief a liquidity
/// operation, but it receives notifications late and must tolerate failed deliveries, for example by reconciling
/// lazily from PoolManager position state.
interface ILiquidityModule {
    /// @notice Called by the hook when a queued liquidity notification is delivered.
    /// @param sender The router that called `PoolManager.modifyLiquidity` (not necessarily the LP).
    /// @param key The pool whose liquidity changed.
    /// @param params The modification; `params.liquidityDelta > 0` for additions and `< 0` for removals.
    /// @param delta The caller's delta for the modification: principal plus the fees it collected.
    /// @param feesAccrued The fees collected by this modification (already included in `delta`).
    function onLiquidityModified(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued
    ) external;
}
