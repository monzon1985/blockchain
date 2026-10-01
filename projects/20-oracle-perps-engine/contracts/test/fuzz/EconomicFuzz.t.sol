// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IOracleVerifier} from "../../src/interfaces/IOracleVerifier.sol";
import {IOrderBook} from "../../src/interfaces/IOrderBook.sol";
import {IPerpsMarket} from "../../src/interfaces/IPerpsMarket.sol";
import {PerpsTestBase} from "../utils/PerpsTestBase.sol";

/// @notice Bounded fuzzing of the economic properties on the full system (live funding and borrow parameters).
contract EconomicFuzzTest is PerpsTestBase {
    uint256 internal constant POOL = 10_000_000e18;

    function setUp() public override {
        super.setUp();
        _deposit(lp, POOL, PRICE0);
    }

    /// @dev Other traders skew the book (and fill the impact pool) at `price`.
    function _seedBook(uint256 longOi, uint256 shortOi, uint256 price) internal {
        if (longOi != 0) _open(makeAddr("seedLong"), true, longOi, longOi / 5, price);
        if (shortOi != 0) _open(makeAddr("seedShort"), false, shortOi, shortOi / 5, price);
    }

    function _order(address who, IOrderBook.OrderType t, bool isLong, uint256 size, uint256 collateral, uint256 fee)
        internal
        returns (uint256)
    {
        bool increase = t == IOrderBook.OrderType.MarketIncrease;
        vm.prank(who);
        return orderBook.createOrder(t, isLong, size, collateral, 0, _acceptable(isLong, increase), fee);
    }

    /// @notice No free round trips: whatever the skew and impact-pool state, opening a position and closing it in
    ///         the same block at the same oracle price returns strictly less than was put in.
    function testFuzz_roundTrip_sameBlockIsNeverProfitable(
        uint256 longOi,
        uint256 shortOi,
        bool isLong,
        uint256 size,
        uint256 leverage,
        uint256 price
    ) public {
        price = bound(price, 100e18, 100_000e18);
        longOi = bound(longOi, 0, 3_000_000e18);
        shortOi = bound(shortOi, 0, 3_000_000e18);
        _seedBook(longOi, shortOi, price);
        size = bound(size, 1000e18, 2_000_000e18);
        leverage = bound(leverage, 1, 15);
        uint256 collateral = size / leverage + 100e18;

        address trader = makeAddr("trader");
        uint256 fee = _minFee();
        _fund(trader, collateral + 2 * fee);
        uint256 startBalance = usd.balanceOf(trader);
        uint256 openId = _order(trader, IOrderBook.OrderType.MarketIncrease, isLong, size, collateral, fee);
        uint256 closeId = _order(trader, IOrderBook.OrderType.MarketDecrease, isLong, type(uint128).max, 0, fee);

        skip(1);
        IOracleVerifier.SignedPriceReport[] memory r = _reports(price);
        vm.startPrank(keeper);
        orderBook.executeOrder(openId, r);
        assertEq(market.getPosition(trader, isLong).sizeUsd, size, "opened");
        orderBook.executeOrder(closeId, r);
        vm.stopPrank();

        assertEq(market.getPosition(trader, isLong).sizeUsd, 0, "closed");
        assertLt(usd.balanceOf(trader), startBalance - 2 * fee, "round trip lost money");
        _assertConservation();
    }

    /// @notice The same property with the exit split into several partial closes (rounding cannot be farmed).
    function testFuzz_roundTrip_splitExitIsNeverProfitable(
        uint256 longOi,
        uint256 shortOi,
        bool isLong,
        uint256 size,
        uint8 parts,
        uint256 price
    ) public {
        price = bound(price, 100e18, 100_000e18);
        longOi = bound(longOi, 0, 3_000_000e18);
        shortOi = bound(shortOi, 0, 3_000_000e18);
        _seedBook(longOi, shortOi, price);
        size = bound(size, 1000e18, 1_000_000e18);
        uint256 n = bound(parts, 2, 6);
        uint256 collateral = size / 5 + 100e18;

        address trader = makeAddr("splitter");
        uint256 fee = _minFee();
        _fund(trader, collateral + (n + 1) * fee);
        uint256 startBalance = usd.balanceOf(trader);
        uint256[] memory ids = new uint256[](n + 1);
        ids[0] = _order(trader, IOrderBook.OrderType.MarketIncrease, isLong, size, collateral, fee);
        for (uint256 i = 1; i < n; ++i) {
            ids[i] = _order(trader, IOrderBook.OrderType.MarketDecrease, isLong, size / n, 0, fee);
        }
        ids[n] = _order(trader, IOrderBook.OrderType.MarketDecrease, isLong, type(uint128).max, 0, fee);

        skip(1);
        IOracleVerifier.SignedPriceReport[] memory r = _reports(price);
        vm.startPrank(keeper);
        orderBook.executeOrder(ids[0], r);
        assertEq(market.getPosition(trader, isLong).sizeUsd, size, "opened");
        for (uint256 i = 1; i <= n; ++i) {
            orderBook.executeOrder(ids[i], r);
        }
        vm.stopPrank();

        assertEq(market.getPosition(trader, isLong).sizeUsd, 0);
        assertLt(usd.balanceOf(trader), startBalance - (n + 1) * fee);
        _assertConservation();
    }

    /// @notice Latency arbitrage is impossible: an order can never be settled with a report whose timestamp is not
    ///         strictly after the order's creation, whatever that report's price is.
    function testFuzz_latency_reportsBeforeOrderAlwaysRejected(uint256 reportAge, uint256 price, bool isLong) public {
        skip(120);
        reportAge = bound(reportAge, 0, 59);
        price = bound(price, 1e18, 1_000_000e18);
        IOracleVerifier.SignedPriceReport[] memory seen = _reportsAt(price, uint64(block.timestamp - reportAge));
        uint256 id = _createOrder(alice, IOrderBook.OrderType.MarketIncrease, isLong, 10_000e18, 2000e18, 0);
        // Keep the reports within the 60 s freshness window so only the ordering rule can reject them.
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(
                IOracleVerifier.ReportPredatesRequest.selector, signer1, block.timestamp - reportAge, block.timestamp
            )
        );
        orderBook.executeOrder(id, seen);
        assertEq(orderBook.getOrder(id).account, alice);
    }

    /// @notice `positionInfo` and `liquidate` agree: a keeper can liquidate exactly when the view says so, and
    ///         a liquidation never breaks custody accounting.
    function testFuzz_liquidation_matchesView(bool isLong, uint256 leverage, uint256 moveBps, uint256 elapsed) public {
        leverage = bound(leverage, 2, 19);
        moveBps = bound(moveBps, 0, 3000);
        elapsed = bound(elapsed, 1, 30 days);
        uint256 size = 100_000e18;
        _open(alice, isLong, size, size / leverage, PRICE0);
        skip(elapsed);
        // Adverse move for the position.
        uint256 price = isLong ? PRICE0 * (10_000 - moveBps) / 10_000 : PRICE0 * (10_000 + moveBps) / 10_000;
        IPerpsMarket.PositionInfo memory info = market.positionInfo(alice, isLong, price);
        IOracleVerifier.SignedPriceReport[] memory r = _reports(price);
        vm.prank(keeper);
        if (info.liquidatable) {
            market.liquidate(alice, isLong, r);
            assertEq(market.getPosition(alice, isLong).sizeUsd, 0);
        } else {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IPerpsMarket.NotLiquidatable.selector, info.remainingCollateral, info.maintenanceMargin
                )
            );
            market.liquidate(alice, isLong, r);
        }
        _assertConservation();
    }
}
