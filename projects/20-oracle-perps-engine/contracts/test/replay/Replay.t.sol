// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {VmSafe} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";

import {IOracleVerifier} from "../../src/interfaces/IOracleVerifier.sol";
import {IOrderBook} from "../../src/interfaces/IOrderBook.sol";
import {IPerpsMarket} from "../../src/interfaces/IPerpsMarket.sol";
import {PerpMath} from "../../src/libraries/PerpMath.sol";
import {PerpsTestBase} from "../utils/PerpsTestBase.sol";

/// @notice Deterministic replay of the Python-generated price paths (`sim/`, committed under
///         `test/fixtures/paths`). A scripted session (a whale, a momentum trader, a contrarian, a scalper with
///         take-profit / stop-loss orders, and a second LP) trades through the real order flow while the keeper
///         settles orders, liquidates and auto-deleverages at every 5-minute step. Custody conservation is asserted
///         at every step; at the end every position is closed, the impact pool is handed to the LPs, and the LPs
///         redeem everything, leaving only rounding dust in the market. One summary line per path reports LP PnL,
///         funding paid and received, and ADL / liquidation counts; each test pins those numbers, which are the
///         README replay table.
contract ReplayTest is PerpsTestBase {
    uint256 internal constant POOL = 1_000_000e18;

    /// @dev Per-path results in the units of the README table: basis points and whole dollars.
    struct Summary {
        int256 moveBps;
        int256 lpPnlBps;
        uint256 fundingPaid;
        uint256 fundingReceived;
        uint256 liquidations;
        uint256 adls;
        uint256 badDebt;
        uint256 haircuts;
        uint256 maxPnlFactorBps;
        uint256 impactToLps;
    }

    address internal whale = makeAddr("whale");
    address internal momentum = makeAddr("momentum");
    address internal contrarian = makeAddr("contrarian");
    address internal scalper = makeAddr("scalper");
    address internal lp2 = makeAddr("lp2");
    address[4] internal traders;

    uint256[] internal pendingTriggers;
    uint256[] internal prices;
    uint256 internal liquidations;
    uint256 internal adls;
    uint256 internal maxPnlFactor;
    uint256 internal stepPrice;

    function setUp() public override {
        super.setUp();
        traders = [whale, momentum, contrarian, scalper];
    }

    // Expected summaries are regression pins of the README replay table: update both together. Fields: move (bps),
    // LP PnL (bps), funding paid / received ($), liquidations, ADL, bad debt ($), haircuts ($), max PnL factor after
    // the keeper (bps), impact pool handed to LPs ($).

    function test_replay_gbm_calm() public {
        _check(_replay("gbm_calm"), Summary(-256, 99, 10, 9, 0, 0, 0, 0, 47, 190));
    }

    function test_replay_gbm_volatile() public {
        _check(_replay("gbm_volatile"), Summary(-151, 80, 117, 114, 0, 0, 0, 0, 257, 851));
    }

    function test_replay_gbm_rally() public {
        _check(_replay("gbm_rally"), Summary(1174, -546, 63, 58, 0, 0, 0, 0, 706, 400));
    }

    function test_replay_gbm_selloff() public {
        _check(_replay("gbm_selloff"), Summary(-1507, 555, 212, 98, 1, 0, 0, 0, 176, 294));
    }

    function test_replay_merton_crash() public {
        Summary memory got = _replay("merton_crash");
        assertGt(got.liquidations, 0, "a crash liquidates the leveraged whale");
        _check(got, Summary(-1247, 514, 319, 47, 1, 0, 603, 0, 171, 372));
    }

    function test_replay_merton_squeeze() public {
        Summary memory got = _replay("merton_squeeze");
        assertGt(got.adls, 0, "a squeeze pushes trader PnL past the ADL threshold");
        assertLe(maxPnlFactor, 0.5e18 + 0.1e18, "ADL keeps the PnL factor near its band");
        _check(got, Summary(8955, -5143, 507, 117, 3, 1, 28_818, 0, 4029, 228));
    }

    /// @dev Every committed fixture is replayed by one of the tests above.
    function test_everyFixtureIsReplayed() public view {
        VmSafe.DirEntry[] memory entries = vm.readDir("test/fixtures/paths");
        assertEq(entries.length, 6, "update the replay tests when adding fixtures");
    }

    function _check(Summary memory got, Summary memory want) internal pure {
        assertEq(got.moveBps, want.moveBps, "move");
        assertEq(got.lpPnlBps, want.lpPnlBps, "LP PnL");
        assertEq(got.fundingPaid, want.fundingPaid, "funding paid");
        assertEq(got.fundingReceived, want.fundingReceived, "funding received");
        assertEq(got.liquidations, want.liquidations, "liquidations");
        assertEq(got.adls, want.adls, "ADL");
        assertEq(got.badDebt, want.badDebt, "bad debt");
        assertEq(got.haircuts, want.haircuts, "haircuts");
        assertEq(got.maxPnlFactorBps, want.maxPnlFactorBps, "max PnL factor");
        assertEq(got.impactToLps, want.impactToLps, "impact pool handed to LPs");
    }

    // ===============================================================================================================
    // Session
    // ===============================================================================================================

    function _replay(string memory name) internal returns (Summary memory sum) {
        string memory json = vm.readFile(string.concat("test/fixtures/paths/", name, ".json"));
        string[] memory raw = vm.parseJsonStringArray(json, ".prices");
        uint256 dt = vm.parseJsonUint(json, ".dtSeconds");
        for (uint256 i; i < raw.length; ++i) {
            prices.push(vm.parseUint(raw[i]));
        }

        uint256 start = block.timestamp;
        stepPrice = prices[0];
        _deposit(lp, POOL, prices[0]);
        uint256 shareValue0 = vault.convertToAssets(1e18);

        for (uint256 i = 1; i < prices.length; ++i) {
            vm.warp(start + i * dt);
            uint256 price = prices[i];
            stepPrice = price;
            _keeperSweep(price);
            _tradersAct(i, price);
            _assertConservation();
            (uint256 factor,) = market.pnlToPoolFactor(price);
            if (factor > maxPnlFactor) maxPnlFactor = factor;
        }

        IPerpsMarket.MarketStats memory st = market.getStats();
        uint256 last = prices[prices.length - 1];
        uint256 shareValue = vault.convertToAssets(1e18);
        _closeEverything(last);

        sum.moveBps = _bpsOf(int256(last) - int256(prices[0]), prices[0]);
        sum.lpPnlBps = _bpsOf(int256(shareValue) - int256(shareValue0), shareValue0);
        sum.fundingPaid = uint256(st.fundingPaidByTraders) / 1e18;
        sum.fundingReceived = uint256(st.fundingPaidToTraders) / 1e18;
        sum.liquidations = liquidations;
        sum.adls = adls;
        sum.badDebt = uint256(st.badDebt) / 1e18;
        sum.haircuts = uint256(st.haircuts) / 1e18;
        sum.maxPnlFactorBps = maxPnlFactor * 10_000 / 1e18;
        // Everything the impact pool collected and did not pay back, handed to the LPs by the end of the run.
        sum.impactToLps = uint256(market.getStats().impactDistributed) / 1e18;

        _log(name, sum, uint256(st.borrowFees) / 1e18, uint256(st.positionFees) / 1e18);
    }

    function _log(string memory name, Summary memory sum, uint256 borrowFees, uint256 positionFees) internal pure {
        console2.log(
            string.concat(
                "REPLAY ",
                name,
                " move=",
                vm.toString(sum.moveBps),
                "bps lpPnl=",
                vm.toString(sum.lpPnlBps),
                "bps fundingPaid=$",
                vm.toString(sum.fundingPaid),
                " fundingReceived=$",
                vm.toString(sum.fundingReceived)
            )
        );
        console2.log(
            string.concat(
                "       borrowFees=$",
                vm.toString(borrowFees),
                " positionFees=$",
                vm.toString(positionFees),
                " liquidations=",
                vm.toString(sum.liquidations),
                " adl=",
                vm.toString(sum.adls),
                " badDebt=$",
                vm.toString(sum.badDebt)
            )
        );
        console2.log(
            string.concat(
                "       haircuts=$",
                vm.toString(sum.haircuts),
                " maxPnlFactorAfterKeeper=",
                vm.toString(sum.maxPnlFactorBps),
                "bps impactToLps=$",
                vm.toString(sum.impactToLps)
            )
        );
    }

    /// @dev Scripted, fully deterministic trader behaviour (no randomness beyond the path itself).
    function _tradersAct(uint256 i, uint256 price) internal {
        // Whale: one large 8x long at the open, held until liquidated, deleveraged or the end.
        if (i == 1) _order(whale, IOrderBook.OrderType.MarketIncrease, true, 520_000e18, 65_000e18, 0);

        // Momentum and contrarian re-balance hourly on the last hour's return.
        if (i % 12 == 0 && i >= 12) {
            uint256 prev = prices[i - 12];
            if (price > prev * 1005 / 1000) {
                _flip(momentum, true, 150_000e18, 15_000e18);
                _flip(contrarian, false, 100_000e18, 20_000e18);
            } else if (price < prev * 995 / 1000) {
                _flip(momentum, false, 150_000e18, 15_000e18);
                _flip(contrarian, true, 100_000e18, 20_000e18);
            }
        }

        // Scalper: a 50k position every 6 steps with a 2% take-profit and stop-loss, alternating sides.
        if (i % 6 == 3) {
            bool isLong = (i / 6) % 2 == 0;
            if (market.getPosition(scalper, isLong).sizeUsd == 0) {
                _order(scalper, IOrderBook.OrderType.MarketIncrease, isLong, 50_000e18, 5000e18, 0);
                uint256 up = price * 102 / 100;
                uint256 down = price * 98 / 100;
                pendingTriggers.push(
                    _create(scalper, IOrderBook.OrderType.TakeProfit, isLong, type(uint128).max, 0, isLong ? up : down)
                );
                pendingTriggers.push(
                    _create(scalper, IOrderBook.OrderType.StopLoss, isLong, type(uint128).max, 0, isLong ? down : up)
                );
            }
        }

        // A second LP joins mid-session and asks for half back later (may be refused by the free-liquidity rule).
        if (i == 60) _deposit(lp2, 50_000e18, price);
        if (i == 200 && vault.balanceOf(lp2) != 0) _redeem(lp2, vault.balanceOf(lp2) / 2, price);
    }

    function _flip(address who, bool toLong, uint256 size, uint256 collateral) internal {
        if (market.getPosition(who, !toLong).sizeUsd != 0) {
            _order(who, IOrderBook.OrderType.MarketDecrease, !toLong, type(uint128).max, 0, 0);
        }
        if (market.getPosition(who, toLong).sizeUsd == 0) {
            _order(who, IOrderBook.OrderType.MarketIncrease, toLong, size, collateral, 0);
        }
    }

    // ===============================================================================================================
    // Keeper
    // ===============================================================================================================

    /// @dev What the Go keeper does every tick: triggers, liquidations, then ADL on the most profitable positions.
    function _keeperSweep(uint256 price) internal {
        IOracleVerifier.SignedPriceReport[] memory r = _reports(price);

        uint256 k;
        while (k < pendingTriggers.length) {
            uint256 id = pendingTriggers[k];
            if (orderBook.getOrder(id).account == address(0)) {
                _dropTrigger(k);
            } else if (orderBook.isExecutable(id, price)) {
                vm.prank(keeper);
                orderBook.executeOrder(id, r);
                _dropTrigger(k);
            } else {
                ++k;
            }
        }

        for (uint256 t; t < 4; ++t) {
            for (uint256 s; s < 2; ++s) {
                bool isLong = s == 0;
                if (market.getPosition(traders[t], isLong).sizeUsd == 0) continue;
                if (!market.positionInfo(traders[t], isLong, price).liquidatable) continue;
                vm.prank(keeper);
                market.liquidate(traders[t], isLong, r);
                ++liquidations;
            }
        }

        for (uint256 round; round < 4; ++round) {
            (uint256 factor,) = market.pnlToPoolFactor(price);
            if (factor <= market.getRiskParams().adlThresholdFactor) break;
            (address who, bool isLong) = _mostProfitable(price);
            if (who == address(0)) break;
            vm.prank(keeper);
            market.autoDeleverage(who, isLong, r);
            ++adls;
        }
    }

    /// @dev Ranked like the Go keeper: positions on sides whose netted PnL is positive, by PnL per unit of size.
    function _mostProfitable(uint256 price) internal view returns (address best, bool bestLong) {
        uint256 bestScore;
        for (uint256 s; s < 2; ++s) {
            bool isLong = s == 0;
            IPerpsMarket.SideState memory side = market.getSide(isLong);
            if (PerpMath.pnl(isLong, side.openInterest, side.openInterestInTokens, price) <= 0) continue;
            for (uint256 t; t < 4; ++t) {
                IPerpsMarket.Position memory p = market.getPosition(traders[t], isLong);
                // A position touched this second cannot be settled with this second's reports.
                if (p.sizeUsd == 0 || p.lastUpdatedAt == block.timestamp) continue;
                int256 pnl = market.positionInfo(traders[t], isLong, price).pnl;
                if (pnl <= 0) continue;
                uint256 score = uint256(pnl) * 1e18 / p.sizeUsd;
                if (score > bestScore) (best, bestLong, bestScore) = (traders[t], isLong, score);
            }
        }
    }

    // ===============================================================================================================
    // Helpers
    // ===============================================================================================================

    function _create(address who, IOrderBook.OrderType t, bool isLong, uint256 size, uint256 collateral, uint256 trg)
        internal
        returns (uint256 id)
    {
        bool increase = t == IOrderBook.OrderType.MarketIncrease;
        uint256 fee = _minFee();
        usd.mint(who, (increase ? collateral : 0) + fee);
        vm.startPrank(who);
        usd.approve(address(orderBook), type(uint256).max);
        id = orderBook.createOrder(t, isLong, size, collateral, trg, _acceptable(isLong, increase), fee);
        vm.stopPrank();
    }

    /// @dev Market order created now and settled one second later at the same path price.
    function _order(address who, IOrderBook.OrderType t, bool isLong, uint256 size, uint256 collateral, uint256 trg)
        internal
    {
        uint256 id = _create(who, t, isLong, size, collateral, trg);
        _execute(id, stepPrice);
    }

    function _redeem(address who, uint256 shares, uint256 price) internal {
        uint256 fee = _minFee();
        usd.mint(who, fee);
        vm.prank(who);
        uint256 id = vault.requestRedeem(shares, 0, fee);
        skip(1);
        vm.prank(keeper);
        vault.executeRequest(id, _reports(price));
    }

    function _closeEverything(uint256 price) internal {
        for (uint256 t; t < 4; ++t) {
            for (uint256 s; s < 2; ++s) {
                bool isLong = s == 0;
                if (market.getPosition(traders[t], isLong).sizeUsd == 0) continue;
                uint256 id = _create(traders[t], IOrderBook.OrderType.MarketDecrease, isLong, type(uint128).max, 0, 0);
                _execute(id, price);
                assertEq(market.getPosition(traders[t], isLong).sizeUsd, 0, "position closed");
            }
        }
        assertEq(market.totalCollateral(), 0);
        // A week later the impact pool has reached the LPs, who redeem everything; the pool must honour it.
        skip(market.IMPACT_POOL_DISTRIBUTION_PERIOD());
        _redeem(lp, vault.balanceOf(lp), price);
        if (vault.balanceOf(lp2) != 0) _redeem(lp2, vault.balanceOf(lp2), price);
        assertEq(vault.totalSupply(), 0, "all shares redeemed");
        assertEq(market.impactPoolAmount(), 0, "impact pool distributed");
        assertLe(usd.balanceOf(address(market)), 2, "only rounding dust is left in the market");
        _assertConservation();
    }

    function _dropTrigger(uint256 k) internal {
        pendingTriggers[k] = pendingTriggers[pendingTriggers.length - 1];
        pendingTriggers.pop();
    }

    /// @dev Signed basis points of `delta / base`, truncated towards zero.
    function _bpsOf(int256 delta, uint256 base) internal pure returns (int256) {
        return (delta * 10_000) / int256(base);
    }
}
