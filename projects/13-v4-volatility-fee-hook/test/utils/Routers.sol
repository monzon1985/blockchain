// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/utils/CurrencySettler.sol";

import {IVolatilityFeeHook} from "../../src/interfaces/IVolatilityFeeHook.sol";
import {ILiquidityModule} from "../../src/interfaces/ILiquidityModule.sol";

/// @notice Executes many swaps, possibly across pools, inside ONE unlock (one transaction), then settles the net.
/// After every swap it asserts that the pool's hook has no open PoolManager delta: whatever the hook took with its
/// return delta it must already have paid out (donated) inside the callback.
contract BatchSwapRouter is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;
    using CurrencySettler for Currency;

    struct SwapAction {
        PoolKey key;
        SwapParams params;
    }

    struct Batch {
        address payer;
        SwapAction[] actions;
    }

    /// @notice A hook still had an open delta right after its swap returned.
    error HookDeltaOutstanding(address hook, Currency currency, int256 delta);

    error NotManager();

    IPoolManager public immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    /// @notice Runs `actions` in order inside a single unlock; `payer` funds (and receives) the net amounts.
    function swapBatch(address payer, SwapAction[] calldata actions) external returns (BalanceDelta[] memory deltas) {
        bytes memory result = manager.unlock(abi.encode(Batch({payer: payer, actions: actions})));
        deltas = abi.decode(result, (BalanceDelta[]));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert NotManager();
        Batch memory batch = abi.decode(data, (Batch));
        BalanceDelta[] memory deltas = new BalanceDelta[](batch.actions.length);
        for (uint256 i; i < batch.actions.length; ++i) {
            SwapAction memory a = batch.actions[i];
            deltas[i] = manager.swap(a.key, a.params, "");
            _assertHookSettled(a.key);
        }
        for (uint256 i; i < batch.actions.length; ++i) {
            _settle(batch.actions[i].key.currency0, batch.payer);
            _settle(batch.actions[i].key.currency1, batch.payer);
        }
        return abi.encode(deltas);
    }

    function _assertHookSettled(PoolKey memory key) private view {
        address hook = address(key.hooks);
        if (hook == address(0)) return;
        int256 d0 = manager.currencyDelta(hook, key.currency0);
        if (d0 != 0) revert HookDeltaOutstanding(hook, key.currency0, d0);
        int256 d1 = manager.currencyDelta(hook, key.currency1);
        if (d1 != 0) revert HookDeltaOutstanding(hook, key.currency1, d1);
    }

    function _settle(Currency currency, address payer) private {
        int256 delta = manager.currencyDelta(address(this), currency);
        if (delta < 0) currency.settle(manager, payer, uint256(-delta), false);
        else if (delta > 0) currency.take(manager, payer, uint256(delta), false);
    }
}

/// @notice A multi-action router in the style of a PositionManager batch: inside ONE unlock it optionally swaps in one
/// pool (leaving an open debt for a while) and then modifies liquidity in another, and only settles at the end. This
/// is the shape the external review used to show that a module running inside the unlock could block an exit.
contract MultiActionRouter is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;
    using CurrencySettler for Currency;

    IPoolManager public immutable manager;
    address internal payer;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    /// @notice Swaps 1e18 of currency0 in `swapKey` first (if `withSwap`), then applies `params` to `liquidityKey`.
    function run(
        PoolKey calldata swapKey,
        bool withSwap,
        PoolKey calldata liquidityKey,
        ModifyLiquidityParams calldata p
    ) external returns (BalanceDelta liquidityDelta) {
        payer = msg.sender;
        liquidityDelta = abi.decode(manager.unlock(abi.encode(swapKey, withSwap, liquidityKey, p)), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager only");
        (PoolKey memory sk, bool withSwap, PoolKey memory lk, ModifyLiquidityParams memory p) =
            abi.decode(data, (PoolKey, bool, PoolKey, ModifyLiquidityParams));
        if (withSwap) manager.swap(sk, SwapParams(true, -1e18, TickMath.MIN_SQRT_PRICE + 1), "");
        (BalanceDelta delta,) = manager.modifyLiquidity(lk, p, "");
        _settle(sk.currency0);
        _settle(sk.currency1);
        _settle(lk.currency0);
        _settle(lk.currency1);
        return abi.encode(delta);
    }

    function _settle(Currency c) private {
        int256 d = manager.currencyDelta(address(this), c);
        if (d < 0) c.settle(manager, payer, uint256(-d), false);
        else if (d > 0) c.take(manager, payer, uint256(d), false);
    }
}

/// @notice Tries to deliver a queued liquidity notification from inside its own unlock callback, i.e. to make a
/// module run while the PoolManager is unlocked. The hook refuses.
contract UnlockedDeliveryRouter is IUnlockCallback {
    IPoolManager public immutable manager;
    IVolatilityFeeHook public immutable hook;

    constructor(IPoolManager manager_, IVolatilityFeeHook hook_) {
        manager = manager_;
        hook = hook_;
    }

    function deliverInsideUnlock(
        uint256 id,
        ILiquidityModule module,
        IVolatilityFeeHook.LiquidityNotification calldata notification
    ) external {
        manager.unlock(abi.encode(id, module, notification));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (uint256 id, ILiquidityModule module, IVolatilityFeeHook.LiquidityNotification memory n) =
            abi.decode(data, (uint256, ILiquidityModule, IVolatilityFeeHook.LiquidityNotification));
        hook.deliverNotification(id, module, n);
        return "";
    }
}

/// @notice Swaps in a hook pool, then tries to open a nested unlock from the same unlock callback (the PoolManager
/// rejects it with AlreadyUnlocked; the router catches that), then swaps in the hook pool again and settles. Used to
/// check that the hook's per-swap state survives a rejected nested unlock between two of its swaps.
contract NestedUnlockSwapRouter is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;
    using CurrencySettler for Currency;

    IPoolManager public immutable manager;
    address internal payer;
    bool public nestedUnlockRejected;
    bytes public nestedUnlockError;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function swapTwiceWithNestedUnlock(PoolKey calldata key, SwapParams calldata first, SwapParams calldata second)
        external
    {
        payer = msg.sender;
        manager.unlock(abi.encode(key, first, second));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager only");
        (PoolKey memory key, SwapParams memory first, SwapParams memory second) =
            abi.decode(data, (PoolKey, SwapParams, SwapParams));
        manager.swap(key, first, "");
        try manager.unlock("") {}
        catch (bytes memory reason) {
            nestedUnlockRejected = true;
            nestedUnlockError = reason;
        }
        manager.swap(key, second, "");
        _settle(key.currency0);
        _settle(key.currency1);
        return "";
    }

    function _settle(Currency c) private {
        int256 d = manager.currencyDelta(address(this), c);
        if (d < 0) c.settle(manager, payer, uint256(-d), false);
        else if (d > 0) c.take(manager, payer, uint256(d), false);
    }
}
