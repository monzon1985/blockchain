// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Script.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {VolatilityFeeHook} from "../src/VolatilityFeeHook.sol";
import {IVolatilityFeeHook} from "../src/interfaces/IVolatilityFeeHook.sol";
import {LiquidityTelemetry} from "../src/modules/LiquidityTelemetry.sol";
import {HookDeployment} from "./HookDeployment.sol";

/// @notice Local end-to-end demo for anvil (see script/local-demo.sh): deploys a PoolManager, two mock tokens, test
/// routers and the hook, opens a dynamic-fee pool, delivers the queued liquidity notification to the telemetry module
/// in its own transaction, and sends swaps in separate transactions (anvil mines each in its own block, so the oracle
/// updates between them). Uses anvil's unlocked default account; no key is involved.
contract LocalDemo is HookDeployment {
    function run() external {
        address sender = msg.sender;

        vm.startBroadcast();
        IPoolManager manager = new PoolManager(sender);
        MockERC20 a = new MockERC20("Demo A", "DMA", 18);
        MockERC20 b = new MockERC20("Demo B", "DMB", 18);
        PoolSwapTest swapRouter = new PoolSwapTest(manager);
        PoolModifyLiquidityTest lpRouter = new PoolModifyLiquidityTest(manager);
        vm.stopBroadcast();

        VolatilityFeeHook hook = _deployHook(
            manager,
            sender,
            IVolatilityFeeHook.FeeConfig({
                alphaWad: 0.1e18, feeSlopePips: 500, surchargeSlopePips: 250, maxSurchargePips: 5000
            })
        );

        (MockERC20 t0, MockERC20 t1) = address(a) < address(b) ? (a, b) : (b, a);
        PoolKey memory key = PoolKey(
            Currency.wrap(address(t0)),
            Currency.wrap(address(t1)),
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            60,
            IHooks(address(hook))
        );

        vm.startBroadcast();
        LiquidityTelemetry telemetry = new LiquidityTelemetry(address(hook));
        hook.setCurrencyAllowed(key.currency0, true);
        hook.setCurrencyAllowed(key.currency1, true);
        hook.setLiquidityModule(telemetry);
        t0.mint(sender, 1_000_000e18);
        t1.mint(sender, 1_000_000e18);
        t0.approve(address(lpRouter), type(uint256).max);
        t1.approve(address(lpRouter), type(uint256).max);
        t0.approve(address(swapRouter), type(uint256).max);
        t1.approve(address(swapRouter), type(uint256).max);
        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));
        ModifyLiquidityParams memory params = ModifyLiquidityParams(-6000, 6000, 1000e18, 0);
        BalanceDelta delta = lpRouter.modifyLiquidity(key, params, "");
        // The addition queued notification 0 for the telemetry module. Deliver it in a separate transaction, while the
        // PoolManager is locked (a new position has collected no fees).
        hook.deliverNotification(
            0,
            telemetry,
            IVolatilityFeeHook.LiquidityNotification(address(lpRouter), key, params, delta, BalanceDelta.wrap(0))
        );

        // Each broadcast transaction lands in its own anvil block: a volatile block, then quieter ones.
        _swap(swapRouter, key, false, 2e18);
        _swap(swapRouter, key, true, 0.5e18);
        _swap(swapRouter, key, true, 0.2e18);
        _swap(swapRouter, key, false, 0.2e18);
        vm.stopBroadcast();

        console2.log("PoolManager:", address(manager));
        console2.log("Hook:       ", address(hook));
        console2.log("Telemetry:  ", address(telemetry));
        console2.log("Token0:     ", address(t0));
        console2.log("Token1:     ", address(t1));
        console2.log("PoolId:");
        console2.logBytes32(keccak256(abi.encode(key)));
    }

    function _swap(PoolSwapTest router, PoolKey memory key, bool zeroForOne, uint256 amountIn) internal {
        router.swap(
            key,
            SwapParams(
                zeroForOne, -int256(amountIn), zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
    }
}
