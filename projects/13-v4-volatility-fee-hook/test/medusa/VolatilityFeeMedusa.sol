// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/utils/CurrencySettler.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {VolatilityFeeHook} from "../../src/VolatilityFeeHook.sol";
import {IVolatilityFeeHook} from "../../src/interfaces/IVolatilityFeeHook.sol";
import {ILiquidityModule} from "../../src/interfaces/ILiquidityModule.sol";
import {LiquidityTelemetry} from "../../src/modules/LiquidityTelemetry.sol";
import {PositionClaims} from "../utils/PositionClaims.sol";
import {
    RevertingModule,
    GasGuzzlerModule,
    DanglingDeltaModule,
    CountNeutralModule,
    NestedSwapModule
} from "../utils/mocks/HostileModules.sol";

/// @dev Minimal HEVM cheat-code interface (supported by Medusa).
interface IHevm {
    function roll(uint256 blockNumber) external;
}

/// @notice Medusa harness. The harness deploys a PoolManager, two tokens, the hook (at a CREATE2 address mined in
/// the constructor) and a dynamic-fee pool, then acts as trader, LP, donor, claim holder and keeper through its own
/// unlock callback. Medusa calls the public actions in random order and blocks; it checks the `property_*` functions
/// after every call and treats any failing `assert` as a bug.
///
/// Properties (mirroring the Foundry invariants):
///   - the hook holds no ERC-20, ETH or ERC-6909 claims, and has no open PoolManager delta after any swap;
///   - swap accounting: output is never received without paying input, and a same-transaction round trip never
///     leaves the trader with at least as much of both tokens and more of one;
///   - the LP fee the PoolManager actually APPLIED (measured from the fee growth it credited to every position) is
///     the fee `quoteFees` announced, lies within [5, 100] bps, and is the same for every swap in a block;
///   - the EWMA never exceeds the largest per-block tick move observed, and in a surcharged block the price stays
///     inside the block's range [low, high];
///   - the PoolManager's ERC-20 balances cover every position's computed claim plus every ERC-6909 claim;
///   - every liquidity removal succeeds whatever module is installed; every queued notification can be delivered,
///     and none can be delivered twice.
contract VolatilityFeeMedusa is IUnlockCallback {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using CurrencySettler for Currency;

    IHevm internal constant HEVM = IHevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
    uint160 internal constant FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );
    uint160 internal constant MIN_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 internal constant MAX_LIMIT = TickMath.MAX_SQRT_PRICE - 1;
    uint128 internal constant BASE_LIQUIDITY = 1000e18;
    uint256 internal constant Q128 = 1 << 128;
    /// @dev Below this gross input the applied fee is not measured (one pip must dwarf the rounding of the probe).
    uint256 internal constant FEE_PROBE_MIN_INPUT = 1e15;

    enum Op {
        Swap,
        SwapClaims,
        Modify,
        Donate,
        Redeem
    }

    struct Position {
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

    IPoolManager public immutable manager;
    VolatilityFeeHook public immutable hook;
    Currency public immutable currency0;
    Currency public immutable currency1;
    PoolKey internal key;
    PoolId internal poolId;

    Position[] internal positions;
    Pending[] internal pending;
    uint256 internal saltNonce;
    bool internal baseLiquidityAdded;

    uint256 internal maxObservedSample;
    uint256 internal lastMeasuredBlock;
    uint24 internal lastMeasuredFee;
    bool internal feeChangedWithinBlock;
    bool internal appliedFeeDiffersFromQuote;
    bool internal appliedFeeOutOfBounds;

    constructor() {
        manager = new PoolManager(address(this));
        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        (MockERC20 t0, MockERC20 t1) = address(a) < address(b) ? (a, b) : (b, a);
        t0.mint(address(this), 1e36);
        t1.mint(address(this), 1e36);
        currency0 = Currency.wrap(address(t0));
        currency1 = Currency.wrap(address(t1));

        IVolatilityFeeHook.FeeConfig memory config = IVolatilityFeeHook.FeeConfig({
            alphaWad: 0.1e18, feeSlopePips: 500, surchargeSlopePips: 250, maxSurchargePips: 5000
        });
        bytes memory initCode =
            abi.encodePacked(type(VolatilityFeeHook).creationCode, abi.encode(manager, address(this), config));
        bytes32 salt = _mineSalt(keccak256(initCode));
        hook = new VolatilityFeeHook{salt: salt}(manager, address(this), config);

        hook.setCurrencyAllowed(currency0, true);
        hook.setCurrencyAllowed(currency1, true);
        key = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(address(hook)));
        poolId = key.toId();
        manager.initialize(key, uint160(1) << 96);
        // Base liquidity is added lazily by the first action: the PoolManager's unlock callback cannot reach this
        // contract while its constructor is still running (it has no code yet).
    }

    /// @dev Adds the base position on first use.
    modifier seeded() {
        if (!baseLiquidityAdded) {
            baseLiquidityAdded = true;
            _modify(-6000, 6000, int256(uint256(BASE_LIQUIDITY)), bytes32(0));
            positions.push(Position(-6000, 6000, bytes32(0), BASE_LIQUIDITY));
        }
        _;
    }

    // =========================================================================================== actions

    function swap(uint256 amount, bool zeroForOne, bool exactIn) public seeded {
        zeroForOne = _direction(zeroForOne);
        amount = 1 + (amount % (exactIn ? 40e18 : 20e18));
        _swapAndCheck(zeroForOne, exactIn ? -int256(amount) : int256(amount), _limit(zeroForOne), false);
    }

    /// @dev Exact-input swap settled in ERC-6909 claims: the input is paid by burning claims when the harness holds
    /// enough (ERC-20 otherwise), and the output is minted as claims.
    function swapWithClaims(uint256 amount, bool zeroForOne) public seeded {
        zeroForOne = _direction(zeroForOne);
        amount = 1 + (amount % 40e18);
        _swapAndCheck(zeroForOne, -int256(amount), _limit(zeroForOne), true);
    }

    function roundTrip(uint256 amount, bool zeroForOne) public seeded {
        zeroForOne = _direction(zeroForOne);
        amount = 1e6 + (amount % 30e18);
        (uint256 b0, uint256 b1) = _balances();
        _swapAndCheck(zeroForOne, -int256(amount), _limit(zeroForOne), false);
        (uint256 m0, uint256 m1) = _balances();
        uint256 received = zeroForOne ? m1 - b1 : m0 - b0;
        if (received > 0 && _canMove(!zeroForOne)) {
            _swapAndCheck(!zeroForOne, -int256(received), zeroForOne ? MAX_LIMIT : MIN_LIMIT, false);
        }
        (uint256 a0, uint256 a1) = _balances();
        assert(!((a0 > b0 && a1 >= b1) || (a1 > b1 && a0 >= b0)));
    }

    function addLiquidity(int256 lowerSeed, uint256 width, uint256 liquidity) public seeded {
        int24 lower = int24((lowerSeed % 200)) * 60;
        int24 upper = lower + int24(int256(1 + width % 40)) * 60;
        uint128 liq = uint128(1e12 + liquidity % 30e18);
        bytes32 salt = bytes32(++saltNonce);
        _modify(lower, upper, int256(uint256(liq)), salt);
        positions.push(Position(lower, upper, salt, liq));
    }

    /// @dev Exit always works: a removal that reverts is a property violation.
    function removeLiquidity(uint256 seed, uint256 percent) public seeded {
        if (positions.length == 0) return;
        uint256 i = seed % positions.length;
        Position storage p = positions[i];
        uint128 amount = uint128((1 + percent % 100) * uint256(p.liquidity) / 100);
        if (amount == 0) amount = p.liquidity;
        try this.modifyExternal(p.lower, p.upper, -int256(uint256(amount)), p.salt) {}
        catch {
            assert(false);
        }
        p.liquidity -= amount;
        if (p.liquidity == 0) {
            positions[i] = positions[positions.length - 1];
            positions.pop();
        }
    }

    function setModule(uint256 kind) public {
        ILiquidityModule m;
        kind %= 7;
        if (kind == 1) m = new LiquidityTelemetry(address(hook));
        else if (kind == 2) m = new RevertingModule();
        else if (kind == 3) m = new GasGuzzlerModule();
        else if (kind == 4) m = new DanglingDeltaModule(manager, currency0);
        else if (kind == 5) m = _countNeutralModule();
        else if (kind == 6) m = new NestedSwapModule(manager);
        hook.setLiquidityModule(m);
    }

    /// @dev Delivers a pending notification: it must never revert, and delivering it again must.
    function deliverNotification(uint256 seed) public {
        if (pending.length == 0) return;
        uint256 i = seed % pending.length;
        Pending memory n = pending[i];
        pending[i] = pending[pending.length - 1];
        pending.pop();
        try hook.deliverNotification(n.id, n.module, n.notification) {}
        catch {
            assert(false);
        }
        try hook.deliverNotification(n.id, n.module, n.notification) {
            assert(false);
        } catch {}
    }

    /// @dev Direct donations to in-range LPs (skipped when no liquidity is in range, where donate() would revert).
    function donate(uint256 amount0, uint256 amount1) public seeded {
        if (manager.getLiquidity(poolId) == 0) return;
        manager.unlock(abi.encode(Op.Donate, abi.encode(amount0 % 1e18, amount1 % 1e18)));
    }

    /// @dev Burns ERC-6909 claims for ERC-20: always pays one for one.
    function redeemClaims(bool zeroSide, uint256 percent) public {
        Currency c = zeroSide ? currency0 : currency1;
        uint256 amount = manager.balanceOf(address(this), c.toId()) * (1 + percent % 100) / 100;
        if (amount == 0) return;
        uint256 before = c.balanceOf(address(this));
        manager.unlock(abi.encode(Op.Redeem, abi.encode(c, amount)));
        assert(c.balanceOf(address(this)) - before == amount);
    }

    function advanceBlocks(uint256 blocks) public {
        HEVM.roll(block.number + 1 + blocks % 20);
    }

    /// @dev Entry point used by removeLiquidity so that a revert can be caught (only callable by this contract).
    function modifyExternal(int24 lower, int24 upper, int256 delta, bytes32 salt) external {
        require(msg.sender == address(this), "self only");
        _modify(lower, upper, delta, salt);
    }

    // =========================================================================================== properties

    function property_hookHoldsNoValue() public view returns (bool) {
        return currency0.balanceOf(address(hook)) == 0 && currency1.balanceOf(address(hook)) == 0
            && address(hook).balance == 0 && manager.balanceOf(address(hook), currency0.toId()) == 0
            && manager.balanceOf(address(hook), currency1.toId()) == 0;
    }

    /// @notice The fee the PoolManager applied is the announced fee and stays within [5, 100] bps; the stored rate
    /// stays within its cap.
    function property_feeWithinBounds() public view returns (bool) {
        IVolatilityFeeHook.PoolState memory s = hook.getPoolState(poolId);
        return !appliedFeeOutOfBounds && !appliedFeeDiffersFromQuote && s.surchargePips <= hook.maxSurchargePips();
    }

    /// @notice Every swap in a block pays the same applied fee (measured, not read from the hook's storage).
    function property_feeConstantWithinBlock() public view returns (bool) {
        return !feeChangedWithinBlock;
    }

    /// @notice The EWMA never exceeds the largest per-block tick move the harness observed, and in a surcharged block
    /// the pool price stays inside the block's range.
    function property_oracleConsistent() public view returns (bool) {
        IVolatilityFeeHook.PoolState memory s = hook.getPoolState(poolId);
        if (s.ewmaWad > maxObservedSample * 1e18) return false;
        if (s.anchorBlock == block.number && s.surchargePips != 0) {
            (uint160 price,,,) = manager.getSlot0(poolId);
            if (price < s.lowSqrtPriceX96 || price > s.highSqrtPriceX96) return false;
        }
        return true;
    }

    /// @notice The PoolManager's ERC-20 balances cover every position's claim (computed from its state) plus every
    /// ERC-6909 claim.
    function property_poolManagerSolvent() public view returns (bool) {
        uint256 owed0 = manager.balanceOf(address(this), currency0.toId());
        uint256 owed1 = manager.balanceOf(address(this), currency1.toId());
        for (uint256 i; i < positions.length; ++i) {
            Position memory p = positions[i];
            (uint256 a0, uint256 a1) = PositionClaims.claimOf(manager, poolId, address(this), p.lower, p.upper, p.salt);
            owed0 += a0;
            owed1 += a1;
        }
        return currency0.balanceOf(address(manager)) >= owed0 && currency1.balanceOf(address(manager)) >= owed1;
    }

    // =========================================================================================== unlock callback

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager only");
        (Op op, bytes memory args) = abi.decode(data, (Op, bytes));
        bool claims;
        if (op == Op.Swap || op == Op.SwapClaims) {
            claims = op == Op.SwapClaims;
            SwapParams memory params = abi.decode(args, (SwapParams));
            BalanceDelta d = manager.swap(key, params, "");
            // The hook must have settled whatever it took (donated) before the swap returned.
            assert(manager.currencyDelta(address(hook), currency0) == 0);
            assert(manager.currencyDelta(address(hook), currency1) == 0);
            // No output without a matching charge.
            if (d.amount0() > 0) assert(d.amount1() < 0);
            if (d.amount1() > 0) assert(d.amount0() < 0);
        } else if (op == Op.Modify) {
            ModifyLiquidityParams memory params = abi.decode(args, (ModifyLiquidityParams));
            uint256 queuedBefore = hook.notificationCount();
            (BalanceDelta callerDelta, BalanceDelta feesAccrued) = manager.modifyLiquidity(key, params, "");
            if (hook.notificationCount() > queuedBefore) {
                pending.push(
                    Pending(
                        queuedBefore,
                        hook.liquidityModule(),
                        IVolatilityFeeHook.LiquidityNotification(address(this), key, params, callerDelta, feesAccrued)
                    )
                );
            }
        } else if (op == Op.Donate) {
            (uint256 amount0, uint256 amount1) = abi.decode(args, (uint256, uint256));
            manager.donate(key, amount0, amount1, "");
        } else {
            (Currency c, uint256 amount) = abi.decode(args, (Currency, uint256));
            manager.burn(address(this), c.toId(), amount);
            manager.take(c, address(this), amount);
        }
        _settle(currency0, claims);
        _settle(currency1, claims);
        return "";
    }

    // =========================================================================================== internals

    /// @dev Swaps and checks the fee the PoolManager applied. For exact-input swaps the LP fee accrues in the input
    /// currency and nothing else does (the surcharge is taken from the output), so the fee growth credited to all
    /// positions, times their liquidity, is the fee paid; divided by the gross input it gives the applied rate.
    function _swapAndCheck(bool zeroForOne, int256 amountSpecified, uint160 limit, bool claims) internal {
        _recordSample();
        Probe memory probe = _probe(zeroForOne);
        manager.unlock(
            abi.encode(claims ? Op.SwapClaims : Op.Swap, abi.encode(SwapParams(zeroForOne, amountSpecified, limit)))
        );
        if (amountSpecified < 0) _checkAppliedFee(probe, zeroForOne);
    }

    /// @dev State needed to measure the fee a swap is about to pay.
    struct Probe {
        uint24 quoted;
        uint256[] growth;
        uint256 erc20In;
        uint256 claimsIn;
    }

    /// @dev The hook samples |tick - anchorTick| at the first swap of each block; the harness tracks the largest.
    function _recordSample() internal {
        IVolatilityFeeHook.PoolState memory s = hook.getPoolState(poolId);
        if (block.number <= s.anchorBlock) return;
        (, int24 tick,,) = manager.getSlot0(poolId);
        int256 move = int256(tick) - int256(s.anchorTick);
        uint256 sample = uint256(move >= 0 ? move : -move);
        if (sample > maxObservedSample) maxObservedSample = sample;
    }

    function _probe(bool zeroForOne) internal view returns (Probe memory p) {
        (p.quoted,,,) = hook.quoteFees(key);
        p.growth = _feeGrowthInside(zeroForOne);
        Currency input = zeroForOne ? currency0 : currency1;
        p.erc20In = input.balanceOf(address(this));
        p.claimsIn = manager.balanceOf(address(this), input.toId());
    }

    function _checkAppliedFee(Probe memory p, bool zeroForOne) internal {
        Currency input = zeroForOne ? currency0 : currency1;
        uint256 erc20Now = input.balanceOf(address(this));
        uint256 claimsNow = manager.balanceOf(address(this), input.toId());
        // Gross input paid: ERC-20 sent plus claims burned (an exact-input swap never credits its input currency).
        uint256 grossIn = (p.erc20In - erc20Now) + (p.claimsIn > claimsNow ? p.claimsIn - claimsNow : 0);
        if (grossIn < FEE_PROBE_MIN_INPUT) return;
        uint256 applied = (_feesSince(p.growth, zeroForOne) * 1e6 + grossIn / 2) / grossIn;
        if (applied < hook.MIN_FEE_PIPS() || applied > hook.MAX_FEE_PIPS()) appliedFeeOutOfBounds = true;
        if (applied != p.quoted) appliedFeeDiffersFromQuote = true;
        if (lastMeasuredBlock == block.number && applied != lastMeasuredFee) feeChangedWithinBlock = true;
        lastMeasuredBlock = block.number;
        lastMeasuredFee = uint24(applied);
    }

    function _feeGrowthInside(bool currency0Side) internal view returns (uint256[] memory g) {
        g = new uint256[](positions.length);
        for (uint256 i; i < positions.length; ++i) {
            (uint256 g0, uint256 g1) = manager.getFeeGrowthInside(poolId, positions[i].lower, positions[i].upper);
            g[i] = currency0Side ? g0 : g1;
        }
    }

    function _feesSince(uint256[] memory before, bool currency0Side) internal view returns (uint256 fees) {
        for (uint256 i; i < before.length; ++i) {
            (uint256 g0, uint256 g1) = manager.getFeeGrowthInside(poolId, positions[i].lower, positions[i].upper);
            // Fee growth is a wrapping accumulator in v4-core.
            unchecked {
                fees += FullMath.mulDiv((currency0Side ? g0 : g1) - before[i], positions[i].liquidity, Q128);
            }
        }
    }

    function _modify(int24 lower, int24 upper, int256 delta, bytes32 salt) internal {
        manager.unlock(abi.encode(Op.Modify, abi.encode(ModifyLiquidityParams(lower, upper, delta, salt))));
    }

    /// @dev Settles this contract's open delta: debts by burning claims (claim swaps, when enough are held) or by
    /// ERC-20 transfer; credits as minted claims (claim swaps) or ERC-20.
    function _settle(Currency currency, bool claims) internal {
        int256 delta = manager.currencyDelta(address(this), currency);
        if (delta < 0) {
            uint256 owed = uint256(-delta);
            bool burn = claims && manager.balanceOf(address(this), currency.toId()) >= owed;
            currency.settle(manager, address(this), owed, burn);
        } else if (delta > 0) {
            currency.take(manager, address(this), uint256(delta), claims);
        }
    }

    function _countNeutralModule() internal returns (ILiquidityModule m) {
        m = new CountNeutralModule(manager, address(this));
        MockERC20(Currency.unwrap(currency0)).transfer(address(m), 1e24);
    }

    function _direction(bool requested) internal view returns (bool) {
        (, int24 tick,,) = manager.getSlot0(poolId);
        if (tick > 5000) return true;
        if (tick < -5000) return false;
        return _canMove(requested) ? requested : !requested;
    }

    function _limit(bool zeroForOne) internal view returns (uint160) {
        (, int24 tick,,) = manager.getSlot0(poolId);
        if (zeroForOne) {
            int24 t = tick - 3000 < TickMath.MIN_TICK ? TickMath.MIN_TICK : tick - 3000;
            uint160 l = TickMath.getSqrtPriceAtTick(t);
            return l <= MIN_LIMIT ? MIN_LIMIT : l;
        }
        int24 u = tick + 3000 > TickMath.MAX_TICK ? TickMath.MAX_TICK : tick + 3000;
        uint160 h = TickMath.getSqrtPriceAtTick(u);
        return h >= MAX_LIMIT ? MAX_LIMIT : h;
    }

    function _canMove(bool zeroForOne) internal view returns (bool) {
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(poolId);
        return zeroForOne ? sqrtPriceX96 > MIN_LIMIT : sqrtPriceX96 < MAX_LIMIT;
    }

    function _balances() internal view returns (uint256, uint256) {
        return (currency0.balanceOf(address(this)), currency1.balanceOf(address(this)));
    }

    /// @dev CREATE2 salt search for an address whose low 14 bits equal FLAGS. Same result as periphery's HookMiner
    /// but without its per-iteration EXTCODESIZE and memory growth, so it fits in one deployment transaction.
    function _mineSalt(bytes32 initCodeHash) internal view returns (bytes32 salt) {
        bool found;
        uint256 flags = FLAGS;
        // Builds 0xff ++ deployer ++ salt ++ initCodeHash (85 bytes) once in scratch memory past the free-memory
        // pointer and only rewrites the 32-byte salt each iteration; nothing is read back after the block, so the
        // free-memory pointer does not need to move.
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore8(ptr, 0xff)
            mstore(add(ptr, 1), shl(96, address()))
            mstore(add(ptr, 53), initCodeHash)
            for { let i := 0 } lt(i, 1000000) { i := add(i, 1) } {
                mstore(add(ptr, 21), i)
                if eq(and(keccak256(ptr, 85), 0x3fff), flags) {
                    salt := i
                    found := 1
                    break
                }
            }
        }
        require(found, "no salt");
    }
}
