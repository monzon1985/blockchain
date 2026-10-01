// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IHookEvents} from "@openzeppelin/uniswap-hooks/interfaces/IHookEvents.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SlotDerivation} from "@openzeppelin/contracts/utils/SlotDerivation.sol";
import {TransientSlot} from "@openzeppelin/contracts/utils/TransientSlot.sol";

import {IVolatilityFeeHook} from "./interfaces/IVolatilityFeeHook.sol";
import {ILiquidityModule} from "./interfaces/ILiquidityModule.sol";
import {VolatilityMath} from "./libraries/VolatilityMath.sol";

/// @title VolatilityFeeHook
/// @notice Uniswap v4 hook that prices swaps by realized volatility and recaptures part of the arbitrage value that
/// top-of-block trades extract from LPs.
///
/// 1. Dynamic LP fee. The first swap of every block folds the previous block's absolute tick change into a per-pool
///    EWMA; every swap in that block is charged 5 bps + slope * EWMA, clamped to [5 bps, 100 bps], via
///    `OVERRIDE_FEE_FLAG`. No external oracle is used, and the fee cannot change within a block.
/// 2. Top-of-block surcharge. Each block keeps the range of prices its swaps have reached. A swap that pushes the
///    price beyond that range pays an extra volatility-scaled surcharge on the part of its unspecified amount that
///    corresponds to the new ground (the whole amount for the block's first swap). The hook takes it as an
///    `afterSwapReturnDelta` and donates all of it to the in-range LPs in the same callback, so it never holds funds.
/// 3. Non-essential logic stays off the critical path. Liquidity changes are only committed to a queue; the optional
///    module (rewards, telemetry) receives them later through `deliverNotification`, which runs while the
///    PoolManager is locked. No module code ever runs inside a swap, an addition or an exit.
///
/// @dev Pools must use `LPFeeLibrary.DYNAMIC_FEE_FLAG` and owner-allowlisted currencies. See the README for the
/// threat model, the rounding-direction table and the invariants.
contract VolatilityFeeHook is BaseHook, Ownable2Step, IHookEvents, IVolatilityFeeHook {
    using StateLibrary for IPoolManager;
    using LPFeeLibrary for uint24;
    using SafeCast for uint256;
    using SafeCast for int256;
    using SlotDerivation for bytes32;
    using TransientSlot for bytes32;
    using TransientSlot for TransientSlot.Uint256Slot;

    /// @notice Lower clamp of the dynamic LP fee: 5 bps.
    uint24 public constant MIN_FEE_PIPS = VolatilityMath.MIN_FEE_PIPS;

    /// @notice Upper clamp of the dynamic LP fee: 100 bps.
    uint24 public constant MAX_FEE_PIPS = VolatilityMath.MAX_FEE_PIPS;

    /// @notice Largest configurable surcharge rate: 1%.
    uint24 public constant MAX_SURCHARGE_CAP_PIPS = 10_000;

    /// @notice Gas forwarded to the liquidity module for each delivered notification.
    uint256 public constant MODULE_GAS_LIMIT = 100_000;

    /// @notice Gas a delivery must still hold, beyond the module's budget, for the call itself and the final event.
    uint256 public constant MODULE_CALL_RESERVE = 15_000;

    /// @dev PoolManager transient slot holding its lock flag. Copied from v4-core's Lock library (BUSL-1.1, so not
    /// imported into this MIT contract); the unit suite asserts it matches the original.
    bytes32 internal constant PM_IS_UNLOCKED_SLOT = 0xc090fc4683624cfc3884e9d8de5eca132f2d0ec062aff75d43c0465d5ceeab23;

    /// @dev Transient slot namespace for the per-pool pre-swap price, derived ERC-7201 style:
    /// keccak256(abi.encode(uint256(keccak256("volatility-fee-hook.transient.pre-swap-price")) - 1)) & ~bytes32(0xff).
    bytes32 private constant PRE_SWAP_PRICE_SLOT = 0x878f53a242355742de3ed8de9af479fd10062a388ce88ba52470cea775977600;

    /// @notice EWMA weight of the newest per-block sample, scaled by 1e18.
    uint256 public immutable alphaWad;

    /// @notice LP fee added per tick of EWMA volatility, in pips.
    uint256 public immutable feeSlopePips;

    /// @notice Surcharge rate added per tick of EWMA volatility, in pips.
    uint256 public immutable surchargeSlopePips;

    /// @notice Cap on the surcharge rate, in pips.
    uint256 public immutable maxSurchargePips;

    /// @notice Whether new pools may use a currency. Keeps fee-on-transfer, rebasing and malicious tokens out.
    mapping(Currency currency => bool allowed) public isCurrencyAllowed;

    /// @notice Module that liquidity modifications are queued for (zero address: no queue).
    ILiquidityModule public liquidityModule;

    /// @inheritdoc IVolatilityFeeHook
    /// @dev Packed with `liquidityModule`, which every queueing operation reads anyway.
    uint96 public notificationCount;

    /// @dev Oracle, fee and price-range state, keyed by pool.
    mapping(PoolId poolId => PoolState state) private _pools;

    /// @inheritdoc IVolatilityFeeHook
    mapping(uint256 id => bytes32 digest) public pendingNotification;

    /// @param manager The Uniswap v4 PoolManager.
    /// @param initialOwner Account allowed to manage the currency allowlist and the liquidity module.
    /// @param config Fee-curve parameters; immutable for the lifetime of the deployment.
    constructor(IPoolManager manager, address initialOwner, FeeConfig memory config)
        BaseHook(manager)
        Ownable(initialOwner)
    {
        // solc 0.8.26 only supports require(bool, CustomError) under via-IR, so errors are raised with if/revert.
        if (config.alphaWad == 0 || config.alphaWad > VolatilityMath.WAD) revert InvalidAlpha(config.alphaWad);
        if (config.feeSlopePips > MAX_FEE_PIPS) revert ParameterTooLarge(config.feeSlopePips, MAX_FEE_PIPS);
        if (config.surchargeSlopePips > MAX_SURCHARGE_CAP_PIPS) {
            revert ParameterTooLarge(config.surchargeSlopePips, MAX_SURCHARGE_CAP_PIPS);
        }
        if (config.maxSurchargePips > MAX_SURCHARGE_CAP_PIPS) {
            revert ParameterTooLarge(config.maxSurchargePips, MAX_SURCHARGE_CAP_PIPS);
        }
        alphaWad = config.alphaWad;
        feeSlopePips = config.feeSlopePips;
        surchargeSlopePips = config.surchargeSlopePips;
        maxSurchargePips = config.maxSurchargePips;
    }

    /// @notice Callbacks this hook implements. The deployment address must encode exactly these bits.
    /// @return permissions beforeInitialize, afterAddLiquidity, afterRemoveLiquidity, beforeSwap, afterSwap and
    /// afterSwapReturnDelta; nothing else.
    function getHookPermissions() public pure virtual override returns (Hooks.Permissions memory permissions) {
        permissions = Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: true,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Admin
    // ---------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IVolatilityFeeHook
    function setCurrencyAllowed(Currency currency, bool allowed) external onlyOwner {
        isCurrencyAllowed[currency] = allowed;
        emit CurrencyAllowlistUpdated(currency, allowed);
    }

    /// @inheritdoc IVolatilityFeeHook
    function setLiquidityModule(ILiquidityModule module) external onlyOwner {
        emit LiquidityModuleUpdated(liquidityModule, module);
        liquidityModule = module;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Liquidity-module delivery (outside any unlock)
    // ---------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IVolatilityFeeHook
    function deliverNotification(uint256 id, ILiquidityModule module, LiquidityNotification calldata notification)
        external
    {
        // A module must never run inside somebody's unlock: there it could leave a delta open, or settle a debt of
        // another party to keep the PoolManager's global delta count unchanged, and revert that party's transaction.
        if (poolManager.exttload(PM_IS_UNLOCKED_SLOT) != bytes32(0)) revert PoolManagerUnlocked();
        if (pendingNotification[id] != _notificationDigest(module, notification)) revert UnknownNotification(id);
        delete pendingNotification[id];

        bytes memory payload = abi.encodeCall(
            ILiquidityModule.onLiquidityModified,
            (notification.sender, notification.key, notification.params, notification.delta, notification.feesAccrued)
        );
        // EIP-150 forwards at most 63/64 of the remaining gas. Require enough for the module's full budget, so that a
        // failed delivery is always the module's own fault and never a keeper under-funding the call on purpose.
        uint256 required = (MODULE_GAS_LIMIT * 64) / 63 + MODULE_CALL_RESERVE;
        uint256 available = gasleft();
        if (available < required) revert InsufficientGasForModule(available, required);

        bool success;
        // Low-level call with a fixed gas budget and zero-length output: no return data is copied (a module cannot
        // make the caller pay for a return bomb), and no extcodesize check or ABI decoding can revert here. The call
        // reads the payload from memory and writes nothing back, so the block is memory-safe.
        // slither-disable-next-line assembly
        assembly ("memory-safe") {
            success := call(MODULE_GAS_LIMIT, module, 0, add(payload, 0x20), mload(payload), 0, 0)
        }
        // The event reports the outcome of the call it follows. The notification was consumed before the call, and no
        // state is written after it, so a re-entrant module can neither replay it nor observe a half-updated hook.
        // slither-disable-start reentrancy-events
        // forge-lint: disable-next-line(reentrancy-events)
        emit LiquidityNotificationDelivered(id, module, success);
        // slither-disable-end reentrancy-events
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IVolatilityFeeHook
    function quoteFees(PoolKey calldata key)
        external
        view
        returns (uint24 lpFeePips, uint24 surchargePips, uint160 lowSqrtPriceX96, uint160 highSqrtPriceX96)
    {
        PoolId poolId = key.toId();
        PoolState memory state = _pools[poolId];
        if (!state.registered) revert PoolNotRegistered(poolId);
        if (block.number > state.anchorBlock) {
            // protocolFee and lpFee are not needed: the pool's stored lpFee is unused for override-fee pools.
            // slither-disable-next-line unused-return
            (uint160 sqrtPriceX96, int24 tick,,) = poolManager.getSlot0(poolId);
            uint256 ewma = VolatilityMath.updateEwma(
                state.ewmaWad,
                VolatilityMath.absTickDelta(tick, state.anchorTick),
                block.number - state.anchorBlock,
                alphaWad
            );
            return (
                VolatilityMath.lpFee(ewma, feeSlopePips),
                VolatilityMath.surchargeRate(ewma, surchargeSlopePips, maxSurchargePips),
                sqrtPriceX96,
                sqrtPriceX96
            );
        }
        return (state.lpFeePips, state.surchargePips, state.lowSqrtPriceX96, state.highSqrtPriceX96);
    }

    /// @inheritdoc IVolatilityFeeHook
    function getPoolState(PoolId poolId) external view returns (PoolState memory state) {
        state = _pools[poolId];
        if (!state.registered) revert PoolNotRegistered(poolId);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Hook callbacks (reachable only through the PoolManager; see BaseHook.onlyPoolManager)
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Gatekeeper for permissionless pool creation: rejects static-fee keys (the override would be ignored and
    /// swaps would pay the key's static fee) and currencies the owner has not vetted. State is keyed by PoolId, so a
    /// hostile pool that passes these checks still cannot touch any other pool's oracle.
    function _beforeInitialize(address, PoolKey calldata key, uint160 sqrtPriceX96) internal override returns (bytes4) {
        if (!key.fee.isDynamicFee()) revert DynamicFeeRequired(key.fee);
        if (!isCurrencyAllowed[key.currency0]) revert CurrencyNotAllowed(key.currency0);
        if (!isCurrencyAllowed[key.currency1]) revert CurrencyNotAllowed(key.currency1);

        PoolId poolId = key.toId();
        int24 tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        _pools[poolId] = PoolState({
            lowSqrtPriceX96: sqrtPriceX96,
            ewmaWad: 0,
            registered: true,
            highSqrtPriceX96: sqrtPriceX96,
            anchorTick: tick,
            anchorBlock: block.number.toUint40(),
            lpFeePips: uint256(MIN_FEE_PIPS).toUint16(),
            surchargePips: 0
        });
        // No external call precedes this event (TickMath and SafeCast are internal libraries).
        // forge-lint: disable-next-line(reentrancy-events)
        emit PoolRegistered(poolId, tick, MIN_FEE_PIPS);
        return this.beforeInitialize.selector;
    }

    /// @dev Runs on the pre-swap state: the pool price here is the block's opening price on the first swap of a block,
    /// which is exactly what the volatility sample and the block's price range need.
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        PoolState storage state = _pools[poolId];
        uint24 fee;
        // The pre-swap price is handed to afterSwap of this same swap through a transient slot keyed by PoolId (so
        // interleaved swaps across pools cannot mix values). A quiet block (zero surcharge rate) needs neither.
        if (block.number > state.anchorBlock) {
            // slither-disable-next-line unused-return
            (uint160 sqrtPriceX96, int24 tick,,) = poolManager.getSlot0(poolId);
            uint24 surchargePips;
            (fee, surchargePips) = _openBlock(poolId, state, sqrtPriceX96, tick);
            if (surchargePips != 0) _preSwapPriceSlot(poolId).tstore(sqrtPriceX96);
        } else {
            fee = state.lpFeePips;
            if (state.surchargePips != 0) {
                // slither-disable-next-line unused-return
                (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
                _preSwapPriceSlot(poolId).tstore(sqrtPriceX96);
            }
        }

        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    /// @dev Runs on the post-swap state: the surcharge is sized from the realized swap delta, and the donation lands on
    /// the liquidity that is in range after the swap.
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        PoolId poolId = key.toId();
        // The unspecified side is the output of an exact-input swap and the input of an exact-output swap.
        bool unspecifiedIsCurrency1 = (params.amountSpecified < 0) == params.zeroForOne;
        uint256 surcharge = _extendRangeAndPrice(
            poolId, _abs(unspecifiedIsCurrency1 ? delta.amount1() : delta.amount0()), unspecifiedIsCurrency1
        );

        // A donation needs in-range liquidity; if the swap left none, skip the surcharge rather than revert the swap.
        if (surcharge == 0 || poolManager.getLiquidity(poolId) == 0) return (this.afterSwap.selector, 0);

        _donateSurcharge(sender, key, poolId, unspecifiedIsCurrency1, surcharge);
        return (this.afterSwap.selector, surcharge.toInt256().toInt128());
    }

    /// @dev Queues a notification for the module; makes no external call and never changes balances.
    function _afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        _queueNotification(sender, key, params, delta, feesAccrued);
        return (this.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /// @dev Queues a notification for the module; makes no external call and never changes balances, so no module
    /// can block, tax or grief an exit.
    function _afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        _queueNotification(sender, key, params, delta, feesAccrued);
        return (this.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev First swap of a new block: sample the tick move of the previously anchored block, update the EWMA, derive
    /// the fee and surcharge rate for this block, and re-anchor (tick and price range) at the current pre-swap price.
    function _openBlock(PoolId poolId, PoolState storage state, uint160 sqrtPriceX96, int24 tick)
        private
        returns (uint24 fee, uint24 surchargePips)
    {
        uint256 sample = VolatilityMath.absTickDelta(tick, state.anchorTick);
        uint256 blocksElapsed = block.number - state.anchorBlock;
        uint256 ewma = VolatilityMath.updateEwma(state.ewmaWad, sample, blocksElapsed, alphaWad);
        fee = VolatilityMath.lpFee(ewma, feeSlopePips);
        surchargePips = VolatilityMath.surchargeRate(ewma, surchargeSlopePips, maxSurchargePips);

        // Both slots are rewritten field by field; the EWMA fits 88 bits and the fee and rate 16 bits (proven bounds,
        // still checked by SafeCast).
        state.lowSqrtPriceX96 = sqrtPriceX96;
        state.ewmaWad = ewma.toUint88();
        state.highSqrtPriceX96 = sqrtPriceX96;
        state.anchorTick = tick;
        state.anchorBlock = block.number.toUint40();
        state.lpFeePips = uint256(fee).toUint16();
        state.surchargePips = uint256(surchargePips).toUint16();

        // The only external call before this event is the read-only getSlot0 (a STATICCALL to the PoolManager).
        // forge-lint: disable-next-line(reentrancy-events)
        emit VolatilityUpdated(poolId, tick, sample, blocksElapsed, ewma, fee, surchargePips);
    }

    /// @dev Extends the block's price range to the post-swap price and returns the surcharge owed for the part of the
    /// swap that left the previous range (zero in a quiet block, or for a swap that stays inside the range: reverting
    /// an earlier move, or re-covering ground the block already paid for).
    function _extendRangeAndPrice(PoolId poolId, uint256 amount, bool inCurrency1) private returns (uint256) {
        PoolState storage state = _pools[poolId];
        uint256 rate = state.surchargePips;
        if (rate == 0) return 0;

        // beforeSwap stored the pre-swap price because the rate is non-zero; the rate cannot change between the two
        // callbacks of one swap. The slot is cleared so that nothing leaks into a later swap in this transaction.
        TransientSlot.Uint256Slot preSlot = _preSwapPriceSlot(poolId);
        uint256 pre = preSlot.tload();
        preSlot.tstore(0);
        // slither-disable-next-line unused-return
        (uint160 post,,,) = poolManager.getSlot0(poolId);

        // Every price change in a surcharged block passes through here, so `pre` always lies inside [low, high], and
        // the edge the swap moves toward lies between `pre` and `post` whenever the swap leaves the range.
        uint256 edge;
        if (post < pre) {
            edge = state.lowSqrtPriceX96;
            if (post >= edge) return 0;
            state.lowSqrtPriceX96 = post;
        } else {
            edge = state.highSqrtPriceX96;
            if (post <= edge) return 0;
            state.highSqrtPriceX96 = post;
        }
        return VolatilityMath.proRatedSurcharge(amount, rate, pre, post, edge, inCurrency1);
    }

    /// @dev Donates the surcharge to the in-range LPs. donate() debits the hook by `surcharge`; the afterSwap return
    /// delta credits it by the same amount, so the hook's PoolManager delta is back to zero when the swap returns.
    function _donateSurcharge(address sender, PoolKey calldata key, PoolId poolId, bool inCurrency1, uint256 surcharge)
        private
    {
        (uint256 amount0, uint256 amount1) = inCurrency1 ? (uint256(0), surcharge) : (surcharge, uint256(0));
        // Emitted before the donation; the only earlier external calls are read-only PoolManager views.
        // forge-lint: disable-next-line(reentrancy-events)
        emit HookFee(PoolId.unwrap(poolId), sender, amount0.toUint128(), amount1.toUint128());
        // The returned delta is exactly (-amount0, -amount1), the debit this donation books against the hook; it is
        // offset by the afterSwap return delta, so there is nothing further to do with it.
        // slither-disable-start unused-return
        // forge-lint: disable-next-line(unused-return)
        poolManager.donate(key, amount0, amount1, "");
        // slither-disable-end unused-return
    }

    /// @dev Commits a liquidity modification to the module's queue. Storage writes and an event only: nothing here can
    /// revert for a valid modification, and no module code runs.
    function _queueNotification(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued
    ) private {
        ILiquidityModule module = liquidityModule;
        if (address(module) == address(0)) return;
        uint256 id = notificationCount++;
        LiquidityNotification memory notification = LiquidityNotification(sender, key, params, delta, feesAccrued);
        pendingNotification[id] = _notificationDigest(module, notification);
        emit LiquidityNotificationQueued(id, module, notification);
    }

    /// @dev Commitment to a notification and the module it is addressed to (never zero: it is a keccak256 digest).
    function _notificationDigest(ILiquidityModule module, LiquidityNotification memory notification)
        private
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(module, notification));
    }

    /// @dev Transient slot holding the pre-swap sqrt price of `poolId` between beforeSwap and afterSwap.
    function _preSwapPriceSlot(PoolId poolId) private pure returns (TransientSlot.Uint256Slot) {
        return PRE_SWAP_PRICE_SLOT.deriveMapping(PoolId.unwrap(poolId)).asUint256();
    }

    /// @dev Absolute value of an int128 as uint256 (handles type(int128).min).
    function _abs(int128 x) private pure returns (uint256) {
        // Casting to uint256 is safe: each branch casts a non-negative int256 (type(int128).min negates without
        // overflow in int256).
        // forge-lint: disable-next-line(unsafe-typecast)
        return x >= 0 ? uint256(int256(x)) : uint256(-int256(x));
    }
}
