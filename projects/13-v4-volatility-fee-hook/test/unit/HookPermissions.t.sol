// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {HookFixture} from "../utils/HookFixture.sol";
import {MissingReturnDeltaHook} from "../utils/mocks/MisconfiguredHook.sol";
import {VolatilityFeeHook} from "../../src/VolatilityFeeHook.sol";

/// @notice Trail of Bits pattern 5, "address bits are part of the API": the permissions the hook declares, the bits
/// its CREATE2 address encodes, and the callbacks it actually implements must be the same set.
contract HookPermissionsTest is HookFixture {
    function setUp() public {
        setUpEnvironment();
    }

    /// @notice The mined address encodes exactly getHookPermissions(), bit by bit, for all 14 flags.
    function test_addressBitsEqualDeclaredPermissions() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        IHooks h = IHooks(address(hook));
        assertEq(Hooks.hasPermission(h, Hooks.BEFORE_INITIALIZE_FLAG), p.beforeInitialize, "beforeInitialize");
        assertEq(Hooks.hasPermission(h, Hooks.AFTER_INITIALIZE_FLAG), p.afterInitialize, "afterInitialize");
        assertEq(Hooks.hasPermission(h, Hooks.BEFORE_ADD_LIQUIDITY_FLAG), p.beforeAddLiquidity, "beforeAddLiquidity");
        assertEq(Hooks.hasPermission(h, Hooks.AFTER_ADD_LIQUIDITY_FLAG), p.afterAddLiquidity, "afterAddLiquidity");
        assertEq(
            Hooks.hasPermission(h, Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG), p.beforeRemoveLiquidity, "beforeRemoveLiquidity"
        );
        assertEq(
            Hooks.hasPermission(h, Hooks.AFTER_REMOVE_LIQUIDITY_FLAG), p.afterRemoveLiquidity, "afterRemoveLiquidity"
        );
        assertEq(Hooks.hasPermission(h, Hooks.BEFORE_SWAP_FLAG), p.beforeSwap, "beforeSwap");
        assertEq(Hooks.hasPermission(h, Hooks.AFTER_SWAP_FLAG), p.afterSwap, "afterSwap");
        assertEq(Hooks.hasPermission(h, Hooks.BEFORE_DONATE_FLAG), p.beforeDonate, "beforeDonate");
        assertEq(Hooks.hasPermission(h, Hooks.AFTER_DONATE_FLAG), p.afterDonate, "afterDonate");
        assertEq(
            Hooks.hasPermission(h, Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG),
            p.beforeSwapReturnDelta,
            "beforeSwapReturnDelta"
        );
        assertEq(
            Hooks.hasPermission(h, Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG), p.afterSwapReturnDelta, "afterSwapReturnDelta"
        );
        assertEq(
            Hooks.hasPermission(h, Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG),
            p.afterAddLiquidityReturnDelta,
            "afterAddLiquidityReturnDelta"
        );
        assertEq(
            Hooks.hasPermission(h, Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG),
            p.afterRemoveLiquidityReturnDelta,
            "afterRemoveLiquidityReturnDelta"
        );
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, HOOK_FLAGS, "exact flag set");
    }

    /// @notice Every callback whose bit is set is implemented (does not revert with HookNotImplemented when the
    /// PoolManager calls it), and every callback whose bit is clear is NOT implemented. A set bit without an
    /// implementation would brick the pool; an implementation without its bit would silently never run.
    function test_implementedCallbacksMatchPermissionBits() public {
        Hooks.Permissions memory p = hook.getHookPermissions();
        BalanceDelta zero = toBalanceDelta(0, 0);
        SwapParams memory sp = SwapParams(true, -1, MIN_PRICE_LIMIT);
        PoolKey memory k = poolKey;

        _assertImplemented(
            p.beforeInitialize, abi.encodeCall(IHooks.beforeInitialize, (address(this), _freshKey(), SQRT_PRICE_1_1))
        );
        _assertImplemented(
            p.afterInitialize, abi.encodeCall(IHooks.afterInitialize, (address(this), k, SQRT_PRICE_1_1, 0))
        );
        _assertImplemented(
            p.beforeAddLiquidity, abi.encodeCall(IHooks.beforeAddLiquidity, (address(this), k, LIQUIDITY_PARAMS, ""))
        );
        _assertImplemented(
            p.afterAddLiquidity,
            abi.encodeCall(IHooks.afterAddLiquidity, (address(this), k, LIQUIDITY_PARAMS, zero, zero, ""))
        );
        _assertImplemented(
            p.beforeRemoveLiquidity,
            abi.encodeCall(IHooks.beforeRemoveLiquidity, (address(this), k, REMOVE_LIQUIDITY_PARAMS, ""))
        );
        _assertImplemented(
            p.afterRemoveLiquidity,
            abi.encodeCall(IHooks.afterRemoveLiquidity, (address(this), k, REMOVE_LIQUIDITY_PARAMS, zero, zero, ""))
        );
        _assertImplemented(p.beforeSwap, abi.encodeCall(IHooks.beforeSwap, (address(this), k, sp, "")));
        _assertImplemented(p.afterSwap, abi.encodeCall(IHooks.afterSwap, (address(this), k, sp, zero, "")));
        _assertImplemented(p.beforeDonate, abi.encodeCall(IHooks.beforeDonate, (address(this), k, 1, 1, "")));
        _assertImplemented(p.afterDonate, abi.encodeCall(IHooks.afterDonate, (address(this), k, 1, 1, "")));
    }

    /// @notice The return-delta flags match what the implementation returns: afterSwap returns a non-zero delta
    /// (the surcharge), while the liquidity callbacks always return a zero delta.
    function test_returnDeltaFlagsMatchBehaviour() public {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.afterSwapReturnDelta, "surcharge needs afterSwapReturnDelta");
        assertFalse(p.beforeSwapReturnDelta, "hook never changes the specified amount");
        assertFalse(p.afterAddLiquidityReturnDelta, "hook never taxes deposits");
        assertFalse(p.afterRemoveLiquidityReturnDelta, "hook never taxes exits");

        // Observe a non-zero afterSwap delta in practice.
        swapExactIn(poolKey, false, 30e18);
        nextBlock();
        SwapObservation memory o = observeSwap(poolKey, true, -10e18);
        assertGt(o.surcharge1, 0, "afterSwap returned a delta");

        // And zero deltas from the liquidity callbacks.
        vm.startPrank(address(manager));
        (, BalanceDelta addDelta) = hook.afterAddLiquidity(
            address(this), poolKey, LIQUIDITY_PARAMS, toBalanceDelta(-1, -1), toBalanceDelta(0, 0), ""
        );
        (, BalanceDelta removeDelta) = hook.afterRemoveLiquidity(
            address(this), poolKey, REMOVE_LIQUIDITY_PARAMS, toBalanceDelta(1, 1), toBalanceDelta(0, 0), ""
        );
        vm.stopPrank();
        assertEq(BalanceDelta.unwrap(addDelta), 0);
        assertEq(BalanceDelta.unwrap(removeDelta), 0);
    }

    /// @notice The CREATE2 address predicted by HookMiner is where the hook lands, and constructing at any address
    /// whose bits differ from the declaration is refused by BaseHook's validation.
    function test_hookMinerPredictionAndValidation() public {
        bytes memory args = abi.encode(manager, owner, defaultConfig());
        (address predicted, bytes32 salt) =
            HookMiner.find(address(this), HOOK_FLAGS, type(VolatilityFeeHook).creationCode, args);
        assertEq(uint160(predicted) & Hooks.ALL_HOOK_MASK, HOOK_FLAGS);
        VolatilityFeeHook second = new VolatilityFeeHook{salt: salt}(manager, owner, defaultConfig());
        assertEq(address(second), predicted);

        // Same bytecode, flags for a different permission set: rejected at construction.
        uint160 wrongFlags = HOOK_FLAGS ^ Hooks.AFTER_DONATE_FLAG;
        (address wrong, bytes32 wrongSalt) =
            HookMiner.find(address(this), wrongFlags, type(VolatilityFeeHook).creationCode, args);
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, wrong));
        new VolatilityFeeHook{salt: wrongSalt}(manager, owner, defaultConfig());
    }

    /// @notice The Angstrom-class bug, reproduced: the implementation returns a surcharge delta from afterSwap but the
    /// declaration (and therefore the address) lacks AFTER_SWAP_RETURNS_DELTA. The PoolManager ignores the returned
    /// delta, the hook's donation is never offset, and every surcharged swap reverts with CurrencyNotSettled. The
    /// permission test above is what prevents shipping this.
    function test_missingReturnDeltaBitBricksSurchargedSwaps() public {
        uint160 flags = HOOK_FLAGS & ~uint160(Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);
        bytes memory args = abi.encode(manager, owner, defaultConfig());
        (, bytes32 salt) = HookMiner.find(address(this), flags, type(MissingReturnDeltaHook).creationCode, args);
        MissingReturnDeltaHook bad = new MissingReturnDeltaHook{salt: salt}(manager, owner, defaultConfig());
        assertFalse(bad.getHookPermissions().afterSwapReturnDelta);

        vm.startPrank(owner);
        bad.setCurrencyAllowed(currency0, true);
        bad.setCurrencyAllowed(currency1, true);
        vm.stopPrank();
        (PoolKey memory k,) =
            initPool(currency0, currency1, IHooks(address(bad)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, SQRT_PRICE_1_1);
        addLiquidity(k, -6000, 6000, 1000e18, 0);

        swapExactIn(k, false, 30e18); // zero surcharge rate in the first block: still works
        nextBlock();
        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        swapExactIn(k, true, 10e18); // surcharged swap: the ignored delta leaves the donation unpaid
    }

    function _assertImplemented(bool permitted, bytes memory callData) internal {
        uint256 snapshot = vm.snapshotState();
        vm.prank(address(manager));
        (bool ok, bytes memory ret) = address(hook).call(callData);
        bool notImplemented = !ok && ret.length >= 4 && bytes4(ret) == BaseHook.HookNotImplemented.selector;
        if (permitted) assertFalse(notImplemented, "permission bit set but callback not implemented");
        else assertTrue(notImplemented, "callback implemented without its permission bit");
        vm.revertToState(snapshot);
    }

    function _freshKey() internal view returns (PoolKey memory k) {
        k = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 1, IHooks(address(hook)));
    }
}
