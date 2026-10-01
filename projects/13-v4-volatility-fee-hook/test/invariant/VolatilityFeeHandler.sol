// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolDonateTest} from "@uniswap/v4-core/src/test/PoolDonateTest.sol";
import {PoolClaimsTest} from "@uniswap/v4-core/src/test/PoolClaimsTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {VolatilityFeeHook} from "../../src/VolatilityFeeHook.sol";
import {IVolatilityFeeHook} from "../../src/interfaces/IVolatilityFeeHook.sol";
import {ILiquidityModule} from "../../src/interfaces/ILiquidityModule.sol";
import {LiquidityTelemetry} from "../../src/modules/LiquidityTelemetry.sol";
import {VolatilityMath} from "../../src/libraries/VolatilityMath.sol";
import {MultiActionRouter} from "../utils/Routers.sol";
import {PositionClaims} from "../utils/PositionClaims.sol";
import {
    RevertingModule,
    GasGuzzlerModule,
    DanglingDeltaModule,
    CountNeutralModule,
    NestedSwapModule,
    SyncHijackModule
} from "../utils/mocks/HostileModules.sol";

/// @notice Stateful handler: random swaps (exact in/out, both directions, settled in ERC-20 or in ERC-6909 claims),
/// same-transaction round trips, liquidity additions and removals (plain, or inside a multi-action unlock that also
/// swaps elsewhere), donations, claim redemptions, block production, module swaps (including hostile modules) and
/// notification deliveries. Every swap is reconciled on the spot against the PoolManager's and the hook's own events;
/// results are kept in ghost variables that the invariant contract checks.
contract VolatilityFeeHandler is Test {
    using StateLibrary for IPoolManager;

    struct Deps {
        IPoolManager manager;
        VolatilityFeeHook hook;
        PoolKey key;
        PoolKey staticKey;
        PoolSwapTest swapRouter;
        PoolModifyLiquidityTest lpRouter;
        PoolDonateTest donateRouter;
        PoolClaimsTest claimsRouter;
        MultiActionRouter multiRouter;
        address owner;
    }

    struct Position {
        address lp;
        address router;
        int24 lower;
        int24 upper;
        bytes32 salt;
        uint128 liquidity;
    }

    struct Pending {
        uint256 id;
        ILiquidityModule module;
        IVolatilityFeeHook.LiquidityNotification notification;
    }

    /// @dev Balances of the settlement kind a swap uses (`moved*`) and of the other kind (`other*`).
    struct Snap {
        uint256 moved0;
        uint256 moved1;
        uint256 other0;
        uint256 other1;
    }

    /// @dev What one swap emitted.
    struct Obs {
        int128 pool0;
        int128 pool1;
        uint24 fee;
        uint256 s0;
        uint256 s1;
        bool opened; // this swap opened a block with a non-zero surcharge rate
    }

    bytes32 internal constant SWAP_TOPIC =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
    bytes32 internal constant DONATE_TOPIC = keccak256("Donate(bytes32,address,uint256,uint256)");
    bytes32 internal constant HOOK_FEE_TOPIC = keccak256("HookFee(bytes32,address,uint128,uint128)");
    bytes32 internal constant VOL_UPDATED_TOPIC =
        keccak256("VolatilityUpdated(bytes32,int24,uint256,uint256,uint256,uint24,uint24)");
    bytes32 internal constant QUEUED_TOPIC = keccak256(
        "LiquidityNotificationQueued(uint256,address,(address,(address,address,uint24,int24,address),(int24,int24,int256,bytes32),int256,int256))"
    );
    bytes32 internal constant DELIVERED_TOPIC = keccak256("LiquidityNotificationDelivered(uint256,address,bool)");
    uint160 internal constant MIN_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 internal constant MAX_LIMIT = TickMath.MAX_SQRT_PRICE - 1;
    uint256 internal constant CLAIM_TOP_UP = 200e18;

    IPoolManager public immutable manager;
    VolatilityFeeHook public immutable hook;
    PoolSwapTest public immutable swapRouter;
    PoolModifyLiquidityTest public immutable lpRouter;
    PoolDonateTest public immutable donateRouter;
    PoolClaimsTest public immutable claimsRouter;
    MultiActionRouter public immutable multiRouter;
    address public immutable owner;
    PoolId public immutable poolId;
    PoolId public immutable staticId;
    PoolKey internal key;
    PoolKey internal staticKey;

    address[] internal actors;
    Position[] internal positions;
    Pending[] internal pending;
    uint256 internal saltNonce;

    // ------------------------------------------------------------------ ghosts: amounts and activity
    uint256 public ghostSurcharge0;
    uint256 public ghostSurcharge1;
    uint256 public ghostDonated0;
    uint256 public ghostDonated1;
    uint256 public ghostSwaps;
    uint256 public ghostClaimSwaps;
    uint256 public ghostSurchargedSwaps;
    uint256 public ghostChargedBlockOpenings;
    uint256 public ghostMaxSample;
    uint256 public ghostRoundTrips;
    uint256 public ghostExits;
    uint256 public ghostMultiActionExits;
    uint256 public ghostDonations;
    uint256 public ghostRedemptions;
    uint256 public ghostDeliveries;
    uint256 public ghostFailedDeliveries;
    uint256 public ghostQueued;

    // ------------------------------------------------------------------ ghosts: violations
    bool public ghostReconciliationFailed;
    bool public ghostFeeOutOfBounds;
    bool public ghostFeeChangedWithinBlock;
    bool public ghostOracleUpdatedTwiceInBlock;
    bool public ghostRoundTripProfit;
    bool public ghostSurchargeExceededOutput;
    bool public ghostSurchargeAboveRate;
    bool public ghostPriceOutsideBlockRange;
    bool public ghostBlockOpeningNotCharged;
    bool public ghostRedeliveryAccepted;
    bool public ghostRedemptionShort;
    uint256 internal lastSwapBlock;
    uint24 internal lastSwapFee;
    uint256 internal lastOracleUpdateBlock;

    constructor(Deps memory d) {
        manager = d.manager;
        hook = d.hook;
        key = d.key;
        staticKey = d.staticKey;
        poolId = d.key.toId();
        staticId = d.staticKey.toId();
        swapRouter = d.swapRouter;
        lpRouter = d.lpRouter;
        donateRouter = d.donateRouter;
        claimsRouter = d.claimsRouter;
        multiRouter = d.multiRouter;
        owner = d.owner;
        for (uint256 i; i < 4; ++i) {
            address a = makeAddr(string.concat("actor", vm.toString(i)));
            actors.push(a);
            _fund(a);
        }
    }

    // ================================================================== actions

    function swap(uint256 actorSeed, bool zeroForOne, bool exactIn, uint256 amount) external {
        address actor = actors[actorSeed % actors.length];
        zeroForOne = _direction(zeroForOne);
        amount = bound(amount, 1, exactIn ? 40e18 : 20e18);
        _observedSwap(actor, zeroForOne, exactIn ? -int256(amount) : int256(amount), _limit(zeroForOne), false);
    }

    /// @dev Same as `swap`, but the input is paid by burning ERC-6909 claims and the output is minted as claims
    /// (how arbitrageurs and aggregators commonly settle on v4). The actor is topped up with claims first.
    function swapWithClaims(uint256 actorSeed, bool zeroForOne, bool exactIn, uint256 amount) external {
        address actor = actors[actorSeed % actors.length];
        zeroForOne = _direction(zeroForOne);
        amount = bound(amount, 1, exactIn ? 40e18 : 20e18);
        Currency input = zeroForOne ? key.currency0 : key.currency1;
        if (manager.balanceOf(actor, input.toId()) < CLAIM_TOP_UP / 2) {
            vm.prank(actor);
            claimsRouter.deposit(input, actor, CLAIM_TOP_UP);
        }
        _observedSwap(actor, zeroForOne, exactIn ? -int256(amount) : int256(amount), _limit(zeroForOne), true);
    }

    /// @dev Sell `amount`, then immediately sell back everything received, in the same transaction. The return leg
    /// has no price limit, so it consumes everything unless the pool runs out of liquidity. The property is "no free
    /// lunch": the trader can never end with at least as much of both tokens and strictly more of one.
    function roundTrip(uint256 actorSeed, bool zeroForOne, uint256 amount) external {
        address actor = actors[actorSeed % actors.length];
        zeroForOne = _direction(zeroForOne);
        amount = bound(amount, 1e6, 30e18);
        (uint256 b0, uint256 b1) = _balances(actor);
        _observedSwap(actor, zeroForOne, -int256(amount), _limit(zeroForOne), false);
        (uint256 m0, uint256 m1) = _balances(actor);
        uint256 received = zeroForOne ? m1 - b1 : m0 - b0;
        if (received > 0 && _canMove(!zeroForOne)) {
            _observedSwap(actor, !zeroForOne, -int256(received), zeroForOne ? MAX_LIMIT : MIN_LIMIT, false);
        }
        (uint256 a0, uint256 a1) = _balances(actor);
        ++ghostRoundTrips;
        if ((a0 > b0 && a1 >= b1) || (a1 > b1 && a0 >= b0)) ghostRoundTripProfit = true;
    }

    /// @dev `viaMultiRouter`: the position is owned by the multi-action router, and its exits share their unlock with
    /// a static-pool swap (the shape of the external review's exit-blocking attack).
    function addLiquidity(uint256 actorSeed, int256 lowerSeed, uint256 width, uint256 liquidity, bool viaMultiRouter)
        external
    {
        address actor = actors[actorSeed % actors.length];
        int24 lower = int24(bound(lowerSeed, -200, 199)) * 60;
        int24 upper = lower + int24(int256(bound(width, 1, 40))) * 60;
        uint128 liq = uint128(bound(liquidity, 1e12, 30e18));
        bytes32 salt = bytes32(++saltNonce);
        address router = viaMultiRouter ? address(multiRouter) : address(lpRouter);
        vm.recordLogs();
        _modify(actor, router, _params(lower, upper, int256(uint256(liq)), salt), false);
        _collectQueued(vm.getRecordedLogs());
        positions.push(Position(actor, router, lower, upper, salt, liq));
    }

    /// @dev Removal must never revert, whatever module is installed and whatever else shares the unlock:
    /// fail_on_revert makes "exit always works" a stateful property of the whole campaign.
    function removeLiquidity(uint256 positionSeed, uint256 fraction, bool withStaticSwap) external {
        if (positions.length == 0) return;
        uint256 i = positionSeed % positions.length;
        Position storage p = positions[i];
        uint128 amount = uint128(bound(fraction, 1, 100) * uint256(p.liquidity) / 100);
        if (amount == 0) amount = p.liquidity;
        bool multi = p.router == address(multiRouter);
        vm.recordLogs();
        _modify(p.lp, p.router, _params(p.lower, p.upper, -int256(uint256(amount)), p.salt), multi && withStaticSwap);
        _collectQueued(vm.getRecordedLogs());
        p.liquidity -= amount;
        ++ghostExits;
        if (multi && withStaticSwap) ++ghostMultiActionExits;
        if (p.liquidity == 0) {
            positions[i] = positions[positions.length - 1];
            positions.pop();
        }
    }

    function donate(uint256 actorSeed, uint256 amount0, uint256 amount1) external {
        if (manager.getLiquidity(poolId) == 0) return;
        address actor = actors[actorSeed % actors.length];
        vm.prank(actor);
        donateRouter.donate(key, bound(amount0, 0, 1e18), bound(amount1, 0, 1e18), "");
        ++ghostDonations;
    }

    /// @dev Claims are always redeemable one-for-one: redeeming never reverts and pays exactly the amount burned.
    function redeemClaims(uint256 actorSeed, bool currency0, uint256 fraction) external {
        address actor = actors[actorSeed % actors.length];
        Currency c = currency0 ? key.currency0 : key.currency1;
        uint256 amount = manager.balanceOf(actor, c.toId()) * bound(fraction, 1, 100) / 100;
        if (amount == 0) return;
        uint256 before = c.balanceOf(actor);
        vm.prank(actor);
        claimsRouter.withdraw(c, actor, amount);
        if (c.balanceOf(actor) - before != amount) ghostRedemptionShort = true;
        ++ghostRedemptions;
    }

    function rollBlocks(uint256 blocks) external {
        blocks = blocks % 10 == 0 ? bound(blocks, 100, 100_000) : bound(blocks, 1, 5);
        vm.roll(vm.getBlockNumber() + blocks);
    }

    function setModule(uint256 kind) external {
        ILiquidityModule m;
        kind %= 8;
        if (kind == 1) m = new LiquidityTelemetry(address(hook));
        else if (kind == 2) m = new RevertingModule();
        else if (kind == 3) m = new GasGuzzlerModule();
        else if (kind == 4) m = new DanglingDeltaModule(manager, key.currency0);
        else if (kind == 5) m = _countNeutralModule();
        else if (kind == 6) m = new NestedSwapModule(manager);
        else if (kind == 7) m = new SyncHijackModule(manager, key.currency1);
        vm.prank(owner);
        hook.setLiquidityModule(m);
    }

    /// @dev Delivery never reverts for a queued notification (whatever the module does), and a notification can never
    /// be delivered twice.
    function deliverNotification(uint256 seed) external {
        if (pending.length == 0) return;
        uint256 i = seed % pending.length;
        Pending memory n = pending[i];
        pending[i] = pending[pending.length - 1];
        pending.pop();
        if (_deliver(n)) ++ghostDeliveries;
        else ++ghostFailedDeliveries;
        try hook.deliverNotification(n.id, n.module, n.notification) {
            ghostRedeliveryAccepted = true;
        } catch {}
    }

    // ================================================================== views and helpers for the invariant contract

    function positionCount() external view returns (uint256) {
        return positions.length;
    }

    function positionAt(uint256 i) external view returns (Position memory) {
        return positions[i];
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function actorAt(uint256 i) external view returns (address) {
        return actors[i];
    }

    function registerPosition(Position calldata p) external {
        positions.push(p);
    }

    function poolKey() external view returns (PoolKey memory) {
        return key;
    }

    /// @notice Everything the PoolManager owes, computed from its state without withdrawing anything: every tracked
    /// hook-pool position, the static pool's LP position, and every actor's ERC-6909 claims.
    function outstandingClaims(address staticLpRouter) external view returns (uint256 owed0, uint256 owed1) {
        for (uint256 i; i < positions.length; ++i) {
            Position memory p = positions[i];
            (uint256 a0, uint256 a1) = PositionClaims.claimOf(manager, poolId, p.router, p.lower, p.upper, p.salt);
            owed0 += a0;
            owed1 += a1;
        }
        (uint256 s0, uint256 s1) = PositionClaims.claimOf(manager, staticId, staticLpRouter, -6000, 6000, bytes32(0));
        owed0 += s0;
        owed1 += s1;
        for (uint256 i; i < actors.length; ++i) {
            owed0 += manager.balanceOf(actors[i], key.currency0.toId());
            owed1 += manager.balanceOf(actors[i], key.currency1.toId());
        }
    }

    /// @notice Delivers every pending notification (used at the end of a run). Never reverts.
    function deliverAll() external {
        while (pending.length > 0) {
            Pending memory n = pending[pending.length - 1];
            pending.pop();
            if (_deliver(n)) ++ghostDeliveries;
            else ++ghostFailedDeliveries;
        }
    }

    /// @notice Removes a whole position through its own router on behalf of its LP (used at the end of a run).
    function exitPosition(Position calldata p) external {
        vm.recordLogs();
        _modify(p.lp, p.router, _params(p.lower, p.upper, -int256(uint256(p.liquidity)), p.salt), false);
        _collectQueued(vm.getRecordedLogs());
    }

    // ================================================================== internals

    /// @dev `limit` must be computed by the caller: computing it here, between vm.prank and the swap, would make an
    /// external call that consumes the prank.
    function _observedSwap(address actor, bool zeroForOne, int256 amountSpecified, uint160 limit, bool withClaims)
        internal
    {
        Snap memory before_ = _snap(actor, withClaims);
        vm.recordLogs();
        vm.prank(actor);
        swapRouter.swap(
            key, SwapParams(zeroForOne, amountSpecified, limit), PoolSwapTest.TestSettings(withClaims, withClaims), ""
        );
        Obs memory o = _decode(vm.getRecordedLogs());
        Snap memory after_ = _snap(actor, withClaims);
        ++ghostSwaps;
        if (withClaims) ++ghostClaimSwaps;
        if (o.s0 + o.s1 > 0) ++ghostSurchargedSwaps;

        // No output without a matching charge: the actor's balances (ERC-20 or claims, whichever the swap settles in)
        // move by exactly the pool's swap delta minus the hook's surcharge, and the other kind does not move at all.
        if (int256(after_.moved0) - int256(before_.moved0) != int256(o.pool0) - int256(o.s0)) {
            ghostReconciliationFailed = true;
        }
        if (int256(after_.moved1) - int256(before_.moved1) != int256(o.pool1) - int256(o.s1)) {
            ghostReconciliationFailed = true;
        }
        if (after_.other0 != before_.other0 || after_.other1 != before_.other1) ghostReconciliationFailed = true;
        // The surcharge never exceeds the unspecified amount it is charged on.
        if (o.s0 > _abs(o.pool0) || o.s1 > _abs(o.pool1)) ghostSurchargeExceededOutput = true;

        if (o.fee < hook.MIN_FEE_PIPS() || o.fee > hook.MAX_FEE_PIPS()) ghostFeeOutOfBounds = true;
        if (lastSwapBlock == block.number && o.fee != lastSwapFee) ghostFeeChangedWithinBlock = true;
        lastSwapBlock = block.number;
        lastSwapFee = o.fee;

        _checkRange(o);
    }

    /// @dev Price-range checks (I-9): inside a surcharged block the price never leaves [low, high]; no swap pays more
    /// than the full rate on its unspecified amount; and the swap that opens a surcharged block (which starts on the
    /// range edge) is charged whenever it moved an amount and left liquidity in range to donate to.
    function _checkRange(Obs memory o) internal {
        IVolatilityFeeHook.PoolState memory s = hook.getPoolState(poolId);
        if (s.surchargePips == 0) return;
        (uint160 price,,,) = manager.getSlot0(poolId);
        if (price < s.lowSqrtPriceX96 || price > s.highSqrtPriceX96) ghostPriceOutsideBlockRange = true;
        uint256 charged = o.s0 + o.s1;
        uint256 base = o.s0 > 0 ? _abs(o.pool0) : _abs(o.pool1);
        if (charged > VolatilityMath.surchargeAmount(base, s.surchargePips)) ghostSurchargeAboveRate = true;
        if (o.opened && o.pool0 != 0 && o.pool1 != 0 && manager.getLiquidity(poolId) > 0) {
            if (charged == 0) ghostBlockOpeningNotCharged = true;
            else ++ghostChargedBlockOpenings;
        }
    }

    function _decode(Vm.Log[] memory logs) internal returns (Obs memory o) {
        uint256 d0;
        uint256 d1;
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory l = logs[i];
            if (l.emitter == address(manager) && l.topics[0] == SWAP_TOPIC) {
                (o.pool0, o.pool1,,,, o.fee) = abi.decode(l.data, (int128, int128, uint160, uint128, int24, uint24));
            } else if (
                l.emitter == address(manager) && l.topics[0] == DONATE_TOPIC
                    && address(uint160(uint256(l.topics[2]))) == address(hook)
            ) {
                (uint256 x0, uint256 x1) = abi.decode(l.data, (uint256, uint256));
                d0 += x0;
                d1 += x1;
            } else if (l.emitter == address(hook) && l.topics[0] == HOOK_FEE_TOPIC) {
                (uint128 x0, uint128 x1) = abi.decode(l.data, (uint128, uint128));
                o.s0 += x0;
                o.s1 += x1;
            } else if (l.emitter == address(hook) && l.topics[0] == VOL_UPDATED_TOPIC) {
                (, uint256 sample,,,, uint24 surchargePips) =
                    abi.decode(l.data, (int24, uint256, uint256, uint256, uint24, uint24));
                if (sample > ghostMaxSample) ghostMaxSample = sample;
                if (lastOracleUpdateBlock == block.number) ghostOracleUpdatedTwiceInBlock = true;
                lastOracleUpdateBlock = block.number;
                o.opened = surchargePips > 0;
            }
        }
        ghostSurcharge0 += o.s0;
        ghostSurcharge1 += o.s1;
        ghostDonated0 += d0;
        ghostDonated1 += d1;
    }

    function _snap(address actor, bool withClaims) internal view returns (Snap memory x) {
        (uint256 e0, uint256 e1) = _balances(actor);
        (uint256 c0, uint256 c1) = _claims(actor);
        x = withClaims ? Snap(c0, c1, e0, e1) : Snap(e0, e1, c0, c1);
    }

    function _modify(address lp, address router, ModifyLiquidityParams memory p, bool withStaticSwap) internal {
        vm.prank(lp);
        if (router == address(multiRouter)) multiRouter.run(staticKey, withStaticSwap, key, p);
        else lpRouter.modifyLiquidity(key, p, "");
    }

    function _collectQueued(Vm.Log[] memory logs) internal {
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory l = logs[i];
            if (l.emitter != address(hook) || l.topics[0] != QUEUED_TOPIC) continue;
            ++ghostQueued;
            pending.push(
                Pending({
                    id: uint256(l.topics[1]),
                    module: ILiquidityModule(address(uint160(uint256(l.topics[2])))),
                    notification: abi.decode(l.data, (IVolatilityFeeHook.LiquidityNotification))
                })
            );
        }
    }

    function _deliver(Pending memory n) internal returns (bool success) {
        vm.recordLogs();
        hook.deliverNotification(n.id, n.module, n.notification);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == DELIVERED_TOPIC) {
                success = abi.decode(logs[i].data, (bool));
            }
        }
    }

    function _countNeutralModule() internal returns (ILiquidityModule m) {
        m = new CountNeutralModule(manager, address(multiRouter));
        MockERC20(Currency.unwrap(key.currency0)).mint(address(m), 1e24);
    }

    /// @dev Keeps the random walk mostly inside the liquid region: past +/-5,000 ticks, trade back toward zero.
    function _direction(bool requested) internal view returns (bool zeroForOne) {
        (, int24 tick,,) = manager.getSlot0(poolId);
        if (tick > 5000) return true;
        if (tick < -5000) return false;
        zeroForOne = _canMove(requested) ? requested : !requested;
    }

    /// @dev Price limit 3,000 ticks away from the current tick (clamped to the global bounds), so one swap cannot run
    /// the price to the edge of the tick range.
    function _limit(bool zeroForOne) internal view returns (uint160) {
        (, int24 tick,,) = manager.getSlot0(poolId);
        if (zeroForOne) {
            int24 t = tick - 3000 < TickMath.MIN_TICK ? TickMath.MIN_TICK : tick - 3000;
            uint160 l = TickMath.getSqrtPriceAtTick(t);
            return l <= MIN_LIMIT ? MIN_LIMIT : l;
        }
        int24 u = tick + 3000 > TickMath.MAX_TICK ? TickMath.MAX_TICK : tick + 3000;
        uint160 lu = TickMath.getSqrtPriceAtTick(u);
        return lu >= MAX_LIMIT ? MAX_LIMIT : lu;
    }

    function _canMove(bool zeroForOne) internal view returns (bool) {
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(poolId);
        return zeroForOne ? sqrtPriceX96 > MIN_LIMIT : sqrtPriceX96 < MAX_LIMIT;
    }

    function _params(int24 lower, int24 upper, int256 delta, bytes32 salt)
        internal
        pure
        returns (ModifyLiquidityParams memory)
    {
        return ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: delta, salt: salt});
    }

    function _balances(address a) internal view returns (uint256, uint256) {
        return (key.currency0.balanceOf(a), key.currency1.balanceOf(a));
    }

    function _claims(address a) internal view returns (uint256, uint256) {
        return (manager.balanceOf(a, key.currency0.toId()), manager.balanceOf(a, key.currency1.toId()));
    }

    function _fund(address a) internal {
        MockERC20 t0 = MockERC20(Currency.unwrap(key.currency0));
        MockERC20 t1 = MockERC20(Currency.unwrap(key.currency1));
        t0.mint(a, 1e30);
        t1.mint(a, 1e30);
        address[5] memory spenders = [
            address(swapRouter), address(lpRouter), address(donateRouter), address(claimsRouter), address(multiRouter)
        ];
        vm.startPrank(a);
        for (uint256 i; i < spenders.length; ++i) {
            t0.approve(spenders[i], type(uint256).max);
            t1.approve(spenders[i], type(uint256).max);
        }
        // ERC-6909: the swap router burns claims to settle, the claims router burns them to redeem.
        manager.setOperator(address(swapRouter), true);
        manager.setOperator(address(claimsRouter), true);
        vm.stopPrank();
    }

    function _abs(int128 x) internal pure returns (uint256) {
        return x >= 0 ? uint256(int256(x)) : uint256(-int256(x));
    }
}
