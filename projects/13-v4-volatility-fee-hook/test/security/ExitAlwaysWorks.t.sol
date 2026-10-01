// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {HookFixture} from "../utils/HookFixture.sol";
import {MultiActionRouter} from "../utils/Routers.sol";
import {
    ModuleBase,
    RevertingModule,
    GasGuzzlerModule,
    ReturnBombModule,
    DanglingDeltaModule,
    ClaimMintModule,
    SyncHijackModule,
    UnsettledUnlockModule,
    PrivilegeEscalationModule,
    FlashRepayModule,
    CountingModule,
    NestedSwapModule,
    CountNeutralModule
} from "../utils/mocks/HostileModules.sol";
import {ILiquidityModule} from "../../src/interfaces/ILiquidityModule.sol";

/// @notice Trail of Bits pattern 6, "hook failures can block pool actions". The liquidity module is non-essential, so
/// no module behaviour (revert, gas exhaustion, return bomb, unsettled deltas, sync hijack, unlocks of its own,
/// privilege escalation, nested swaps, or the count-neutral settleFor trick from the external review) may stop an LP
/// from exiting. The hook makes this structural rather than best-effort: a liquidity operation only commits a
/// notification, and the module runs later, in `deliverNotification`, while the PoolManager is locked. Every test
/// checks both halves: the exit (the module is never reached), and the delivery (a hostile module fails on its own,
/// in the deliverer's transaction, and never leaves the hook holding anything).
contract ExitAlwaysWorksTest is HookFixture {
    using StateLibrary for IPoolManager;

    int24 internal constant LOWER = -1200;
    int24 internal constant UPPER = 1200;
    uint128 internal constant LIQ = 50e18;
    bytes32 internal constant SALT = bytes32(uint256(0xE417));

    MultiActionRouter internal multiRouter;

    function setUp() public {
        setUpEnvironment();
        multiRouter = new MultiActionRouter(manager);
        IERC20(Currency.unwrap(currency0)).approve(address(multiRouter), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(multiRouter), type(uint256).max);
    }

    function test_exit_revertingModule() public {
        _assertExitThenDelivery(new RevertingModule(), false);
    }

    function test_exit_gasGuzzlerModule() public {
        _assertExitThenDelivery(new GasGuzzlerModule(), false);
    }

    function test_exit_returnBombModule() public {
        _assertExitThenDelivery(new ReturnBombModule(), false);
    }

    function test_exit_danglingDeltaModule() public {
        DanglingDeltaModule m = new DanglingDeltaModule(manager, currency0);
        _assertExitThenDelivery(m, false);
        assertEq(currency0.balanceOf(address(m)), 0, "take reverts: the PoolManager is locked at delivery");
    }

    function test_exit_claimMintModule() public {
        ClaimMintModule m = new ClaimMintModule(manager, currency0);
        _assertExitThenDelivery(m, false);
        assertEq(manager.balanceOf(address(m), currency0.toId()), 0, "mint reverts: the PoolManager is locked");
    }

    /// @notice `sync` works while the PoolManager is locked, so this module "succeeds". The checkpoint it moves only
    /// lives in the deliverer's transaction, and every settlement re-syncs first: a swap and an exit in the same
    /// transaction still settle.
    function test_exit_syncHijackModule() public {
        _assertExitThenDelivery(new SyncHijackModule(manager, currency1), true);
        swapExactIn(poolKey, true, 1e18);
        addLiquidity(poolKey, LOWER, UPPER, LIQ, SALT);
        removeLiquidity(poolKey, LOWER, UPPER, LIQ, SALT);
    }

    function test_exit_unsettledUnlockModule() public {
        _assertExitThenDelivery(new UnsettledUnlockModule(manager, currency0), false);
    }

    function test_exit_privilegeEscalationModule() public {
        PrivilegeEscalationModule m = new PrivilegeEscalationModule(hook);
        _assertExitThenDelivery(m, false);
        assertEq(address(hook.liquidityModule()), address(m), "module could not remove itself");
    }

    function test_exit_nestedSwapModule() public {
        _assertExitThenDelivery(new NestedSwapModule(manager), false);
    }

    /// @notice No false positives: a module that flash-borrows from the PoolManager inside an unlock of its own and
    /// repays before it ends is delivered successfully.
    function test_exit_flashRepayModule_isAllowed() public {
        FlashRepayModule m = new FlashRepayModule(manager, currency0);
        _assertExitThenDelivery(m, true);
        assertEq(m.completedCalls(), 2, "add and remove both delivered");
    }

    function test_exit_wellBehavedModule() public {
        CountingModule m = new CountingModule();
        _assertExitThenDelivery(m, true);
        assertEq(m.completedCalls(), 2);
        assertEq(m.netLiquidity(), 0);
    }

    /// @notice A module address without code is a harmless no-op, both at exit and at delivery.
    function test_exit_codelessModule() public {
        ILiquidityModule eoa = ILiquidityModule(makeAddr("eoa"));
        vm.prank(owner);
        hook.setLiquidityModule(eoa);
        vm.recordLogs();
        addLiquidity(poolKey, LOWER, UPPER, LIQ, SALT);
        removeLiquidity(poolKey, LOWER, UPPER, LIQ, SALT);
        Queued[] memory q = queuedIn(vm.getRecordedLogs(), address(hook));
        assertEq(_positionLiquidity(), 0);
        assertTrue(deliver(q[0]));
        assertTrue(deliver(q[1]));
    }

    /// @notice Regression for the external review's exit-blocking attack. A router removes liquidity from the hook
    /// pool inside the same unlock as a swap elsewhere that leaves an open debt (a PositionManager-style batch). Under
    /// the old in-unlock sandbox, CountNeutralModule took 1 wei and paid off the router's debt with settleFor: the
    /// PoolManager's open-delta count, sync currency and reserves were unchanged, so the sandbox let it through, and
    /// the whole exit reverted with CurrencyNotSettled. Now the module is not reached during the exit, and at delivery
    /// the PoolManager is locked, so there is no debt to hide behind.
    function test_exit_countNeutralModuleCannotBlockAMultiActionExit() public {
        ModifyLiquidityParams memory add = ModifyLiquidityParams(-600, 600, 10e18, bytes32("p"));
        ModifyLiquidityParams memory rem = ModifyLiquidityParams(-600, 600, -10e18, bytes32("p"));
        multiRouter.run(staticKey, false, poolKey, add);

        CountNeutralModule m = new CountNeutralModule(manager, address(multiRouter));
        IERC20(Currency.unwrap(currency0)).transfer(address(m), 10e18);
        vm.prank(owner);
        hook.setLiquidityModule(m);

        vm.recordLogs();
        BalanceDelta d = multiRouter.run(staticKey, true, poolKey, rem);
        Queued[] memory q = queuedIn(vm.getRecordedLogs(), address(hook));

        (uint128 left,,) = manager.getPositionInfo(poolId, address(multiRouter), -600, 600, bytes32("p"));
        assertEq(left, 0, "the multi-action exit completed");
        assertGt(d.amount0(), 0, "and paid the LP token0");
        assertGt(d.amount1(), 0, "and token1");

        assertEq(q.length, 1);
        assertTrue(deliver(q[0]), "delivered later, while the PoolManager is locked");
        assertEq(m.completedCalls(), 0, "no open debt existed to hide the theft behind");
        assertEq(currency1.balanceOf(address(m)), 0);
        _assertHookHoldsNothing();
    }

    /// @notice The gas an exit costs does not depend on the module at all: queueing is the same storage write and
    /// event whatever the module does. The module's gas budget is only ever spent by whoever delivers.
    function test_exit_gasDoesNotDependOnTheModule() public {
        ILiquidityModule[4] memory modules = [
            ILiquidityModule(new CountingModule()),
            new RevertingModule(),
            new GasGuzzlerModule(),
            new ReturnBombModule()
        ];
        // Each measurement runs in a fresh call frame, so that the test's own memory use cannot skew it.
        uint256 counting = this.exitGas(modules[0]);
        assertEq(this.exitGas(modules[1]), counting, "reverting");
        assertEq(this.exitGas(modules[2]), counting, "gas guzzler");
        assertEq(this.exitGas(modules[3]), counting, "return bomb");
        uint256 none = this.exitGas(ILiquidityModule(address(0)));
        assertLt(counting - none, 40_000, "queueing one notification costs a fixed ~30k gas");
    }

    /// @dev External so that every measurement starts from the same (empty) memory.
    function exitGas(ILiquidityModule m) external returns (uint256) {
        return _exitGas(m);
    }

    /// @notice The extra gas a hostile module can impose on its deliverer is bounded by the module budget plus the
    /// call reserve: the hook never copies the module's return data, so a return bomb costs no more than a guzzler.
    function test_delivery_gasGriefingIsBounded() public {
        uint256 baseline = _deliveryGas(new CountingModule());
        uint256 bound = hook.MODULE_GAS_LIMIT() + hook.MODULE_CALL_RESERVE();
        assertLe(_deliveryGas(new GasGuzzlerModule()), baseline + bound, "gas guzzler bounded");
        assertLe(_deliveryGas(new ReturnBombModule()), baseline + bound, "return bomb bounded (no copy of 150 KB)");
    }

    /// @notice Fuzzed: whatever module is installed, whatever the market did, and whether the exit is a plain router
    /// call or part of a multi-action unlock with an open debt, a full exit succeeds, every queued notification can
    /// then be delivered without reverting, and the hook ends up holding nothing.
    function testFuzz_exitAlwaysWorks(uint8 moduleKind, uint256 swapSeed, uint128 liquidity, bool multiAction) public {
        liquidity = uint128(bound(liquidity, 1e9, 200e18));
        ILiquidityModule m = _module(moduleKind % 13);
        vm.prank(owner);
        hook.setLiquidityModule(m);

        vm.recordLogs();
        _modify(multiAction, int256(uint256(liquidity)));
        for (uint256 i; i < 4; ++i) {
            uint256 r = uint256(keccak256(abi.encode(swapSeed, i)));
            nextBlock();
            swapExactIn(poolKey, r % 2 == 0, bound(r >> 8, 1e12, 40e18));
        }
        BalanceDelta paid = _modify(multiAction, -int256(uint256(liquidity)));
        Queued[] memory q = queuedIn(vm.getRecordedLogs(), address(hook));

        address positionOwner = multiAction ? address(multiRouter) : address(modifyLiquidityRouter);
        (uint128 left,,) = manager.getPositionInfo(poolId, positionOwner, LOWER, UPPER, SALT);
        assertEq(left, 0, "position fully closed");
        assertTrue(paid.amount0() >= 0 && paid.amount1() >= 0, "an exit never charges the LP");
        assertGt(int256(paid.amount0()) + int256(paid.amount1()), 0, "LP received its funds");
        assertEq(q.length, address(m) == address(0) ? 0 : 2, "one notification per modification");
        for (uint256 i; i < q.length; ++i) {
            deliver(q[i]);
        }
        _assertHookHoldsNothing();
    }

    // ------------------------------------------------------------------------------------------------ helpers

    function _assertExitThenDelivery(ILiquidityModule m, bool expectDeliverySuccess) internal {
        vm.prank(owner);
        hook.setLiquidityModule(m);

        vm.recordLogs();
        addLiquidity(poolKey, LOWER, UPPER, LIQ, SALT);
        assertEq(_positionLiquidity(), LIQ);

        // Trade so the exit also collects fees and donations.
        swapExactIn(poolKey, true, 20e18);
        nextBlock();
        swapExactIn(poolKey, false, 25e18);

        (uint256 b0, uint256 b1) = balancesOf(address(this));
        BalanceDelta d = removeLiquidity(poolKey, LOWER, UPPER, LIQ, SALT);
        (uint256 a0, uint256 a1) = balancesOf(address(this));
        Queued[] memory q = queuedIn(vm.getRecordedLogs(), address(hook));

        assertEq(_positionLiquidity(), 0, "exit completed");
        assertEq(int256(a0) - int256(b0), int256(d.amount0()), "LP received token0");
        assertEq(int256(a1) - int256(b1), int256(d.amount1()), "LP received token1");
        assertEq(ModuleBase(address(m)).completedCalls(), 0, "the module was not reached by the add or the exit");
        assertEq(q.length, 2, "both modifications queued");

        for (uint256 i; i < q.length; ++i) {
            assertEq(deliver(q[i]), expectDeliverySuccess, "delivery outcome");
            assertEq(hook.pendingNotification(q[i].id), bytes32(0), "consumed either way");
        }
        if (!expectDeliverySuccess) {
            assertEq(ModuleBase(address(m)).completedCalls(), 0, "every module side effect was reverted");
        }
        _assertHookHoldsNothing();
    }

    /// @dev Returns the liquidity modification's own delta (for the multi-action router: without the static swap).
    function _modify(bool multiAction, int256 delta) internal returns (BalanceDelta) {
        ModifyLiquidityParams memory p = ModifyLiquidityParams(LOWER, UPPER, delta, SALT);
        if (multiAction) {
            return multiRouter.run(staticKey, delta < 0, poolKey, p); // the exit shares its unlock with a swap
        }
        return modifyLiquidityRouter.modifyLiquidity(poolKey, p, ZERO_BYTES);
    }

    function _exitGas(ILiquidityModule m) internal returns (uint256 used) {
        uint256 snapshot = vm.snapshotState();
        vm.prank(owner);
        hook.setLiquidityModule(m);
        addLiquidity(poolKey, LOWER, UPPER, LIQ, SALT);
        uint256 g = gasleft();
        removeLiquidity(poolKey, LOWER, UPPER, LIQ, SALT);
        used = g - gasleft();
        vm.revertToState(snapshot);
    }

    function _deliveryGas(ILiquidityModule m) internal returns (uint256 used) {
        uint256 snapshot = vm.snapshotState();
        vm.prank(owner);
        hook.setLiquidityModule(m);
        vm.recordLogs();
        addLiquidity(poolKey, LOWER, UPPER, LIQ, SALT);
        Queued[] memory q = queuedIn(vm.getRecordedLogs(), address(hook));
        uint256 g = gasleft();
        hook.deliverNotification(q[0].id, q[0].module, q[0].notification);
        used = g - gasleft();
        vm.revertToState(snapshot);
    }

    function _module(uint256 kind) internal returns (ILiquidityModule) {
        if (kind == 0) return ILiquidityModule(address(0));
        if (kind == 1) return new RevertingModule();
        if (kind == 2) return new GasGuzzlerModule();
        if (kind == 3) return new ReturnBombModule();
        if (kind == 4) return new DanglingDeltaModule(manager, currency0);
        if (kind == 5) return new ClaimMintModule(manager, currency1);
        if (kind == 6) return new SyncHijackModule(manager, currency0);
        if (kind == 7) return new UnsettledUnlockModule(manager, currency1);
        if (kind == 8) return new PrivilegeEscalationModule(hook);
        if (kind == 9) return new FlashRepayModule(manager, currency1);
        if (kind == 10) return new NestedSwapModule(manager);
        if (kind == 11) {
            CountNeutralModule m = new CountNeutralModule(manager, address(multiRouter));
            IERC20(Currency.unwrap(currency0)).transfer(address(m), 100e18);
            return m;
        }
        return new CountingModule();
    }

    function _positionLiquidity() internal view returns (uint128 liquidity) {
        (liquidity,,) = manager.getPositionInfo(poolId, address(modifyLiquidityRouter), LOWER, UPPER, SALT);
    }

    function _assertHookHoldsNothing() internal view {
        assertEq(currency0.balanceOf(address(hook)), 0);
        assertEq(currency1.balanceOf(address(hook)), 0);
        assertEq(manager.balanceOf(address(hook), currency0.toId()), 0);
        assertEq(manager.balanceOf(address(hook), currency1.toId()), 0);
        assertEq(address(hook).balance, 0);
    }
}
