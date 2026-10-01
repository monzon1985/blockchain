// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.37;

import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {ERC20} from "solady/tokens/ERC20.sol";

import {AMMFactory} from "../../src/AMMFactory.sol";
import {AMMPair} from "../../src/AMMPair.sol";
import {AMMRouter} from "../../src/AMMRouter.sol";
import {IAMMPair} from "../../src/interfaces/IAMMPair.sol";
import {AMMLibrary} from "../../src/libraries/AMMLibrary.sol";
import {FlashBorrower} from "../mocks/Callees.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice The system under stateful test, shared by the Foundry invariant suite (AMMHandler) and the Medusa
///         harness (AMMMedusa): three tokens, the three pairs between them, the router, three LPs/traders and a
///         flash borrower.
/// @dev Three layers of checking:
///      1. Every action `assert`s its own postconditions: a successful swap delivers exactly the router's quote, a
///         burn pays exactly the pro-rata share, a deposit mints exactly the pair's LP formula, skim/sync leave the
///         pair in sync, and so on. In Foundry an assert failure fails the campaign (`fail_on_revert = true`); in
///         Medusa it fails the action's assertion test.
///      2. A reverting router or pair call is swallowed only if its error selector is on that action's list of
///         expected errors (dust that rounds to zero, an exact output larger than the reserve, ...). Anything else
///         goes to `_onUnexpectedRevert`, which re-raises it (Foundry) or fails an assertion (Medusa).
///      3. Every action snapshots all pairs before and after and records any violation of a cross-action invariant
///         in a ghost flag; the `check*` views are the invariants I-1 to I-9.
abstract contract AMMSystem is CommonBase, StdUtils {
    uint256 internal constant N = 3;

    AMMFactory public factory;
    AMMRouter public router;
    FlashBorrower public borrower;
    MockERC20[N] public tokens;
    AMMPair[N] public pairs; // pairs[i] = tokens[i] / tokens[(i + 1) % N]
    address[N] public actors = [address(0x1111), address(0x2222), address(0x3333)];
    address public constant FEE_RECIPIENT = address(0xFEE0);

    // Ghost state: set once a violation is observed, never cleared.
    bool public kDecreasedOutsideBurn;
    bool public supplyDecreasedOutsideBurn;
    bool public shareValueDecreased;
    bool public roundTripProfited;

    // Ghost counters: attempted and successful operations, so the suite can assert that the campaign is not vacuous.
    uint256 public swapAttempts;
    uint256 public swapsExecuted;
    uint256 public exactOutAttempts;
    uint256 public exactOutExecuted;
    uint256 public burnAttempts;
    uint256 public burnsExecuted;
    uint256 public roundTrips;

    struct Snapshot {
        uint256 reserve0;
        uint256 reserve1;
        uint256 supply;
        uint256 feeLp;
    }

    /// @dev Pair and actor state around a liquidity operation, ordered as the router arguments (A, B).
    struct LiquidityState {
        uint256 reserveA;
        uint256 reserveB;
        uint256 pairBalanceA;
        uint256 pairBalanceB;
        uint256 supply;
        uint256 feeLp;
        uint256 pairLp;
        uint256 actorA;
        uint256 actorB;
        uint256 actorLp;
    }

    function _deploySystem() internal {
        vm.warp(1_750_000_000);
        factory = new AMMFactory(address(this));
        router = new AMMRouter(address(factory));
        borrower = new FlashBorrower(factory);
        tokens[0] = new MockERC20("Token 0", "T0", 18);
        tokens[1] = new MockERC20("Token 1", "T1", 6);
        tokens[2] = new MockERC20("Token 2", "T2", 24);
        for (uint256 t; t < N; ++t) {
            tokens[t].mint(address(this), 1e40);
            tokens[t].approve(address(router), type(uint256).max);
            tokens[t].mint(address(borrower), 1e36);
            for (uint256 a; a < N; ++a) {
                tokens[t].mint(actors[a], 1e36);
                vm.prank(actors[a]);
                tokens[t].approve(address(router), type(uint256).max);
            }
        }
        for (uint256 i; i < N; ++i) {
            (address x, address y) = (address(tokens[i]), address(tokens[(i + 1) % N]));
            router.addLiquidity(x, y, 1e26, 3e26, 0, 0, address(this), block.timestamp);
            pairs[i] = AMMPair(factory.getPair(x, y));
            for (uint256 a; a < N; ++a) {
                // Every actor starts as an LP so that burns are reachable from the first call.
                vm.prank(actors[a]);
                router.addLiquidity(x, y, 1e24, 3e24, 0, 0, actors[a], block.timestamp);
                vm.prank(actors[a]);
                pairs[i].approve(address(router), type(uint256).max);
            }
        }
    }

    // ------------------------------------------------------------------------------------------------------
    // Expected reverts
    // ------------------------------------------------------------------------------------------------------

    /// @dev Called with the revert data of a router or pair call whose selector is not on the action's list.
    ///      Foundry: re-raise it, so `fail_on_revert = true` fails the campaign with the original error.
    ///      The Medusa harness overrides this with an assertion failure (a plain revert is not a Medusa failure).
    function _onUnexpectedRevert(bytes memory reason) internal virtual {
        assembly ("memory-safe") {
            // Re-raise the exact revert data of the failed call.
            revert(add(reason, 0x20), mload(reason))
        }
    }

    /// @dev Swallows `reason` if its selector is one of `expected`, otherwise hands it to `_onUnexpectedRevert`.
    function _allowOnly(bytes memory reason, bytes4[] memory expected) internal {
        bytes4 selector = bytes4(reason); // zero-padded when shorter than 4 bytes (a bare revert is never expected)
        for (uint256 i; i < expected.length; ++i) {
            if (reason.length >= 4 && selector == expected[i]) return;
        }
        _onUnexpectedRevert(reason);
    }

    /// @dev Exact-input swaps (minimum output 0): a hop can round to zero output (the pair rejects a zero-output
    ///      swap; the library rejects a zero input to the next hop); the actor can run out of tokens; reserves are
    ///      capped at 112 bits.
    function _exactInErrors() internal pure returns (bytes4[] memory e) {
        e = new bytes4[](4);
        e[0] = IAMMPair.InsufficientOutputAmount.selector;
        e[1] = AMMLibrary.InsufficientInputAmount.selector;
        e[2] = ERC20.InsufficientBalance.selector;
        e[3] = IAMMPair.Overflow.selector;
    }

    /// @dev Exact-output swaps (no maximum input): the output can exceed a reserve, and the required input can
    ///      exceed the actor's balance or the 112-bit reserve cap.
    function _exactOutErrors() internal pure returns (bytes4[] memory e) {
        e = new bytes4[](3);
        e[0] = AMMLibrary.InsufficientLiquidity.selector;
        e[1] = ERC20.InsufficientBalance.selector;
        e[2] = IAMMPair.Overflow.selector;
    }

    /// @dev Deposits (minimums 0): a zero side cannot be quoted, dust mints no LP, balances and reserves are finite.
    function _depositErrors() internal pure returns (bytes4[] memory e) {
        e = new bytes4[](4);
        e[0] = AMMLibrary.InsufficientAmount.selector;
        e[1] = IAMMPair.InsufficientLiquidityMinted.selector;
        e[2] = ERC20.InsufficientBalance.selector;
        e[3] = IAMMPair.Overflow.selector;
    }

    /// @dev Withdrawals (minimums 0): burning zero or dust LP pays nothing on one side.
    function _withdrawErrors() internal pure returns (bytes4[] memory e) {
        e = new bytes4[](1);
        e[0] = IAMMPair.InsufficientLiquidityBurned.selector;
    }

    /// @dev Flash swaps: borrowing nothing on both sides.
    function _flashErrors() internal pure returns (bytes4[] memory e) {
        e = new bytes4[](1);
        e[0] = IAMMPair.InsufficientOutputAmount.selector;
    }

    // ------------------------------------------------------------------------------------------------------
    // Snapshots and ghost bookkeeping
    // ------------------------------------------------------------------------------------------------------

    function _snapshot() internal view returns (Snapshot[N] memory snaps) {
        for (uint256 i; i < N; ++i) {
            (uint112 r0, uint112 r1,) = pairs[i].getReserves();
            snaps[i] = Snapshot(r0, r1, pairs[i].totalSupply(), pairs[i].balanceOf(FEE_RECIPIENT));
        }
    }

    /// @dev a * b >= c * d without overflow (512-bit products).
    function _mulGe(uint256 a, uint256 b, uint256 c, uint256 d) internal pure returns (bool) {
        (uint256 hi1, uint256 lo1) = _mul512(a, b);
        (uint256 hi2, uint256 lo2) = _mul512(c, d);
        return hi1 > hi2 || (hi1 == hi2 && lo1 >= lo2);
    }

    function _mul512(uint256 a, uint256 b) internal pure returns (uint256 hi, uint256 lo) {
        assembly ("memory-safe") {
            // Standard 512-bit multiplication (Remco Bloemen): mm = a*b mod (2^256 - 1), lo = a*b mod 2^256.
            let mm := mulmod(a, b, not(0))
            lo := mul(a, b)
            hi := sub(sub(mm, lo), lt(mm, lo))
        }
    }

    function _record(Snapshot[N] memory before, bool isBurn) internal {
        Snapshot[N] memory now_ = _snapshot();
        for (uint256 i; i < N; ++i) {
            uint256 kBefore = before[i].reserve0 * before[i].reserve1;
            uint256 kAfter = now_[i].reserve0 * now_[i].reserve1;
            if (!isBurn && kAfter < kBefore) kDecreasedOutsideBurn = true;
            if (!isBurn && now_[i].supply < before[i].supply) supplyDecreasedOutsideBurn = true;
            // sqrt(k) per LP share never decreases, except for the dilution of the protocol-fee mint F:
            //   kAfter * (supplyBefore + F)^2 >= kBefore * supplyAfter^2
            uint256 fee = now_[i].feeLp - before[i].feeLp;
            uint256 base = before[i].supply + fee;
            if (!_mulGe(kAfter, base * base, kBefore, now_[i].supply * now_[i].supply)) shareValueDecreased = true;
        }
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % N];
    }

    function _pathFor(uint256 seed) internal view returns (address[] memory path) {
        uint256 start = seed % N;
        bool forward = (seed >> 8) % 2 == 0;
        uint256 hops = 1 + (seed >> 16) % 2; // 1 or 2 hops
        path = new address[](hops + 1);
        for (uint256 i; i <= hops; ++i) {
            path[i] = address(tokens[forward ? (start + i) % N : (start + N * 2 - i) % N]);
        }
    }

    function _balance(address token, address owner) internal view returns (uint256) {
        return MockERC20(token).balanceOf(owner);
    }

    function _inSync(AMMPair pair) internal view returns (bool) {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        return _balance(pair.token0(), address(pair)) == r0 && _balance(pair.token1(), address(pair)) == r1;
    }

    function _liquidityState(AMMPair pair, address tokenA, address tokenB, address actor)
        internal
        view
        returns (LiquidityState memory s)
    {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        (s.reserveA, s.reserveB) = tokenA == pair.token0() ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        s.pairBalanceA = _balance(tokenA, address(pair));
        s.pairBalanceB = _balance(tokenB, address(pair));
        s.supply = pair.totalSupply();
        s.feeLp = pair.balanceOf(FEE_RECIPIENT);
        s.pairLp = pair.balanceOf(address(pair));
        s.actorA = _balance(tokenA, actor);
        s.actorB = _balance(tokenB, actor);
        s.actorLp = pair.balanceOf(actor);
    }

    // ------------------------------------------------------------------------------------------------------
    // Actions: liquidity
    // ------------------------------------------------------------------------------------------------------

    function addLiquidity(uint256 actorSeed, uint256 pairSeed, uint256 amountA, uint256 amountB) public {
        uint256 p = pairSeed % N;
        address actor = _actor(actorSeed);
        (amountA, amountB) = (bound(amountA, 0, 1e30), bound(amountB, 0, 1e30));
        Snapshot[N] memory before = _snapshot();
        _addLiquidityAs(actor, p, amountA, amountB);
        _record(before, false);
    }

    /// @dev One deposit: who adds how much to which pair, with the tokens ordered as the router arguments.
    struct Deposit {
        AMMPair pair;
        address actor;
        address tokenA;
        address tokenB;
        uint256 desiredA;
        uint256 desiredB;
    }

    function _addLiquidityAs(address actor, uint256 p, uint256 desiredA, uint256 desiredB) internal {
        Deposit memory d = Deposit({
            pair: pairs[p],
            actor: actor,
            tokenA: address(tokens[p]),
            tokenB: address(tokens[(p + 1) % N]),
            desiredA: desiredA,
            desiredB: desiredB
        });
        LiquidityState memory s = _liquidityState(d.pair, d.tokenA, d.tokenB, actor);
        vm.prank(actor);
        try router.addLiquidity(d.tokenA, d.tokenB, desiredA, desiredB, 0, 0, actor, block.timestamp) returns (
            uint256 usedA, uint256 usedB, uint256 liquidity
        ) {
            _assertDeposit(d, s, usedA, usedB, liquidity);
        } catch (bytes memory reason) {
            _allowOnly(reason, _depositErrors());
        }
    }

    /// @dev A successful deposit takes at most what was offered, charges exactly what it reports and mints exactly
    ///      the pair's LP formula.
    function _assertDeposit(Deposit memory d, LiquidityState memory s, uint256 usedA, uint256 usedB, uint256 liquidity)
        internal
        view
    {
        assert(usedA <= d.desiredA && usedB <= d.desiredB);
        assert(s.actorA - _balance(d.tokenA, d.actor) == usedA);
        assert(s.actorB - _balance(d.tokenB, d.actor) == usedB);
        // min(amount * supply / reserve) over both sides, where the amount includes any unsynced surplus and the
        // supply includes the protocol-fee mint of this call.
        uint256 base = s.supply + (d.pair.balanceOf(FEE_RECIPIENT) - s.feeLp);
        uint256 viaA = (usedA + s.pairBalanceA - s.reserveA) * base / s.reserveA;
        uint256 viaB = (usedB + s.pairBalanceB - s.reserveB) * base / s.reserveB;
        assert(liquidity == (viaA < viaB ? viaA : viaB));
        assert(d.pair.balanceOf(d.actor) - s.actorLp == liquidity);
        assert(_inSync(d.pair));
    }

    function removeLiquidity(uint256 actorSeed, uint256 pairSeed, uint256 bps) public {
        _removeLiquidity(actorSeed, pairSeed, bps, false);
    }

    function removeLiquiditySupportingFeeOnTransfer(uint256 actorSeed, uint256 pairSeed, uint256 bps) public {
        _removeLiquidity(actorSeed, pairSeed, bps, true);
    }

    /// @dev One withdrawal: who burns how much LP of which pair, with the tokens ordered as the router arguments.
    struct Withdrawal {
        AMMPair pair;
        address actor;
        address tokenA;
        address tokenB;
        uint256 liquidity;
        bool feeOnTransferVariant;
    }

    function _removeLiquidity(uint256 actorSeed, uint256 pairSeed, uint256 bps, bool feeOnTransferVariant) internal {
        uint256 p = pairSeed % N;
        Withdrawal memory w = Withdrawal({
            pair: pairs[p],
            actor: _actor(actorSeed),
            tokenA: address(tokens[p]),
            tokenB: address(tokens[(p + 1) % N]),
            liquidity: 0,
            feeOnTransferVariant: feeOnTransferVariant
        });
        w.liquidity = w.pair.balanceOf(w.actor) * bound(bps, 0, 10_000) / 10_000;
        Snapshot[N] memory before = _snapshot();
        LiquidityState memory s = _liquidityState(w.pair, w.tokenA, w.tokenB, w.actor);
        ++burnAttempts;
        (bool ok, uint256 amountA, uint256 amountB, bytes memory reason) = _routerRemove(w);
        if (ok) {
            ++burnsExecuted;
            _assertBurn(w, s, amountA, amountB);
        } else {
            _allowOnly(reason, _withdrawErrors());
        }
        _record(before, true);
    }

    /// @dev One router withdrawal as `w.actor` (minimums 0); returns the amounts, or the revert data.
    function _routerRemove(Withdrawal memory w)
        internal
        returns (bool ok, uint256 amountA, uint256 amountB, bytes memory reason)
    {
        vm.prank(w.actor);
        if (w.feeOnTransferVariant) {
            try router.removeLiquiditySupportingFeeOnTransferTokens(
                w.tokenA, w.tokenB, w.liquidity, 0, 0, w.actor, block.timestamp
            ) returns (
                uint256 a, uint256 b
            ) {
                return (true, a, b, "");
            } catch (bytes memory r) {
                return (false, 0, 0, r);
            }
        }
        try router.removeLiquidity(w.tokenA, w.tokenB, w.liquidity, 0, 0, w.actor, block.timestamp) returns (
            uint256 a, uint256 b
        ) {
            return (true, a, b, "");
        } catch (bytes memory r) {
            return (false, 0, 0, r);
        }
    }

    /// @dev A successful burn pays exactly the pro-rata share of the pair's balances, rounded down, to the actor.
    function _assertBurn(Withdrawal memory w, LiquidityState memory s, uint256 amountA, uint256 amountB) internal view {
        // The pair divides by the supply after this call's protocol-fee mint and burns all the LP it holds.
        uint256 base = s.supply + (w.pair.balanceOf(FEE_RECIPIENT) - s.feeLp);
        uint256 burned = w.liquidity + s.pairLp;
        assert(base - w.pair.totalSupply() == burned);
        assert(s.actorLp - w.pair.balanceOf(w.actor) == w.liquidity);
        assert(amountA == burned * s.pairBalanceA / base && amountB == burned * s.pairBalanceB / base);
        assert(_balance(w.tokenA, w.actor) - s.actorA == amountA);
        assert(_balance(w.tokenB, w.actor) - s.actorB == amountB);
        assert(_inSync(w.pair));
    }

    // ------------------------------------------------------------------------------------------------------
    // Actions: swaps
    // ------------------------------------------------------------------------------------------------------

    function swapExactIn(uint256 actorSeed, uint256 pathSeed, uint256 amountIn) public {
        address actor = _actor(actorSeed);
        Snapshot[N] memory before = _snapshot();
        _swapExactInAs(actor, bound(amountIn, 1, 1e29), _pathFor(pathSeed));
        _record(before, false);
    }

    /// @dev Exact-input swap that must deliver exactly `router.getAmountsOut`; returns the output (0 if reverted).
    function _swapExactInAs(address actor, uint256 amountIn, address[] memory path) internal returns (uint256) {
        (address tokenIn, address tokenOut) = (path[0], path[path.length - 1]);
        (bool quotable, uint256[] memory quoted) = _quoteOut(amountIn, path);
        (uint256 inBefore, uint256 outBefore) = (_balance(tokenIn, actor), _balance(tokenOut, actor));
        ++swapAttempts;
        vm.prank(actor);
        try router.swapExactTokensForTokens(amountIn, 0, path, actor, block.timestamp) returns (
            uint256[] memory amounts
        ) {
            ++swapsExecuted;
            // Only a route the router can quote can execute, and it executes at exactly that quote.
            assert(quotable && keccak256(abi.encode(amounts)) == keccak256(abi.encode(quoted)));
            uint256 amountOut = amounts[amounts.length - 1];
            assert(_balance(tokenOut, actor) - outBefore == amountOut);
            assert(inBefore - _balance(tokenIn, actor) == amountIn);
            return amountOut;
        } catch (bytes memory reason) {
            _allowOnly(reason, _exactInErrors());
            return 0;
        }
    }

    function swapExactOut(uint256 actorSeed, uint256 pathSeed, uint256 amountOut) public {
        address actor = _actor(actorSeed);
        address[] memory path = _pathFor(pathSeed);
        amountOut = bound(amountOut, 1, 1e27);
        Snapshot[N] memory before = _snapshot();
        (address tokenIn, address tokenOut) = (path[0], path[path.length - 1]);
        (bool quotable, uint256[] memory quoted) = _quoteIn(amountOut, path);
        (uint256 inBefore, uint256 outBefore) = (_balance(tokenIn, actor), _balance(tokenOut, actor));
        ++swapAttempts;
        ++exactOutAttempts;
        vm.prank(actor);
        try router.swapTokensForExactTokens(amountOut, type(uint256).max, path, actor, block.timestamp) returns (
            uint256[] memory amounts
        ) {
            ++swapsExecuted;
            ++exactOutExecuted;
            // Delivers exactly the requested output for exactly the quoted input.
            assert(quotable && keccak256(abi.encode(amounts)) == keccak256(abi.encode(quoted)));
            assert(_balance(tokenOut, actor) - outBefore == amountOut);
            assert(inBefore - _balance(tokenIn, actor) == amounts[0]);
        } catch (bytes memory reason) {
            _allowOnly(reason, _exactOutErrors());
        }
        _record(before, false);
    }

    function swapSupportingFeeOnTransfer(uint256 actorSeed, uint256 pathSeed, uint256 amountIn) public {
        address actor = _actor(actorSeed);
        address[] memory path = _pathFor(pathSeed);
        amountIn = bound(amountIn, 1, 1e29);
        Snapshot[N] memory before = _snapshot();
        (address tokenIn, address tokenOut) = (path[0], path[path.length - 1]);
        (bool quotable, uint256 expectedOut) = _quoteFeeOnTransfer(amountIn, path);
        (uint256 inBefore, uint256 outBefore) = (_balance(tokenIn, actor), _balance(tokenOut, actor));
        ++swapAttempts;
        vm.prank(actor);
        try router.swapExactTokensForTokensSupportingFeeOnTransferTokens(amountIn, 0, path, actor, block.timestamp) {
            ++swapsExecuted;
            // Every hop is priced on what the pair actually holds above its reserve (including any donation).
            assert(quotable && _balance(tokenOut, actor) - outBefore == expectedOut);
            assert(inBefore - _balance(tokenIn, actor) == amountIn);
        } catch (bytes memory reason) {
            _allowOnly(reason, _exactInErrors());
        }
        _record(before, false);
    }

    /// @dev Swap A -> B, then immediately swap the whole output B -> A in the same pair. A pair holding an
    ///      unsynced surplus (a donation) pays it to the next trader, exactly like Uniswap v2 (`skim` lets anyone
    ///      take it), so the no-profit property is only recorded when the pair starts in sync.
    function roundTrip(uint256 actorSeed, uint256 pairSeed, uint256 amountIn, bool reverse) public {
        uint256 p = pairSeed % N;
        address actor = _actor(actorSeed);
        (address x, address y) = (address(tokens[p]), address(tokens[(p + 1) % N]));
        if (reverse) (x, y) = (y, x);
        amountIn = bound(amountIn, 1, 1e29);
        address[] memory there = new address[](2);
        (there[0], there[1]) = (x, y);
        address[] memory back = new address[](2);
        (back[0], back[1]) = (y, x);
        bool inSync = _inSync(pairs[p]);
        Snapshot[N] memory before = _snapshot();
        uint256 out = _swapExactInAs(actor, amountIn, there);
        if (out > 0) {
            uint256 returned = _swapExactInAs(actor, out, back);
            if (inSync && returned > 0) {
                ++roundTrips;
                if (returned > amountIn) roundTripProfited = true;
            }
        }
        _record(before, false);
    }

    function flashSwap(uint256 pairSeed, uint256 amount0, uint256 amount1) public {
        AMMPair pair = pairs[pairSeed % N];
        (uint112 r0, uint112 r1,) = pair.getReserves();
        (amount0, amount1) = (bound(amount0, 0, uint256(r0) / 2), bound(amount1, 0, uint256(r1) / 2));
        Snapshot[N] memory before = _snapshot();
        uint256 borrowerBefore0 = _balance(pair.token0(), address(borrower));
        uint256 borrowerBefore1 = _balance(pair.token1(), address(borrower));
        try borrower.borrow(pair, amount0, amount1) {
            // The borrower kept nothing and paid exactly its repayment rule; the pair ends in sync.
            uint256 repay0 = amount0 > 0 ? amount0 * borrower.repayNumerator() / 997 + 1 - amount0 : 0;
            uint256 repay1 = amount1 > 0 ? amount1 * borrower.repayNumerator() / 997 + 1 - amount1 : 0;
            assert(borrowerBefore0 - _balance(pair.token0(), address(borrower)) == repay0);
            assert(borrowerBefore1 - _balance(pair.token1(), address(borrower)) == repay1);
            assert(_inSync(pair));
        } catch (bytes memory reason) {
            _allowOnly(reason, _flashErrors());
        }
        _record(before, false);
    }

    // ------------------------------------------------------------------------------------------------------
    // Actions: balance reconciliation, time, protocol fee
    // ------------------------------------------------------------------------------------------------------

    function donate(uint256 pairSeed, uint256 amount0, uint256 amount1) public {
        AMMPair pair = pairs[pairSeed % N];
        (amount0, amount1) = (bound(amount0, 0, 1e28), bound(amount1, 0, 1e28));
        Snapshot[N] memory before = _snapshot();
        (address t0, address t1) = (pair.token0(), pair.token1());
        (uint256 b0, uint256 b1) = (_balance(t0, address(pair)), _balance(t1, address(pair)));
        MockERC20(t0).transfer(address(pair), amount0);
        MockERC20(t1).transfer(address(pair), amount1);
        // A donation moves balances only; reserves wait for the next sync, mint, burn or swap.
        assert(_balance(t0, address(pair)) - b0 == amount0 && _balance(t1, address(pair)) - b1 == amount1);
        _record(before, false);
    }

    function skim(uint256 pairSeed, uint256 actorSeed) public {
        AMMPair pair = pairs[pairSeed % N];
        address to = _actor(actorSeed);
        Snapshot[N] memory before = _snapshot();
        (address t0, address t1) = (pair.token0(), pair.token1());
        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 surplus0 = _balance(t0, address(pair)) - r0;
        uint256 surplus1 = _balance(t1, address(pair)) - r1;
        (uint256 to0, uint256 to1) = (_balance(t0, to), _balance(t1, to));
        pair.skim(to);
        // skim pays out exactly the surplus above the reserves and leaves the pair in sync.
        assert(_balance(t0, to) - to0 == surplus0 && _balance(t1, to) - to1 == surplus1);
        assert(_inSync(pair));
        _record(before, false);
    }

    function sync(uint256 pairSeed) public {
        AMMPair pair = pairs[pairSeed % N];
        Snapshot[N] memory before = _snapshot();
        pair.sync();
        // sync writes the balances into the reserves.
        assert(_inSync(pair));
        _record(before, false);
    }

    function warp(uint256 seconds_) public {
        uint256 start = block.timestamp;
        uint256 delta = bound(seconds_, 0, 7 days);
        vm.warp(start + delta);
        assert(block.timestamp == start + delta);
    }

    function setProtocolFee(bool on) public {
        address recipient = on ? FEE_RECIPIENT : address(0);
        factory.setFeeTo(recipient);
        assert(factory.feeTo() == recipient);
    }

    // ------------------------------------------------------------------------------------------------------
    // Quotes used by the action assertions
    // ------------------------------------------------------------------------------------------------------

    function _quoteOut(uint256 amountIn, address[] memory path) internal view returns (bool, uint256[] memory) {
        try router.getAmountsOut(amountIn, path) returns (uint256[] memory amounts) {
            return (true, amounts);
        } catch {
            return (false, new uint256[](0));
        }
    }

    function _quoteIn(uint256 amountOut, address[] memory path) internal view returns (bool, uint256[] memory) {
        try router.getAmountsIn(amountOut, path) returns (uint256[] memory amounts) {
            return (true, amounts);
        } catch {
            return (false, new uint256[](0));
        }
    }

    /// @dev Output of a fee-on-transfer-style swap: every hop's input is what its pair holds above its reserve
    ///      (the incoming amount plus any unsynced surplus). The tokens here charge no fee, so this is exact.
    function _quoteFeeOnTransfer(uint256 amountIn, address[] memory path) internal view returns (bool, uint256) {
        uint256 incoming = amountIn;
        for (uint256 i; i + 1 < path.length; ++i) {
            AMMPair pair = AMMPair(factory.getPair(path[i], path[i + 1]));
            (uint112 r0, uint112 r1,) = pair.getReserves();
            (uint256 reserveIn, uint256 reserveOut) =
                path[i] == pair.token0() ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
            uint256 input = _balance(path[i], address(pair)) + incoming - reserveIn;
            try router.getAmountOut(input, reserveIn, reserveOut) returns (uint256 out) {
                if (out == 0) return (false, 0); // the pair rejects a zero-output swap
                incoming = out;
            } catch {
                return (false, 0);
            }
        }
        return (true, incoming);
    }

    // ------------------------------------------------------------------------------------------------------
    // Invariants
    // ------------------------------------------------------------------------------------------------------

    /// @notice Non-vacuity: every operation kind attempted at least `minAttempts` times succeeded at least once.
    ///         Expected reverts are swallowed, so without this a regression that made every swap (or every burn)
    ///         revert with an "expected" error would leave every other invariant green.
    function checkNotVacuous(uint256 minAttempts) public view returns (bool) {
        if (swapAttempts >= minAttempts && swapsExecuted == 0) return false;
        if (exactOutAttempts >= minAttempts && exactOutExecuted == 0) return false;
        if (burnAttempts >= minAttempts && burnsExecuted == 0) return false;
        return true;
    }

    function checkKNeverDecreasesExceptOnBurn() public view returns (bool) {
        return !kDecreasedOutsideBurn;
    }

    function checkLpSupplyOnlyDropsOnBurn() public view returns (bool) {
        return !supplyDecreasedOutsideBurn;
    }

    function checkShareValueNeverDecreases() public view returns (bool) {
        return !shareValueDecreased;
    }

    function checkRoundTripNeverProfits() public view returns (bool) {
        return !roundTripProfited;
    }

    function checkReservesNeverExceedBalances() public view returns (bool) {
        for (uint256 i; i < N; ++i) {
            (uint112 r0, uint112 r1,) = pairs[i].getReserves();
            if (r0 > _balance(pairs[i].token0(), address(pairs[i]))) return false;
            if (r1 > _balance(pairs[i].token1(), address(pairs[i]))) return false;
        }
        return true;
    }

    function checkMinimumLiquidityLockedForever() public view returns (bool) {
        for (uint256 i; i < N; ++i) {
            if (pairs[i].balanceOf(address(0)) != pairs[i].MINIMUM_LIQUIDITY()) return false;
        }
        return true;
    }

    function checkRouterHoldsNothing() public view returns (bool) {
        for (uint256 i; i < N; ++i) {
            if (tokens[i].balanceOf(address(router)) != 0) return false;
            if (pairs[i].balanceOf(address(router)) != 0) return false;
        }
        return true;
    }

    function checkLpSupplyEqualsSumOfHolders() public view returns (bool) {
        for (uint256 i; i < N; ++i) {
            AMMPair pair = pairs[i];
            uint256 sum = pair.balanceOf(address(0)) + pair.balanceOf(address(this)) + pair.balanceOf(FEE_RECIPIENT)
                + pair.balanceOf(address(pair)) + pair.balanceOf(address(router));
            for (uint256 a; a < N; ++a) {
                sum += pair.balanceOf(actors[a]);
            }
            if (sum != pair.totalSupply()) return false;
        }
        return true;
    }

    function checkLockReleasedBetweenTransactions() public view returns (bool) {
        for (uint256 i; i < N; ++i) {
            if (pairs[i].isLocked()) return false;
        }
        return true;
    }
}
