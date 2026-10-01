// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ILiquidityModule} from "../interfaces/ILiquidityModule.sol";

/// @title LiquidityTelemetry
/// @notice Reference liquidity module: keeps per-pool counters of the liquidity additions and removals that the hook
/// delivers from its notification queue. It holds no funds and has no admin; its only trusted input is the hook
/// address fixed at deployment.
/// @dev Counters are best-effort by design. Notifications arrive after the fact (whenever someone calls
/// `deliverNotification`), and a delivery that fails is recorded and skipped, so a reward system built on this
/// pattern must reconcile against PoolManager position state instead of trusting that every notification arrived.
contract LiquidityTelemetry is ILiquidityModule {
    /// @notice Aggregated liquidity activity of one pool.
    /// @param additions Number of liquidity additions observed.
    /// @param removals Number of liquidity removals observed.
    /// @param netLiquidity Sum of all observed liquidity deltas.
    struct PoolTelemetry {
        uint64 additions;
        uint64 removals;
        int128 netLiquidity;
    }

    /// @notice The only address allowed to deliver liquidity notifications.
    address public immutable hook;

    /// @notice Activity observed per pool.
    mapping(PoolId poolId => PoolTelemetry telemetry) public telemetry;

    /// @notice Emitted for every liquidity notification the hook delivers.
    /// @param poolId The pool whose liquidity changed.
    /// @param sender The router that modified liquidity.
    /// @param liquidityDelta The signed liquidity change.
    /// @param netLiquidity The pool's observed net liquidity after the change.
    event LiquidityRecorded(PoolId indexed poolId, address indexed sender, int256 liquidityDelta, int128 netLiquidity);

    /// @notice Only the hook may deliver notifications.
    /// @param caller The rejected caller.
    error NotHook(address caller);

    /// @notice The hook address must be set.
    error ZeroHook();

    /// @param hook_ The hook whose notifications this module accepts.
    constructor(address hook_) {
        if (hook_ == address(0)) revert ZeroHook();
        hook = hook_;
    }

    /// @inheritdoc ILiquidityModule
    function onLiquidityModified(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta
    ) external {
        if (msg.sender != hook) revert NotHook(msg.sender);
        PoolId poolId = key.toId();
        PoolTelemetry storage t = telemetry[poolId];
        if (params.liquidityDelta > 0) {
            ++t.additions;
        } else {
            ++t.removals;
        }
        // Checked cast and checked addition: an out-of-range value reverts, and the hook records a failed delivery.
        t.netLiquidity += SafeCast.toInt128(params.liquidityDelta);
        emit LiquidityRecorded(poolId, sender, params.liquidityDelta, t.netLiquidity);
    }
}
