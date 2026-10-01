// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

import {IOracleVerifier} from "../../src/interfaces/IOracleVerifier.sol";
import {IOrderBook} from "../../src/interfaces/IOrderBook.sol";
import {PerpsTestBase} from "../utils/PerpsTestBase.sol";

contract OrderBookTest is PerpsTestBase {
    uint256 internal constant SIZE = 100_000e18;
    uint256 internal constant COLLATERAL = 10_000e18;

    function setUp() public override {
        super.setUp();
        _deposit(lp, 1_000_000e18, PRICE0);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // createOrder
    // ---------------------------------------------------------------------------------------------------------------

    function test_createOrder_escrowsAndStores() public {
        uint256 fee = _minFee();
        _fund(alice, COLLATERAL + fee);
        vm.expectEmit(address(orderBook));
        emit IOrderBook.OrderCreated(
            1, alice, IOrderBook.OrderType.LimitIncrease, true, SIZE, COLLATERAL, 2900e18, 2950e18, fee
        );
        vm.prank(alice);
        uint256 id =
            orderBook.createOrder(IOrderBook.OrderType.LimitIncrease, true, SIZE, COLLATERAL, 2900e18, 2950e18, fee);
        assertEq(id, 1);
        assertEq(orderBook.nextOrderId(), 2);
        assertEq(orderBook.totalEscrow(), COLLATERAL + fee);
        assertEq(usd.balanceOf(address(orderBook)), COLLATERAL + fee);
        IOrderBook.Order memory o = orderBook.getOrder(id);
        assertEq(o.account, alice);
        assertEq(uint8(o.orderType), uint8(IOrderBook.OrderType.LimitIncrease));
        assertTrue(o.isLong);
        assertEq(o.createdAt, block.timestamp);
        assertEq(o.sizeDeltaUsd, SIZE);
        assertEq(o.collateralDelta, COLLATERAL);
        assertEq(o.triggerPrice, 2900e18);
        assertEq(o.acceptablePrice, 2950e18);
        assertEq(o.executionFee, fee);
    }

    function test_createOrder_decreaseEscrowsOnlyFee() public {
        uint256 id = _createOrder(alice, IOrderBook.OrderType.StopLoss, true, SIZE, 5000e18, 2800e18);
        assertEq(orderBook.totalEscrow(), _minFee());
        assertEq(orderBook.getOrder(id).collateralDelta, 5000e18);
    }

    function test_revert_createOrder_validation() public {
        uint256 fee = _minFee();
        _fund(alice, 10 * COLLATERAL);
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(IOrderBook.ExecutionFeeTooLow.selector, fee - 1, fee));
        orderBook.createOrder(
            IOrderBook.OrderType.MarketIncrease, true, SIZE, COLLATERAL, 0, type(uint128).max, fee - 1
        );
        vm.expectRevert(IOrderBook.EmptyOrder.selector);
        orderBook.createOrder(IOrderBook.OrderType.MarketIncrease, true, 0, 0, 0, type(uint128).max, fee);
        vm.expectRevert(abi.encodeWithSelector(IOrderBook.InvalidTriggerPrice.selector, 1));
        orderBook.createOrder(IOrderBook.OrderType.MarketDecrease, true, SIZE, 0, 1, 0, fee);
        vm.expectRevert(abi.encodeWithSelector(IOrderBook.InvalidTriggerPrice.selector, 0));
        orderBook.createOrder(IOrderBook.OrderType.TakeProfit, true, SIZE, 0, 0, 0, fee);
        vm.expectRevert(IOrderBook.EmptyOrder.selector);
        orderBook.createOrder(IOrderBook.OrderType.LimitIncrease, true, 0, COLLATERAL, 2900e18, type(uint128).max, fee);
        vm.expectRevert(); // SafeCast: acceptable price must fit in uint128
        orderBook.createOrder(IOrderBook.OrderType.MarketIncrease, true, SIZE, COLLATERAL, 0, type(uint256).max, fee);
        vm.stopPrank();
    }

    function test_createOrder_pausedBlocksIncreasesOnly() public {
        vm.prank(guardian);
        market.setPaused(true);
        uint256 fee = _minFee();
        _fund(alice, COLLATERAL + 2 * fee);
        vm.startPrank(alice);
        vm.expectRevert(IOrderBook.MarketPaused.selector);
        orderBook.createOrder(IOrderBook.OrderType.LimitIncrease, true, SIZE, COLLATERAL, 1, type(uint128).max, fee);
        orderBook.createOrder(IOrderBook.OrderType.MarketDecrease, true, SIZE, 0, 0, 0, fee);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------------------------------------------------
    // cancelOrder
    // ---------------------------------------------------------------------------------------------------------------

    function test_cancelOrder_afterTimeoutRefundsEverything() public {
        uint256 id = _createOrder(alice, IOrderBook.OrderType.MarketIncrease, true, SIZE, COLLATERAL, 0);
        uint256 createdAt = block.timestamp;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IOrderBook.CancelTooEarly.selector, createdAt + 120));
        orderBook.cancelOrder(id);

        skip(120);
        vm.expectEmit(address(orderBook));
        emit IOrderBook.OrderCancelled(id, alice, "");
        vm.prank(alice);
        orderBook.cancelOrder(id);
        assertEq(usd.balanceOf(alice), COLLATERAL + _minFee());
        assertEq(orderBook.totalEscrow(), 0);
        assertEq(orderBook.getOrder(id).account, address(0));
        _assertConservation();
    }

    function test_cancelOrder_decreaseRefundsFee() public {
        uint256 id = _createOrder(alice, IOrderBook.OrderType.TakeProfit, true, SIZE, 0, 3500e18);
        skip(120);
        vm.prank(alice);
        orderBook.cancelOrder(id);
        assertEq(usd.balanceOf(alice), _minFee());
    }

    function test_revert_cancelOrder_unknownOrNotOwner() public {
        vm.expectRevert(abi.encodeWithSelector(IOrderBook.UnknownOrder.selector, 42));
        orderBook.cancelOrder(42);
        uint256 id = _createOrder(alice, IOrderBook.OrderType.MarketIncrease, true, SIZE, COLLATERAL, 0);
        skip(200);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IOrderBook.NotOrderOwner.selector, bob, alice));
        orderBook.cancelOrder(id);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // executeOrder
    // ---------------------------------------------------------------------------------------------------------------

    function test_revert_executeOrder_unauthorizedOrUnknown() public {
        uint256 id = _createOrder(alice, IOrderBook.OrderType.MarketIncrease, true, SIZE, COLLATERAL, 0);
        skip(1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, alice));
        orderBook.executeOrder(id, _reports(PRICE0));
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IOrderBook.UnknownOrder.selector, 99));
        orderBook.executeOrder(99, _reports(PRICE0));
    }

    /// @dev The latency-arbitrage guard: a price the user could have seen before creating the order never settles it.
    function test_revert_executeOrder_reportNotNewerThanOrder() public {
        IOracleVerifier.SignedPriceReport[] memory seen = _reports(2900e18);
        uint256 id = _createOrder(alice, IOrderBook.OrderType.MarketIncrease, true, SIZE, COLLATERAL, 0);
        skip(10);
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(
                IOracleVerifier.ReportPredatesRequest.selector, signer1, block.timestamp - 10, block.timestamp - 10
            )
        );
        orderBook.executeOrder(id, seen);
    }

    function test_revert_executeOrder_staleReports() public {
        uint256 id = _createOrder(alice, IOrderBook.OrderType.MarketIncrease, true, SIZE, COLLATERAL, 0);
        skip(1);
        IOracleVerifier.SignedPriceReport[] memory r = _reports(PRICE0);
        skip(61);
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(
                IOracleVerifier.StaleReport.selector, signer1, block.timestamp - 61, block.timestamp - 60
            )
        );
        orderBook.executeOrder(id, r);
    }

    function test_executeOrder_canSettleLongAfterCreationWithFreshReports() public {
        uint256 id = _createOrder(alice, IOrderBook.OrderType.MarketIncrease, true, SIZE, COLLATERAL, 0);
        skip(1 hours);
        vm.prank(keeper);
        orderBook.executeOrder(id, _reports(PRICE0));
        assertEq(market.getPosition(alice, true).sizeUsd, SIZE);
    }

    function test_isExecutable() public {
        assertFalse(orderBook.isExecutable(7, PRICE0));
        uint256 m = _createOrder(alice, IOrderBook.OrderType.MarketIncrease, true, SIZE, COLLATERAL, 0);
        uint256 tp = _createOrder(bob, IOrderBook.OrderType.TakeProfit, false, SIZE, 0, 2800e18);
        uint256 sl = _createOrder(carol, IOrderBook.OrderType.StopLoss, true, SIZE, 0, 2800e18);
        assertTrue(orderBook.isExecutable(m, 1));
        assertTrue(orderBook.isExecutable(tp, 2800e18));
        assertFalse(orderBook.isExecutable(tp, 2801e18));
        assertTrue(orderBook.isExecutable(sl, 2799e18));
        assertFalse(orderBook.isExecutable(sl, 2801e18));
    }

    /// @dev Whatever gas a keeper supplies, an order is either filled or left pending: it is never cancelled because
    ///      the fill ran out of gas (empty revert data makes the whole keeper transaction revert).
    function test_executeOrder_underSuppliedGasNeverCancels() public {
        uint256 id = _createOrder(alice, IOrderBook.OrderType.MarketIncrease, true, SIZE, COLLATERAL, 0);
        skip(1);
        IOracleVerifier.SignedPriceReport[] memory r = _reports(PRICE0);
        bytes memory call = abi.encodeCall(orderBook.executeOrder, (id, r));
        bool sawOutOfGasGuard;
        bool sawSuccess;
        for (uint256 g = 150_000; g <= 700_000; g += 1000) {
            uint256 snap = vm.snapshotState();
            vm.prank(keeper);
            (bool ok, bytes memory ret) = address(orderBook).call{gas: g}(call);
            if (ok) {
                sawSuccess = true;
                assertEq(market.getPosition(alice, true).sizeUsd, SIZE, "success must mean filled");
            } else {
                assertEq(orderBook.getOrder(id).account, alice, "failure must leave the order pending");
                if (ret.length == 4 && bytes4(ret) == IOrderBook.ExecutionOutOfGas.selector) sawOutOfGasGuard = true;
            }
            vm.revertToState(snap);
        }
        assertTrue(sawOutOfGasGuard, "guard exercised");
        assertTrue(sawSuccess, "enough gas fills");
    }
}
