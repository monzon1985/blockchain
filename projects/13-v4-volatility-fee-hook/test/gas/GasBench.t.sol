// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "../utils/HookFixture.sol";
import {ILiquidityModule} from "../../src/interfaces/ILiquidityModule.sol";
import {LiquidityTelemetry} from "../../src/modules/LiquidityTelemetry.sol";
import {GasGuzzlerModule} from "../utils/mocks/HostileModules.sol";

/// @notice Gas benchmark of the hook's hot paths against a static 30 bps pool without hooks. Every test performs
/// exactly ONE router call on state prepared in setUp (different preparations live in different contracts), so the
/// numbers in .gas-snapshot compare like with like. CI runs `forge snapshot --check --match-contract GasBench`.
abstract contract GasBenchBase is HookFixture {
    function setUp() public virtual {
        setUpEnvironment();
        // Move both pools in the initialization block so the next block opens with non-zero volatility.
        swapExactIn(poolKey, false, 30e18);
        swapExactIn(staticKey, false, 30e18);
        nextBlock();
    }

    function _setModule(ILiquidityModule module) internal {
        vm.prank(owner);
        hook.setLiquidityModule(module);
    }
}

/// @notice First swap of a block after a volatile block, plus liquidity operations without a module.
contract GasBench is GasBenchBase {
    /// @notice Baseline: exact-input swap in the static 30 bps pool.
    function test_gas_swap_static() public {
        swapExactIn(staticKey, true, 1e18);
    }

    /// @notice First swap of a block: oracle update + dynamic fee + surcharge taken and donated.
    function test_gas_swap_hook_firstOfBlock_surcharged() public {
        swapExactIn(poolKey, true, 1e18);
    }

    function test_gas_addLiquidity_static() public {
        addLiquidity(staticKey, -600, 600, 10e18, bytes32(uint256(1)));
    }

    function test_gas_addLiquidity_hook() public {
        addLiquidity(poolKey, -600, 600, 10e18, bytes32(uint256(1)));
    }

    function test_gas_removeLiquidity_static() public {
        removeLiquidity(staticKey, RANGE_LOWER, RANGE_UPPER, 10e18, 0);
    }

    function test_gas_removeLiquidity_hook() public {
        removeLiquidity(poolKey, RANGE_LOWER, RANGE_UPPER, 10e18, 0);
    }
}

/// @notice Later swaps in a block whose first swap already happened (no oracle update).
contract GasBenchSameBlock is GasBenchBase {
    function setUp() public override {
        super.setUp();
        swapExactIn(poolKey, true, 5e18); // opens the block: anchor set, price moved down
        swapExactIn(staticKey, true, 5e18);
    }

    function test_gas_swap_static_sameBlock() public {
        swapExactIn(staticKey, true, 1e18);
    }

    /// @notice Pushing past the block's low: dynamic fee + range update + surcharge, no oracle update.
    function test_gas_swap_hook_sameBlock_extending() public {
        swapExactIn(poolKey, true, 1e18);
    }

    /// @notice Moving back inside the block's price range: dynamic fee only.
    function test_gas_swap_hook_sameBlock_insideRange() public {
        swapExactIn(poolKey, false, 1e18);
    }
}

/// @notice First swap of a block in a quiet pool: oracle update + fee, but zero volatility means no surcharge.
contract GasBenchQuiet is GasBenchBase {
    function setUp() public override {
        super.setUp();
        vm.roll(vm.getBlockNumber() + 1000); // long enough for the EWMA to decay to exactly zero
    }

    function test_gas_swap_hook_firstOfBlock_quiet() public {
        swapExactIn(poolKey, true, 1e18);
    }
}

/// @notice Later swap in a quiet block (zero surcharge rate): the hook only returns the cached fee.
contract GasBenchQuietSameBlock is GasBenchBase {
    function setUp() public override {
        super.setUp();
        vm.roll(vm.getBlockNumber() + 1000);
        swapExactIn(poolKey, true, 1e18); // opens the quiet block
        swapExactIn(staticKey, true, 1e18);
    }

    function test_gas_swap_static_quietSameBlock() public {
        swapExactIn(staticKey, false, 1e18);
    }

    function test_gas_swap_hook_quietSameBlock() public {
        swapExactIn(poolKey, false, 1e18);
    }
}

/// @notice Liquidity operations with a module installed: the LP pays only for queueing one notification.
contract GasBenchTelemetryModule is GasBenchBase {
    function setUp() public override {
        super.setUp();
        _setModule(new LiquidityTelemetry(address(hook)));
    }

    function test_gas_addLiquidity_hook_telemetry() public {
        addLiquidity(poolKey, -600, 600, 10e18, bytes32(uint256(1)));
    }

    function test_gas_removeLiquidity_hook_telemetry() public {
        removeLiquidity(poolKey, RANGE_LOWER, RANGE_UPPER, 10e18, 0);
    }
}

/// @notice A module that burns its whole gas budget costs an exiting LP exactly as much as any other module: it is
/// never called during the exit.
contract GasBenchHostileModule is GasBenchBase {
    function setUp() public override {
        super.setUp();
        _setModule(new GasGuzzlerModule());
    }

    function test_gas_removeLiquidity_hook_gasGuzzler() public {
        removeLiquidity(poolKey, RANGE_LOWER, RANGE_UPPER, 10e18, 0);
    }
}

/// @notice What a keeper pays to deliver one queued notification (the module's own work included).
abstract contract GasBenchDeliveryBase is GasBenchBase {
    Queued internal pending;

    function _queueOne(ILiquidityModule module) internal {
        _setModule(module);
        vm.recordLogs();
        addLiquidity(poolKey, -600, 600, 10e18, bytes32(uint256(1)));
        pending = queuedIn(vm.getRecordedLogs(), address(hook))[0];
    }
}

contract GasBenchDeliveryTelemetry is GasBenchDeliveryBase {
    function setUp() public override {
        super.setUp();
        _queueOne(new LiquidityTelemetry(address(hook)));
    }

    function test_gas_deliver_telemetry() public {
        hook.deliverNotification(pending.id, pending.module, pending.notification);
    }
}

/// @notice Worst case for a keeper: the module burns its whole budget (bounded by MODULE_GAS_LIMIT).
contract GasBenchDeliveryHostile is GasBenchDeliveryBase {
    function setUp() public override {
        super.setUp();
        _queueOne(new GasGuzzlerModule());
    }

    function test_gas_deliver_gasGuzzler() public {
        hook.deliverNotification(pending.id, pending.module, pending.notification);
    }
}
