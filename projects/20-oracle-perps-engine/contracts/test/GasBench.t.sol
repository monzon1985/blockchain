// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IOracleVerifier} from "../src/interfaces/IOracleVerifier.sol";
import {IOrderBook} from "../src/interfaces/IOrderBook.sol";
import {PerpsTestBase} from "./utils/PerpsTestBase.sol";

/// @notice Gas benchmarks of the hot paths. `forge snapshot --check --match-contract GasBench` guards the
///         test-level numbers in `.gas-snapshot`; `vm.snapshotGasLastFrame` records the cost of the measured call
///         alone in `snapshots/GasBench.json` (the numbers quoted in the README).
contract GasBench is PerpsTestBase {
    uint256 internal constant SIZE = 100_000e18;
    uint256 internal constant COLLATERAL = 10_000e18;

    function setUp() public override {
        super.setUp();
        _deposit(lp, 1_000_000e18, PRICE0);
        // A resting book so fills touch warm, non-zero aggregates like in production.
        _open(bob, false, 50_000e18, 5000e18, PRICE0);
        _open(carol, true, 80_000e18, 8000e18, PRICE0);
    }

    function test_gas_verifyReports_2of3() public {
        IOracleVerifier.SignedPriceReport[] memory three = _reports(PRICE0);
        IOracleVerifier.SignedPriceReport[] memory two = new IOracleVerifier.SignedPriceReport[](2);
        two[0] = three[0];
        two[1] = three[1];
        oracle.verifyReports(MARKET_ID, two, 0);
        vm.snapshotGasLastFrame("oracle.verifyReports (2 signatures)");
    }

    function test_gas_verifyReports_3of3() public {
        IOracleVerifier.SignedPriceReport[] memory r = _reports(PRICE0);
        oracle.verifyReports(MARKET_ID, r, 0);
        vm.snapshotGasLastFrame("oracle.verifyReports (3 signatures)");
    }

    function test_gas_createOrder_marketIncrease() public {
        uint256 fee = _minFee();
        _fund(alice, COLLATERAL + fee);
        vm.prank(alice);
        orderBook.createOrder(IOrderBook.OrderType.MarketIncrease, true, SIZE, COLLATERAL, 0, type(uint128).max, fee);
        vm.snapshotGasLastFrame("orderBook.createOrder (market increase)");
    }

    function test_gas_executeOrder_openPosition() public {
        uint256 id = _createOrder(alice, IOrderBook.OrderType.MarketIncrease, true, SIZE, COLLATERAL, 0);
        skip(1);
        IOracleVerifier.SignedPriceReport[] memory r = _reports(PRICE0);
        vm.prank(keeper);
        orderBook.executeOrder(id, r);
        vm.snapshotGasLastFrame("orderBook.executeOrder (open position)");
    }

    function test_gas_executeOrder_increasePosition() public {
        _open(alice, true, SIZE, COLLATERAL, PRICE0);
        skip(1 hours);
        uint256 id = _createOrder(alice, IOrderBook.OrderType.MarketIncrease, true, SIZE, COLLATERAL, 0);
        skip(1);
        IOracleVerifier.SignedPriceReport[] memory r = _reports(3050e18);
        vm.prank(keeper);
        orderBook.executeOrder(id, r);
        vm.snapshotGasLastFrame("orderBook.executeOrder (increase, settles fees)");
    }

    function test_gas_executeOrder_closePosition() public {
        _open(alice, true, SIZE, COLLATERAL, PRICE0);
        skip(1 hours);
        uint256 id = _createOrder(alice, IOrderBook.OrderType.MarketDecrease, true, type(uint128).max, 0, 0);
        skip(1);
        IOracleVerifier.SignedPriceReport[] memory r = _reports(3100e18);
        vm.prank(keeper);
        orderBook.executeOrder(id, r);
        vm.snapshotGasLastFrame("orderBook.executeOrder (full close)");
    }

    function test_gas_executeOrder_failedFillCancels() public {
        uint256 id = _createOrder(alice, IOrderBook.OrderType.MarketIncrease, true, SIZE, 1000e18, 0);
        skip(1);
        IOracleVerifier.SignedPriceReport[] memory r = _reports(PRICE0);
        vm.prank(keeper);
        orderBook.executeOrder(id, r);
        vm.snapshotGasLastFrame("orderBook.executeOrder (fill fails, order cancelled)");
    }

    function test_gas_executeOrder_takeProfit() public {
        _open(alice, true, SIZE, COLLATERAL, PRICE0);
        uint256 id = _createOrder(alice, IOrderBook.OrderType.TakeProfit, true, type(uint128).max, 0, 3200e18);
        skip(1);
        IOracleVerifier.SignedPriceReport[] memory r = _reports(3250e18);
        vm.prank(keeper);
        orderBook.executeOrder(id, r);
        vm.snapshotGasLastFrame("orderBook.executeOrder (take-profit)");
    }

    function test_gas_cancelOrder() public {
        uint256 id = _createOrder(alice, IOrderBook.OrderType.MarketIncrease, true, SIZE, COLLATERAL, 0);
        skip(120);
        vm.prank(alice);
        orderBook.cancelOrder(id);
        vm.snapshotGasLastFrame("orderBook.cancelOrder");
    }

    function test_gas_liquidate() public {
        _open(alice, true, SIZE, COLLATERAL, PRICE0);
        skip(1);
        IOracleVerifier.SignedPriceReport[] memory r = _reports(2730e18);
        vm.prank(keeper);
        market.liquidate(alice, true, r);
        vm.snapshotGasLastFrame("market.liquidate");
    }

    function test_gas_autoDeleverage() public {
        _open(alice, true, 650_000e18, 60_000e18, PRICE0);
        skip(1);
        IOracleVerifier.SignedPriceReport[] memory r = _reports(5000e18);
        vm.prank(keeper);
        market.autoDeleverage(alice, true, r);
        vm.snapshotGasLastFrame("market.autoDeleverage");
    }

    function test_gas_requestDeposit() public {
        uint256 fee = _minFee();
        _fund(alice, 10_000e18 + fee);
        vm.prank(alice);
        vault.requestDeposit(10_000e18, 0, fee);
        vm.snapshotGasLastFrame("vault.requestDeposit");
    }

    function test_gas_executeDeposit() public {
        uint256 fee = _minFee();
        _fund(alice, 10_000e18 + fee);
        vm.prank(alice);
        uint256 id = vault.requestDeposit(10_000e18, 0, fee);
        skip(1);
        IOracleVerifier.SignedPriceReport[] memory r = _reports(PRICE0);
        vm.prank(keeper);
        vault.executeRequest(id, r);
        vm.snapshotGasLastFrame("vault.executeRequest (deposit)");
    }

    function test_gas_executeRedeem() public {
        uint256 shares = vault.balanceOf(lp);
        uint256 fee = _minFee();
        _fund(lp, fee);
        vm.prank(lp);
        uint256 id = vault.requestRedeem(shares / 10, 0, fee);
        skip(1);
        IOracleVerifier.SignedPriceReport[] memory r = _reports(PRICE0);
        vm.prank(keeper);
        vault.executeRequest(id, r);
        vm.snapshotGasLastFrame("vault.executeRequest (redeem)");
    }
}
