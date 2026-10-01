// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

import {HookFixture} from "../utils/HookFixture.sol";
import {VolatilityFeeHook} from "../../src/VolatilityFeeHook.sol";
import {IVolatilityFeeHook} from "../../src/interfaces/IVolatilityFeeHook.sol";

/// @notice Replays the seeded GBM paths in test/fixtures/gbm_paths.json (written by sim/gen_paths.py) through hook
/// pools (several fee-curve configurations) and a static 30 bps pool with identical liquidity, and reports LP fee
/// revenue, LP P&L versus holding, and arbitrage profit.
///
/// Per block: an arbitrageur trades first in each pool and moves its price to the edge of the no-arbitrage band
/// around the external price (band = total fee it would pay, 1 tick ~ 1 bp); then up to two noise traders trade in
/// each pool if the fee they would pay there at the margin (LP fee, plus the surcharge if the pool price sits on the
/// block's range edge in their direction) is within their tolerance (elastic demand). Economic results depend on the
/// model, so they are not asserted as "better" or "worse"; instead the whole report is pinned to the committed file
/// test/fixtures/replay/<regime>.txt, so the numbers quoted in the README cannot drift from what the code produces.
/// Regenerate them after an intended change with: REPLAY_REPORT_UPDATE=true forge test --match-contract GbmReplayTest
/// The assertions check the mechanism (fees track volatility, the surcharge lowers arbitrage profit against the same
/// curve without it, the hook ends holding nothing).
contract GbmReplayTest is HookFixture {
    using StateLibrary for IPoolManager;

    uint256 internal constant Q96 = 2 ** 96;
    uint256 internal constant Q128 = 2 ** 128;
    uint24 internal constant STATIC_FEE = 3000;
    int256 internal constant HUGE = 1e30;

    struct PoolStats {
        uint256 feesValue; // LP fees + donations, valued in token1 at the final external price
        int256 pnlVsHodl; // LP position + fees - initial deposit, all valued at the final external price
        int256 arbPnl; // arbitrage profit, valued at the external price at trade time
        uint256 noiseTrades;
        uint256 feeSumPips; // sum over blocks of the LP fee a new swap would pay (for the average)
        uint256 surchargedArbs; // arbitrage trades that paid a surcharge
    }

    struct Path {
        string name;
        int256[] extTicks;
        int256[] noiseAmounts;
        uint256[] noiseMaxFeePips;
    }

    struct Venue {
        PoolKey key;
        PoolId id;
        VolatilityFeeHook hook; // zero for the static pool
    }

    string internal constant REPORT_DIR = "test/fixtures/replay/";

    string internal json;
    uint256 internal startAmount0;
    uint256 internal startAmount1;
    uint256 internal blocks;
    uint160 internal deployNonce;

    function setUp() public {
        setUpEnvironment();
        json = vm.readFile("test/fixtures/gbm_paths.json");
        blocks = vm.parseJsonUint(json, ".blocks");
        (startAmount0, startAmount1) = _amountsFor(currentSqrtPrice(poolId));
    }

    /// @notice Report for the calm regime (sigma 1.5 bps per block). Run with -vv to see the table. Each regime's
    /// report (the static 30 bps pool and three hook configurations) must match its committed file under
    /// test/fixtures/replay/ byte for byte, and in each the surcharge must lower arbitrage profit against the same
    /// fee curve without it. One test per regime keeps each run under the per-test gas limit.
    function test_replay_report_calm() public {
        _checkReport(0);
    }

    /// @notice Report for the normal regime (sigma 4 bps per block).
    function test_replay_report_normal() public {
        _checkReport(1);
    }

    /// @notice Report for the stressed regime (sigma 10 bps per block).
    function test_replay_report_stressed() public {
        _checkReport(2);
    }

    /// @notice Report for the regime-switch path (sigma 1.5 -> 12 -> 1.5 bps per block).
    function test_replay_report_regimeSwitch() public {
        _checkReport(3);
    }

    function _checkReport(uint256 index) internal {
        string memory report = _reportRegime(index);
        console2.log(report);
        string memory path = string.concat(REPORT_DIR, _loadPath(index).name, ".txt");
        if (vm.envOr("REPLAY_REPORT_UPDATE", false)) {
            vm.writeFile(path, report);
        } else {
            assertEq(report, vm.readFile(path), string.concat("replay report differs from ", path));
        }
    }

    /// @notice With the full flow (arbitrage and noise), the average LP fee still orders the regimes by volatility.
    function test_replay_feeTracksVolatilityAcrossRegimes() public {
        assertEq(_pathCount(), 4, "fixture has four regimes");
        uint256[3] memory avgFee;
        for (uint256 i; i < 3; ++i) {
            uint256 snapshot = vm.snapshotState();
            avgFee[i] = _run(_loadPath(i), Venue(poolKey, poolId, hook)).feeSumPips / blocks;
            vm.revertToState(snapshot);
        }
        console2.log("avg LP fee (pips) calm / normal / stressed:", avgFee[0], avgFee[1], avgFee[2]);
        assertLt(avgFee[0], avgFee[1], "calm pays less than normal");
        assertLt(avgFee[1], avgFee[2], "normal pays less than stressed");
    }

    /// @notice In the regime-switch path (sigma 1.5 -> 12 -> 1.5 bps per block) the fee rises during the
    /// high-volatility segment and decays after it. Arbitrage only, so the oracle sees the external price moves.
    function test_replay_feeFollowsRegimeSwitch() public {
        Path memory p = _loadPath(3);
        uint256[] memory fees = new uint256[](blocks);
        PoolStats memory h;
        Venue memory v = Venue(poolKey, poolId, hook);
        uint256 startBlock = vm.getBlockNumber();
        for (uint256 b; b < blocks; ++b) {
            vm.roll(startBlock + b + 1);
            (uint24 lpFee, uint24 surcharge,,) = hook.quoteFees(poolKey);
            fees[b] = lpFee;
            _arbitrage(v, int24(p.extTicks[b]), lpFee + surcharge, h);
        }
        uint256 calmBefore = _mean(fees, 100, 150);
        uint256 stressed = _mean(fees, 200, 250);
        uint256 calmAfter = _mean(fees, 350, 400);
        console2.log("regime-switch avg LP fee (pips): calm-before", calmBefore);
        console2.log("                                 stressed   ", stressed);
        console2.log("                                 calm-after ", calmAfter);
        assertGt(stressed, calmBefore * 2, "fee at least doubles when volatility jumps 8x");
        assertLt(calmAfter, stressed, "fee decays once volatility subsides");
    }

    /// @dev Runs one path through the static pool and three hook configurations; returns one row per venue.
    function _reportRegime(uint256 index) internal returns (string memory out) {
        Path memory p = _loadPath(index);
        IVolatilityFeeHook.FeeConfig[3] memory configs = [
            defaultConfig(),
            IVolatilityFeeHook.FeeConfig({
                alphaWad: 0.1e18, feeSlopePips: 500, surchargeSlopePips: 0, maxSurchargePips: 0
            }),
            IVolatilityFeeHook.FeeConfig({
                alphaWad: 0.1e18, feeSlopePips: 1500, surchargeSlopePips: 500, maxSurchargePips: 5000
            })
        ];
        string[3] memory labels = ["hook default", "hook, no surcharge", "hook, steep"];

        out = string.concat(
            "== ",
            p.name,
            " (",
            vm.toString(blocks),
            " blocks)\n",
            "venue | LP fees | LP P&L vs HODL | arbitrage profit | avg LP fee | noise trades | surcharged arbs\n"
        );
        uint256 snapshot = vm.snapshotState();
        out = string.concat(
            out, _row("static 30 bps", _run(p, Venue(staticKey, staticId, VolatilityFeeHook(address(0)))), STATIC_FEE)
        );
        vm.revertToState(snapshot);
        int256[3] memory arb;
        for (uint256 c; c < configs.length; ++c) {
            snapshot = vm.snapshotState();
            Venue memory v = c == 0 ? Venue(poolKey, poolId, hook) : _deployVenue(configs[c]);
            PoolStats memory h = _run(p, v);
            arb[c] = h.arbPnl;
            out = string.concat(out, _row(labels[c], h, h.feeSumPips / blocks));
            assertEq(
                currency0.balanceOf(address(v.hook)) + currency1.balanceOf(address(v.hook)), 0, "hook holds nothing"
            );
            vm.revertToState(snapshot);
        }
        assertLt(arb[0], arb[1], string.concat(p.name, ": the surcharge lowers arbitrage profit"));
    }

    // ------------------------------------------------------------------------------------------------ simulation

    function _run(Path memory p, Venue memory v) internal returns (PoolStats memory st) {
        uint256 startBlock = vm.getBlockNumber();
        for (uint256 b; b < blocks; ++b) {
            vm.roll(startBlock + b + 1);
            int24 ext = int24(p.extTicks[b]);
            (uint24 lpFee, uint24 surcharge) = _arbFees(v);
            st.feeSumPips += lpFee;
            if (_arbitrage(v, ext, lpFee + surcharge, st) && surcharge > 0) ++st.surchargedArbs;
            for (uint256 slot; slot < 2; ++slot) {
                _noise(p, 2 * b + slot, v, st);
            }
        }
        _finalize(v.id, int24(p.extTicks[blocks - 1]), st);
    }

    function _arbFees(Venue memory v) internal view returns (uint24 lpFee, uint24 surcharge) {
        if (address(v.hook) == address(0)) return (STATIC_FEE, 0);
        (lpFee, surcharge,,) = v.hook.quoteFees(v.key);
    }

    /// @dev Moves the pool price to the edge of the no-arbitrage band around the external tick. Returns whether a
    /// trade happened.
    function _arbitrage(Venue memory v, int24 extTick, uint256 feePips, PoolStats memory st)
        internal
        returns (bool traded)
    {
        int24 band = int24(uint24(feePips / 100));
        int24 poolTick = currentTick(v.id);
        BalanceDelta d;
        if (poolTick < extTick - band) {
            d = swapWithLimit(v.key, false, -HUGE, TickMath.getSqrtPriceAtTick(extTick - band));
        } else if (poolTick > extTick + band) {
            d = swapWithLimit(v.key, true, -HUGE, TickMath.getSqrtPriceAtTick(extTick + band));
        } else {
            return false;
        }
        st.arbPnl += _signedValue(d.amount0(), d.amount1(), TickMath.getSqrtPriceAtTick(extTick));
        return true;
    }

    function _noise(Path memory p, uint256 idx, Venue memory v, PoolStats memory st) internal {
        int256 amount = p.noiseAmounts[idx];
        if (amount == 0) return;
        bool zeroForOne = amount > 0;
        uint256 fee = STATIC_FEE;
        if (address(v.hook) != address(0)) {
            (uint24 lpFee, uint24 surcharge, uint160 low, uint160 high) = v.hook.quoteFees(v.key);
            uint160 price = currentSqrtPrice(v.id);
            // Marginal fee: a trade that starts on the block's range edge in its direction pays the surcharge.
            bool onEdge = zeroForOne ? price <= low : price >= high;
            fee = lpFee + (onEdge ? surcharge : 0);
        }
        if (fee > p.noiseMaxFeePips[idx]) return;
        swapExactIn(v.key, zeroForOne, uint256(zeroForOne ? amount : -amount));
        ++st.noiseTrades;
    }

    function _finalize(PoolId id, int24 extTick, PoolStats memory st) internal view {
        uint160 extSqrt = TickMath.getSqrtPriceAtTick(extTick);
        (uint256 g0, uint256 g1) = manager.getFeeGrowthInside(id, RANGE_LOWER, RANGE_UPPER);
        st.feesValue =
            _value(FullMath.mulDiv(g0, POOL_LIQUIDITY, Q128), FullMath.mulDiv(g1, POOL_LIQUIDITY, Q128), extSqrt);
        (uint256 a0, uint256 a1) = _amountsFor(currentSqrtPrice(id));
        st.pnlVsHodl =
            int256(_value(a0, a1, extSqrt) + st.feesValue) - int256(_value(startAmount0, startAmount1, extSqrt));
    }

    /// @dev A hook with another fee curve and a fresh pool with the same liquidity as the others. The address carries
    /// the hook's flag bits; deployCodeTo avoids mining a salt per configuration.
    function _deployVenue(IVolatilityFeeHook.FeeConfig memory c) internal returns (Venue memory v) {
        address target = address(uint160(0x7777 + ++deployNonce) << 20 | HOOK_FLAGS);
        deployCodeTo("VolatilityFeeHook.sol:VolatilityFeeHook", abi.encode(manager, owner, c), target);
        v.hook = VolatilityFeeHook(target);
        vm.startPrank(owner);
        v.hook.setCurrencyAllowed(currency0, true);
        v.hook.setCurrencyAllowed(currency1, true);
        vm.stopPrank();
        (v.key, v.id) =
            initPool(currency0, currency1, IHooks(target), LPFeeLibrary.DYNAMIC_FEE_FLAG, TICK_SPACING, SQRT_PRICE_1_1);
        addLiquidity(v.key, RANGE_LOWER, RANGE_UPPER, POOL_LIQUIDITY, 0);
    }

    // ------------------------------------------------------------------------------------------------ helpers

    function _amountsFor(uint160 sqrtPriceX96) internal pure returns (uint256, uint256) {
        return
            LiquidityAmounts.getAmountsForLiquidity(
                sqrtPriceX96, sqrtAt(RANGE_LOWER), sqrtAt(RANGE_UPPER), POOL_LIQUIDITY
            );
    }

    /// @dev token1 value of (amount0, amount1) at the price given as sqrt(P) * 2^96.
    function _value(uint256 amount0, uint256 amount1, uint160 sqrtPriceX96) internal pure returns (uint256) {
        return amount1 + FullMath.mulDiv(FullMath.mulDiv(amount0, sqrtPriceX96, Q96), sqrtPriceX96, Q96);
    }

    /// @dev Signed token1 value of a BalanceDelta (positive = received).
    function _signedValue(int128 amount0, int128 amount1, uint160 sqrtPriceX96) internal pure returns (int256) {
        uint256 abs0 = amount0 >= 0 ? uint256(int256(amount0)) : uint256(-int256(amount0));
        int256 v0 = int256(_value(abs0, 0, sqrtPriceX96));
        return (amount0 >= 0 ? v0 : -v0) + int256(amount1);
    }

    function _mean(uint256[] memory xs, uint256 from, uint256 to) internal pure returns (uint256 m) {
        for (uint256 i = from; i < to; ++i) {
            m += xs[i];
        }
        m /= (to - from);
    }

    function _pathCount() internal view returns (uint256 n) {
        while (vm.keyExistsJson(json, string.concat(".paths[", vm.toString(n), "]"))) ++n;
    }

    function _loadPath(uint256 i) internal view returns (Path memory p) {
        string memory base = string.concat(".paths[", vm.toString(i), "]");
        p.name = vm.parseJsonString(json, string.concat(base, ".name"));
        p.extTicks = vm.parseJsonIntArray(json, string.concat(base, ".extTicks"));
        p.noiseAmounts = vm.parseJsonIntArray(json, string.concat(base, ".noiseAmounts"));
        p.noiseMaxFeePips = vm.parseJsonUintArray(json, string.concat(base, ".noiseMaxFeePips"));
    }

    function _row(string memory label, PoolStats memory st, uint256 avgFeePips) internal pure returns (string memory) {
        return string.concat(
            "  ",
            label,
            " | ",
            _fmt(int256(st.feesValue)),
            " | ",
            _fmt(st.pnlVsHodl),
            " | ",
            _fmt(st.arbPnl),
            " | ",
            vm.toString(avgFeePips),
            " pips | ",
            vm.toString(st.noiseTrades),
            " | ",
            vm.toString(st.surchargedArbs),
            "\n"
        );
    }

    /// @dev Formats a 1e18-scaled token1 amount with 4 decimals.
    function _fmt(int256 x) internal pure returns (string memory) {
        bool neg = x < 0;
        uint256 u = uint256(neg ? -x : x);
        string memory f = vm.toString((u % 1e18) / 1e14);
        while (bytes(f).length < 4) f = string.concat("0", f);
        return string.concat(neg ? "-" : "", vm.toString(u / 1e18), ".", f);
    }
}
