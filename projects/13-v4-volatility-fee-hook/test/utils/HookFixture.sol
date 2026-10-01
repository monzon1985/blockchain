// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Vm} from "forge-std/Vm.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {VolatilityFeeHook} from "../../src/VolatilityFeeHook.sol";
import {IVolatilityFeeHook} from "../../src/interfaces/IVolatilityFeeHook.sol";
import {ILiquidityModule} from "../../src/interfaces/ILiquidityModule.sol";

/// @notice Shared fixture on top of v4-core's Deployers: a PoolManager with test routers, two sorted mock tokens, a
/// HookMiner-mined hook deployment, a dynamic-fee pool that uses it and a static 30 bps pool without hooks.
abstract contract HookFixture is Deployers {
    using StateLibrary for IPoolManager;

    /// @dev Exactly the six callbacks VolatilityFeeHook implements.
    uint160 internal constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    int24 internal constant TICK_SPACING = 60;
    int24 internal constant RANGE_LOWER = -6000;
    int24 internal constant RANGE_UPPER = 6000;
    uint128 internal constant POOL_LIQUIDITY = 1000e18;

    address internal owner = makeAddr("owner");
    address internal lp = makeAddr("lp");
    address internal trader = makeAddr("trader");

    VolatilityFeeHook internal hook;
    PoolKey internal poolKey;
    PoolId internal poolId;
    PoolKey internal staticKey;
    PoolId internal staticId;

    function defaultConfig() internal pure returns (IVolatilityFeeHook.FeeConfig memory) {
        return IVolatilityFeeHook.FeeConfig({
            alphaWad: 0.1e18, feeSlopePips: 500, surchargeSlopePips: 250, maxSurchargePips: 5000
        });
    }

    /// @dev Mines a CREATE2 salt whose address encodes HOOK_FLAGS and deploys the hook with it.
    function deployHook(IVolatilityFeeHook.FeeConfig memory config) internal returns (VolatilityFeeHook deployed) {
        bytes memory args = abi.encode(manager, owner, config);
        (address expected, bytes32 salt) =
            HookMiner.find(address(this), HOOK_FLAGS, type(VolatilityFeeHook).creationCode, args);
        deployed = new VolatilityFeeHook{salt: salt}(manager, owner, config);
        assertEq(address(deployed), expected, "HookMiner address mismatch");
    }

    function setUpEnvironment() internal {
        setUpEnvironment(defaultConfig());
    }

    function setUpEnvironment(IVolatilityFeeHook.FeeConfig memory config) internal {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        hook = deployHook(config);

        vm.startPrank(owner);
        hook.setCurrencyAllowed(currency0, true);
        hook.setCurrencyAllowed(currency1, true);
        vm.stopPrank();

        (poolKey, poolId) = initPool(
            currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, TICK_SPACING, SQRT_PRICE_1_1
        );
        (staticKey, staticId) = initPool(currency0, currency1, IHooks(address(0)), 3000, TICK_SPACING, SQRT_PRICE_1_1);

        addLiquidity(poolKey, RANGE_LOWER, RANGE_UPPER, POOL_LIQUIDITY, 0);
        addLiquidity(staticKey, RANGE_LOWER, RANGE_UPPER, POOL_LIQUIDITY, 0);
    }

    function addLiquidity(PoolKey memory key_, int24 lower, int24 upper, uint128 liquidity, bytes32 salt) internal {
        modifyLiquidityRouter.modifyLiquidity(
            key_,
            ModifyLiquidityParams({
                tickLower: lower, tickUpper: upper, liquidityDelta: int256(uint256(liquidity)), salt: salt
            }),
            ZERO_BYTES
        );
    }

    function removeLiquidity(PoolKey memory key_, int24 lower, int24 upper, uint128 liquidity, bytes32 salt)
        internal
        returns (BalanceDelta)
    {
        return modifyLiquidityRouter.modifyLiquidity(
            key_,
            ModifyLiquidityParams({
                tickLower: lower, tickUpper: upper, liquidityDelta: -int256(uint256(liquidity)), salt: salt
            }),
            ZERO_BYTES
        );
    }

    /// @dev Exact-input swap with no price limit (other than the global bounds).
    function swapExactIn(PoolKey memory key_, bool zeroForOne, uint256 amountIn) internal returns (BalanceDelta) {
        return swapWithLimit(key_, zeroForOne, -int256(amountIn), zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT);
    }

    /// @dev Exact-output swap with no price limit (other than the global bounds).
    function swapExactOut(PoolKey memory key_, bool zeroForOne, uint256 amountOut) internal returns (BalanceDelta) {
        return swapWithLimit(key_, zeroForOne, int256(amountOut), zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT);
    }

    function swapWithLimit(PoolKey memory key_, bool zeroForOne, int256 amountSpecified, uint160 limit)
        internal
        returns (BalanceDelta)
    {
        return swapWithSettings(key_, zeroForOne, amountSpecified, limit, false);
    }

    /// @dev `withClaims`: the output is minted as ERC-6909 claims and the input is paid by burning claims (the payer
    /// must hold enough of them and have made the swap router its operator).
    function swapWithSettings(
        PoolKey memory key_,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 limit,
        bool withClaims
    ) internal returns (BalanceDelta) {
        return swapRouter.swap(
            key_,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings({takeClaims: withClaims, settleUsingBurn: withClaims}),
            ZERO_BYTES
        );
    }

    /// @notice What one swap did, reconstructed from balances and from the PoolManager's and hook's own events.
    struct SwapObservation {
        int256 traderDelta0; // change of the payer's currency0 balance
        int256 traderDelta1; // change of the payer's currency1 balance
        int128 poolAmount0; // PoolManager Swap event (swapper perspective, before hook deltas)
        int128 poolAmount1;
        uint24 fee; // fee reported by the PoolManager Swap event
        uint256 surcharge0; // hook HookFee event
        uint256 surcharge1;
        uint256 donated0; // PoolManager Donate event emitted for the hook
        uint256 donated1;
        uint256 swapEvents;
        int256 claimDelta0; // change of the payer's ERC-6909 claim on currency0
        int256 claimDelta1;
    }

    bytes32 internal constant SWAP_TOPIC =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
    bytes32 internal constant DONATE_TOPIC = keccak256("Donate(bytes32,address,uint256,uint256)");
    bytes32 internal constant HOOK_FEE_TOPIC = keccak256("HookFee(bytes32,address,uint128,uint128)");

    /// @dev Executes a swap through PoolSwapTest (payer = this contract) and decodes everything it emitted.
    function observeSwap(PoolKey memory key_, bool zeroForOne, int256 amountSpecified, uint160 limit)
        internal
        returns (SwapObservation memory o)
    {
        return observeSwapWithSettings(key_, zeroForOne, amountSpecified, limit, false);
    }

    function observeSwapWithSettings(
        PoolKey memory key_,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 limit,
        bool withClaims
    ) internal returns (SwapObservation memory o) {
        (uint256 b0, uint256 b1) = balancesOf(address(this));
        (uint256 c0, uint256 c1) = claimsOf(address(this));
        vm.recordLogs();
        swapWithSettings(key_, zeroForOne, amountSpecified, limit, withClaims);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (uint256 a0, uint256 a1) = balancesOf(address(this));
        (uint256 d0, uint256 d1) = claimsOf(address(this));
        o.traderDelta0 = int256(a0) - int256(b0);
        o.traderDelta1 = int256(a1) - int256(b1);
        o.claimDelta0 = int256(d0) - int256(c0);
        o.claimDelta1 = int256(d1) - int256(c1);
        o = _decodeSwapLogs(logs, o);
    }

    function observeSwap(PoolKey memory key_, bool zeroForOne, int256 amountSpecified)
        internal
        returns (SwapObservation memory)
    {
        return observeSwap(key_, zeroForOne, amountSpecified, zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT);
    }

    function _decodeSwapLogs(Vm.Log[] memory logs, SwapObservation memory o)
        internal
        view
        returns (SwapObservation memory)
    {
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory l = logs[i];
            if (l.topics.length == 0) continue;
            if (l.emitter == address(manager) && l.topics[0] == SWAP_TOPIC) {
                (o.poolAmount0, o.poolAmount1,,,, o.fee) =
                    abi.decode(l.data, (int128, int128, uint160, uint128, int24, uint24));
                ++o.swapEvents;
            } else if (
                l.emitter == address(manager) && l.topics[0] == DONATE_TOPIC
                    && address(uint160(uint256(l.topics[2]))) == address(hook)
            ) {
                (uint256 d0, uint256 d1) = abi.decode(l.data, (uint256, uint256));
                o.donated0 += d0;
                o.donated1 += d1;
            } else if (l.emitter == address(hook) && l.topics[0] == HOOK_FEE_TOPIC) {
                (uint128 s0, uint128 s1) = abi.decode(l.data, (uint128, uint128));
                o.surcharge0 += s0;
                o.surcharge1 += s1;
            }
        }
        return o;
    }

    /// @dev vm.getBlockNumber() instead of block.number: the optimizer may reuse a block.number read across vm.roll.
    function nextBlock() internal {
        vm.roll(vm.getBlockNumber() + 1);
    }

    function currentTick(PoolId id) internal view returns (int24 tick) {
        (, tick,,) = manager.getSlot0(id);
    }

    function currentSqrtPrice(PoolId id) internal view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,) = manager.getSlot0(id);
    }

    function state() internal view returns (IVolatilityFeeHook.PoolState memory) {
        return hook.getPoolState(poolId);
    }

    function balancesOf(address account) internal view returns (uint256, uint256) {
        return (currency0.balanceOf(account), currency1.balanceOf(account));
    }

    function claimsOf(address account) internal view returns (uint256, uint256) {
        return (manager.balanceOf(account, currency0.toId()), manager.balanceOf(account, currency1.toId()));
    }

    // ------------------------------------------------------------------------------------ liquidity notifications

    /// @notice A notification as a keeper would read it from `LiquidityNotificationQueued`.
    struct Queued {
        uint256 id;
        ILiquidityModule module;
        IVolatilityFeeHook.LiquidityNotification notification;
    }

    bytes32 internal constant QUEUED_TOPIC = keccak256(
        "LiquidityNotificationQueued(uint256,address,(address,(address,address,uint24,int24,address),(int24,int24,int256,bytes32),int256,int256))"
    );
    bytes32 internal constant DELIVERED_TOPIC = keccak256("LiquidityNotificationDelivered(uint256,address,bool)");

    /// @dev Decodes every notification `h` queued in `logs`.
    function queuedIn(Vm.Log[] memory logs, address h) internal pure returns (Queued[] memory out) {
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == h && logs[i].topics[0] == QUEUED_TOPIC) ++n;
        }
        out = new Queued[](n);
        n = 0;
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory l = logs[i];
            if (l.emitter != h || l.topics[0] != QUEUED_TOPIC) continue;
            out[n++] = Queued({
                id: uint256(l.topics[1]),
                module: ILiquidityModule(address(uint160(uint256(l.topics[2])))),
                notification: abi.decode(l.data, (IVolatilityFeeHook.LiquidityNotification))
            });
        }
    }

    /// @dev Delivers one queued notification and returns the success flag the hook reported.
    function deliver(Queued memory q) internal returns (bool success) {
        vm.recordLogs();
        hook.deliverNotification(q.id, q.module, q.notification);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == DELIVERED_TOPIC) {
                return abi.decode(logs[i].data, (bool));
            }
        }
        revert("no delivery event");
    }

    /// @dev The ERC-7751 error the PoolManager raises when a hook callback reverts.
    function wrappedHookError(bytes4 callbackSelector, bytes memory reason) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            bytes4(keccak256("WrappedError(address,bytes4,bytes,bytes)")),
            address(hook),
            callbackSelector,
            reason,
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    /// @dev Sqrt price at a tick (convenience for price limits in tests).
    function sqrtAt(int24 tick) internal pure returns (uint160) {
        return TickMath.getSqrtPriceAtTick(tick);
    }
}
