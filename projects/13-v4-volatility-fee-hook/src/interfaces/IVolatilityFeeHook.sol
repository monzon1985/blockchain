// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {ILiquidityModule} from "./ILiquidityModule.sol";

/// @title IVolatilityFeeHook
/// @notice Types, events, errors and external surface of the volatility-aware dynamic-fee hook.
interface IVolatilityFeeHook {
    /// @notice Immutable fee-curve parameters, shared by every pool that uses one hook deployment.
    /// @param alphaWad EWMA weight of the newest per-block sample, scaled by 1e18, in (0, 1e18].
    /// @param feeSlopePips LP fee added per tick of EWMA volatility, in pips (at most 10,000).
    /// @param surchargeSlopePips Top-of-block surcharge added per tick of EWMA volatility, in pips (at most 10,000).
    /// @param maxSurchargePips Cap on the surcharge rate, in pips (at most 10,000 = 1%).
    struct FeeConfig {
        uint64 alphaWad;
        uint24 feeSlopePips;
        uint24 surchargeSlopePips;
        uint24 maxSurchargePips;
    }

    /// @notice Per-pool state, packed in two storage slots (the first holds the low edge and the EWMA, the second
    /// everything a same-block swap reads: the high edge, the anchor, the fee and the surcharge rate).
    /// @dev The block's price range is maintained only while its surcharge rate is non-zero; in a quiet block it keeps
    /// the opening price.
    /// @param lowSqrtPriceX96 Lowest pool price reached in `anchorBlock` (the block's opening price until a swap moves
    /// below it). Only the part of a swap that moves the price below it is surcharged.
    /// @param ewmaWad EWMA of the absolute tick change per block, ticks scaled by 1e18 (at most 1,774,544e18 < 2^88).
    /// @param registered True once the pool has been initialized through this hook.
    /// @param highSqrtPriceX96 Highest pool price reached in `anchorBlock`. Only the part of a swap that moves the price
    /// above it is surcharged.
    /// @param anchorTick Tick at the start of the block's first swap; the next block's volatility sample is measured
    /// from it.
    /// @param anchorBlock Block in which the anchor and the price range were recorded.
    /// @param lpFeePips LP fee charged to every swap in `anchorBlock`, in pips (at most 10,000).
    /// @param surchargePips Surcharge rate for range-extending swaps in `anchorBlock`, in pips (at most 10,000).
    struct PoolState {
        uint160 lowSqrtPriceX96;
        uint88 ewmaWad;
        bool registered;
        uint160 highSqrtPriceX96;
        int24 anchorTick;
        uint40 anchorBlock;
        uint16 lpFeePips;
        uint16 surchargePips;
    }

    /// @notice One liquidity modification, as reported to the liquidity module.
    /// @param sender The router that called `PoolManager.modifyLiquidity` (not necessarily the LP).
    /// @param key The pool whose liquidity changed.
    /// @param params The modification; `params.liquidityDelta > 0` for additions and `< 0` for removals.
    /// @param delta The caller's delta for the modification: principal plus the fees it collected.
    /// @param feesAccrued The fees collected by this modification (already included in `delta`).
    struct LiquidityNotification {
        address sender;
        PoolKey key;
        ModifyLiquidityParams params;
        BalanceDelta delta;
        BalanceDelta feesAccrued;
    }

    /// @notice Emitted when a pool is initialized with this hook.
    /// @param poolId The pool.
    /// @param tick The initial tick, which anchors the first volatility sample.
    /// @param lpFeePips The initial LP fee (the 5 bps floor, since no volatility has been observed yet).
    event PoolRegistered(PoolId indexed poolId, int24 tick, uint24 lpFeePips);

    /// @notice Emitted by the first swap of each block, when the oracle folds the previous block into the EWMA.
    /// @param poolId The pool.
    /// @param anchorTick Tick at the start of this block's first swap (the previous block's closing tick).
    /// @param sampleTicks Absolute tick change over the previously sampled block.
    /// @param blocksElapsed Blocks since the previous sample.
    /// @param ewmaWad The updated EWMA, ticks scaled by 1e18.
    /// @param lpFeePips LP fee applied to every swap in this block.
    /// @param surchargePips Surcharge rate for range-extending swaps in this block.
    event VolatilityUpdated(
        PoolId indexed poolId,
        int24 anchorTick,
        uint256 sampleTicks,
        uint256 blocksElapsed,
        uint256 ewmaWad,
        uint24 lpFeePips,
        uint24 surchargePips
    );

    /// @notice Emitted when the owner adds a currency to, or removes it from, the pool-creation allowlist.
    /// @param currency The currency.
    /// @param allowed Whether new pools may use it.
    event CurrencyAllowlistUpdated(Currency indexed currency, bool allowed);

    /// @notice Emitted when the owner replaces the liquidity module.
    /// @param previousModule The module that was active until now (zero if none).
    /// @param newModule The module that liquidity changes are queued for from now on (zero disables the queue).
    event LiquidityModuleUpdated(ILiquidityModule indexed previousModule, ILiquidityModule indexed newModule);

    /// @notice Emitted when a liquidity modification is queued for the module. Carries everything a keeper needs to
    /// call `deliverNotification`.
    /// @param id Sequence number of the notification.
    /// @param module The module the notification is addressed to (the one active when the liquidity changed).
    /// @param notification The modification.
    event LiquidityNotificationQueued(
        uint256 indexed id, ILiquidityModule indexed module, LiquidityNotification notification
    );

    /// @notice Emitted when a queued notification has been handed to its module (successfully or not).
    /// @param id Sequence number of the notification; it can never be delivered again.
    /// @param module The module it was delivered to.
    /// @param success False if the module reverted or ran out of gas; its effects were reverted and the queue moved on.
    event LiquidityNotificationDelivered(uint256 indexed id, ILiquidityModule indexed module, bool success);

    /// @notice A pool was initialized with a static fee, so the hook's fee override would be silently ignored.
    /// @param fee The fee field of the rejected PoolKey.
    error DynamicFeeRequired(uint24 fee);

    /// @notice A pool was initialized with a currency the owner has not allowlisted.
    /// @param currency The rejected currency.
    error CurrencyNotAllowed(Currency currency);

    /// @notice The EWMA weight must be in (0, 1e18].
    /// @param alphaWad The rejected value.
    error InvalidAlpha(uint256 alphaWad);

    /// @notice A slope or cap exceeds its allowed maximum.
    /// @param value The rejected value, in pips.
    /// @param max The maximum allowed, in pips.
    error ParameterTooLarge(uint256 value, uint256 max);

    /// @notice `quoteFees` or `getPoolState` was asked about a pool this hook never initialized.
    /// @param poolId The unknown pool.
    error PoolNotRegistered(PoolId poolId);

    /// @notice `deliverNotification` was called while the PoolManager is unlocked. Modules only ever run outside an
    /// unlock, so they can never touch anyone's flash accounting.
    error PoolManagerUnlocked();

    /// @notice The notification does not match a pending entry: wrong data, already delivered, or never queued.
    /// @param id The rejected sequence number.
    error UnknownNotification(uint256 id);

    /// @notice The transaction does not carry enough gas to run the liquidity module with its full budget.
    /// @dev Reverting here, instead of starving the module, stops a keeper from forcing the module to fail on purpose
    /// (which would consume the notification). The notification stays pending, and a retry with more gas succeeds.
    /// @param available Gas left when the check ran.
    /// @param required Gas needed to give the module its full budget.
    error InsufficientGasForModule(uint256 available, uint256 required);

    /// @notice Allows or forbids a currency in pools created from now on. Existing pools are not affected.
    /// @param currency The currency.
    /// @param allowed Whether new pools may use it.
    function setCurrencyAllowed(Currency currency, bool allowed) external;

    /// @notice Replaces the module that liquidity modifications are queued for.
    /// @dev Takes effect for every pool of this hook. Notifications already queued stay addressed to the module that
    /// was active when they were queued.
    /// @param module The new module, or the zero address to stop queueing notifications.
    function setLiquidityModule(ILiquidityModule module) external;

    /// @notice Hands a queued notification to its module. Permissionless: anyone (the module itself, a keeper) may
    /// deliver, because the data is checked against the commitment stored when the liquidity changed.
    /// @dev Runs only while the PoolManager is locked, with a fixed gas budget, as a low-level call that copies no
    /// return data and whose failure is recorded instead of propagated. Each notification is delivered at most once.
    /// @param id Sequence number from `LiquidityNotificationQueued`.
    /// @param module The module the notification is addressed to, as emitted in `LiquidityNotificationQueued`.
    /// @param notification The notification exactly as emitted in `LiquidityNotificationQueued`.
    function deliverNotification(uint256 id, ILiquidityModule module, LiquidityNotification calldata notification)
        external;

    /// @notice Commitment of a pending notification: keccak256(abi.encode(module, notification)), or zero if the id
    /// was never queued or has been delivered.
    /// @param id Sequence number of the notification.
    /// @return digest The commitment.
    function pendingNotification(uint256 id) external view returns (bytes32 digest);

    /// @notice Number of notifications queued so far; the next one gets this id.
    /// @return The count.
    function notificationCount() external view returns (uint96);

    /// @notice Fees the next swap in `key` would pay if it were executed now in a new transaction.
    /// @dev If the current block has not seen a swap yet, the pending oracle update is simulated from the pool's
    /// current price, and the block's range collapses to that price. A swap is surcharged only for the part of its
    /// move that leaves [low, high], pro-rated as in `VolatilityMath.proRatedSurcharge`; a swap that starts on the
    /// boundary it moves away from (always the case for the first swap of a block) pays the rate on its whole amount.
    /// @param key The pool.
    /// @return lpFeePips LP fee in pips.
    /// @return surchargePips Surcharge rate in pips, charged on the unspecified amount of range-extending swaps.
    /// @return lowSqrtPriceX96 Lower boundary of the block's price range.
    /// @return highSqrtPriceX96 Upper boundary of the block's price range.
    function quoteFees(PoolKey calldata key)
        external
        view
        returns (uint24 lpFeePips, uint24 surchargePips, uint160 lowSqrtPriceX96, uint160 highSqrtPriceX96);

    /// @notice Stored state of a pool.
    /// @param poolId The pool.
    /// @return The pool's state.
    function getPoolState(PoolId poolId) external view returns (PoolState memory);
}
