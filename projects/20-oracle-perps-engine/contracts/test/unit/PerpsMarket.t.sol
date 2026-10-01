// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PerpsDeployment} from "../../script/PerpsDeployment.sol";
import {PerpsMarket} from "../../src/PerpsMarket.sol";
import {IOracleVerifier} from "../../src/interfaces/IOracleVerifier.sol";
import {IOrderBook} from "../../src/interfaces/IOrderBook.sol";
import {IPerpsMarket} from "../../src/interfaces/IPerpsMarket.sol";
import {PerpMath} from "../../src/libraries/PerpMath.sol";
import {MockUSD} from "../mocks/MockUSD.sol";
import {PerpsTestBase} from "../utils/PerpsTestBase.sol";

/// @notice Position mechanics with funding and borrow fees switched off, so every amount is exact.
contract PerpsMarketMechanicsTest is PerpsTestBase {
    uint256 internal constant POOL = 1_000_000e18;
    uint256 internal constant SIZE = 100_000e18;
    uint256 internal constant COLLATERAL = 10_000e18;
    // 100k * 5 bps.
    uint256 internal constant FEE = 50e18;
    // Balanced book to a $100k long imbalance: (1e23)^2 / 1e18 * 5e8 / 1e18.
    uint256 internal constant OPEN_IMPACT = 5e18;
    // Back to balance from a $100k imbalance at the positive factor.
    uint256 internal constant CLOSE_IMPACT = 2.5e18;

    function _riskParams() internal pure override returns (IPerpsMarket.RiskParams memory) {
        return _staticRiskParams();
    }

    function setUp() public override {
        super.setUp();
        _deposit(lp, POOL, PRICE0);
    }

    function _expectCancel(uint256 id, bytes memory reason) internal {
        vm.expectEmit(address(orderBook));
        emit IOrderBook.OrderCancelled(id, keeper, reason);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Wiring and access control
    // ---------------------------------------------------------------------------------------------------------------

    function test_constructor_wiresComponents() public view {
        assertEq(address(orderBook.market()), address(market));
        assertEq(address(vault.market()), address(market));
        assertEq(vault.asset(), address(usd));
        assertEq(address(market.collateralToken()), address(usd));
        assertEq(address(market.oracle()), address(oracle));
        assertEq(market.marketId(), MARKET_ID);
        (uint256 minFee, uint256 timeout, bool isPaused) = market.requestConfig();
        assertEq(minFee, 0.1e18);
        assertEq(timeout, 120);
        assertFalse(isPaused);
    }

    function test_revert_constructor_nonEighteenDecimals() public {
        MockUSD six = new MockUSD(6);
        vm.expectRevert(abi.encodeWithSelector(IPerpsMarket.UnsupportedCollateralDecimals.selector, 6));
        new PerpsMarket(address(sys.manager), IERC20(address(six)), oracle, MARKET_ID, _staticRiskParams(), "LP", "LP");
    }

    function test_revert_componentEntryPoints_unauthorized() public {
        IOrderBook.Order memory o;
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(IPerpsMarket.UnauthorizedCaller.selector, alice));
        market.refreshPrice(_reports(PRICE0), 0);
        vm.expectRevert(abi.encodeWithSelector(IPerpsMarket.UnauthorizedCaller.selector, alice));
        market.fillOrder(o, PRICE0);
        vm.expectRevert(abi.encodeWithSelector(IPerpsMarket.UnauthorizedCaller.selector, alice));
        market.addLiquidity(1);
        vm.expectRevert(abi.encodeWithSelector(IPerpsMarket.UnauthorizedCaller.selector, alice));
        market.removeLiquidity(1, alice);
        vm.stopPrank();

        // The vault may refresh the price but not fill orders.
        vm.prank(address(vault));
        vm.expectRevert(abi.encodeWithSelector(IPerpsMarket.UnauthorizedCaller.selector, address(vault)));
        market.fillOrder(o, PRICE0);
    }

    function test_revert_keeperEntryPoints_unauthorized() public {
        IOracleVerifier.SignedPriceReport[] memory r = _reports(PRICE0);
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, alice));
        market.liquidate(bob, true, r);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, alice));
        market.autoDeleverage(bob, true, r);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, alice));
        market.setPaused(true);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, alice));
        market.setRiskParams(_staticRiskParams());
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Increase
    // ---------------------------------------------------------------------------------------------------------------

    function test_increase_long_chargesFeeAndImpact() public {
        uint256 id = _createOrder(alice, IOrderBook.OrderType.MarketIncrease, true, SIZE, COLLATERAL, 0);
        uint256 keeperBefore = usd.balanceOf(keeper);
        skip(1);
        vm.expectEmit(address(market));
        emit IPerpsMarket.PositionIncreased(
            alice, true, SIZE, COLLATERAL, PRICE0, FEE, -int256(OPEN_IMPACT), SIZE, COLLATERAL - FEE - OPEN_IMPACT
        );
        vm.expectEmit(address(orderBook));
        emit IOrderBook.OrderExecuted(id, keeper, PRICE0, block.timestamp);
        vm.prank(keeper);
        orderBook.executeOrder(id, _reports(PRICE0));

        IPerpsMarket.Position memory p = market.getPosition(alice, true);
        assertEq(p.sizeUsd, SIZE);
        assertEq(p.sizeInTokens, PerpMath.tokensForSize(SIZE, PRICE0, true));
        assertEq(p.collateral, COLLATERAL - FEE - OPEN_IMPACT);
        assertEq(p.lastUpdatedAt, block.timestamp);
        assertEq(market.poolAmount(), POOL + FEE);
        assertEq(market.impactPoolAmount(), OPEN_IMPACT);
        assertEq(market.totalCollateral(), COLLATERAL - FEE - OPEN_IMPACT);
        assertEq(market.getSide(true).openInterest, SIZE);
        assertEq(usd.balanceOf(keeper) - keeperBefore, _minFee());
        assertEq(market.lastPrice(), PRICE0);
        IPerpsMarket.MarketStats memory st = market.getStats();
        assertEq(st.positionFees, FEE);
        assertEq(st.impactCollected, OPEN_IMPACT);
        _assertConservation();
    }

    function test_increase_short_roundsTokensUp() public {
        _open(bob, false, SIZE, COLLATERAL, PRICE0);
        IPerpsMarket.Position memory p = market.getPosition(bob, false);
        assertEq(p.sizeInTokens, PerpMath.tokensForSize(SIZE, PRICE0, false));
        assertEq(p.sizeInTokens, PerpMath.tokensForSize(SIZE, PRICE0, true) + 1);
        assertEq(market.getSide(false).openInterestInTokens, p.sizeInTokens);
    }

    function test_increase_existingPosition_addsSizeAtNewPrice() public {
        _open(alice, true, SIZE, COLLATERAL, PRICE0);
        _open(alice, true, SIZE, COLLATERAL, 3300e18);
        IPerpsMarket.Position memory p = market.getPosition(alice, true);
        assertEq(p.sizeUsd, 2 * SIZE);
        assertEq(
            p.sizeInTokens, PerpMath.tokensForSize(SIZE, PRICE0, true) + PerpMath.tokensForSize(SIZE, 3300e18, true)
        );
        // Second open moves the imbalance 100k -> 200k: 5e8 * (4e46 - 1e46) / 1e36 = $15.
        assertEq(p.collateral, 2 * COLLATERAL - 2 * FEE - OPEN_IMPACT - 15e18);
        _assertConservation();
    }

    function test_increase_collateralOnly() public {
        _open(alice, true, SIZE, COLLATERAL, PRICE0);
        _open(alice, true, 0, 5000e18, PRICE0);
        IPerpsMarket.Position memory p = market.getPosition(alice, true);
        assertEq(p.sizeUsd, SIZE);
        assertEq(p.collateral, COLLATERAL + 5000e18 - FEE - OPEN_IMPACT);
    }

    function test_increase_skewReducingTradeEarnsPositiveImpact() public {
        _open(alice, true, SIZE, COLLATERAL, PRICE0); // impact pool: $5
        // A $100k short rebalances the book: +$2.5 at the positive factor, fully covered by the pool. Each fill
        // happens one second after the previous one, whose accrual hands 1/604,800 of the impact pool to the LPs.
        uint256 impactPool = _decayOneSecond(OPEN_IMPACT);
        _open(bob, false, SIZE, COLLATERAL, PRICE0);
        assertEq(market.getPosition(bob, false).collateral, COLLATERAL - FEE + CLOSE_IMPACT);
        impactPool -= CLOSE_IMPACT;
        assertEq(market.impactPoolAmount(), impactPool);

        // $500k long: imbalance 0 -> 500k costs 5e8 * (5e23)^2 / 1e36 = $125.
        _open(carol, true, 500_000e18, 50_000e18, PRICE0);
        assertEq(market.getPosition(carol, true).collateral, 50_000e18 - 250e18 - 125e18);
        impactPool = _decayOneSecond(impactPool) + 125e18;
        // $500k short brings it back: earns half of that, $62.5.
        address dave = makeAddr("dave");
        _open(dave, false, 500_000e18, 50_000e18, PRICE0);
        assertEq(market.getPosition(dave, false).collateral, 50_000e18 - 250e18 + 62.5e18);
        impactPool = _decayOneSecond(impactPool) - 62.5e18;
        assertEq(market.impactPoolAmount(), impactPool);
        assertEq(market.getStats().impactDistributed, market.getStats().impactCollected - impactPool - 65e18);
        _assertConservation();
    }

    /// @dev Impact-pool balance left after a one-second accrual.
    function _decayOneSecond(uint256 impactPool) internal view returns (uint256) {
        return impactPool - impactPool / market.IMPACT_POOL_DISTRIBUTION_PERIOD();
    }

    /// @dev Liquidations remove open interest without price impact, so the book can be imbalanced while the impact
    ///      pool is nearly empty; a rebalancing trade then earns at most the pool balance.
    function test_increase_positiveImpactClippedToPoolBalance() public {
        _open(alice, true, SIZE, COLLATERAL, PRICE0); // pool 5
        _open(bob, false, 2 * SIZE, 2 * COLLATERAL, PRICE0); // crossover: +2.5 - 5 -> pool 7.5
        // (less the one-second distribution of alice's $5 to the LPs when bob's fill accrued)
        uint256 impactPool = _decayOneSecond(OPEN_IMPACT) + 2.5e18;
        assertEq(market.impactPoolAmount(), impactPool);

        skip(1);
        vm.prank(keeper);
        market.liquidate(alice, true, _reports(2700e18)); // long side emptied, book short-heavy by $200k
        assertEq(market.getSide(true).openInterest, 0);
        impactPool = _decayOneSecond(impactPool);

        // Rebalancing $200k would earn 2.5e8 * (2e23)^2 / 1e36 = $10, but only ~$7.5 is in the pool.
        impactPool = _decayOneSecond(impactPool);
        assertLt(impactPool, 7.5e18);
        _open(carol, true, 2 * SIZE, 2 * COLLATERAL, 2700e18);
        assertEq(market.getPosition(carol, true).collateral, 2 * COLLATERAL - 2 * FEE + impactPool);
        assertEq(market.impactPoolAmount(), 0);
        _assertConservation();
    }

    function test_increase_failures_cancelOrderAndPayKeeper() public {
        // 25x leverage: margin too low. Opening at the mark price shows -1000 wei of PnL (token rounding).
        uint256 id = _createOrder(alice, IOrderBook.OrderType.MarketIncrease, true, SIZE, 4000e18, 0);
        uint256 aliceBefore = usd.balanceOf(alice);
        uint256 keeperBefore = usd.balanceOf(keeper);
        skip(1);
        int256 pnl = PerpMath.pnl(true, SIZE, PerpMath.tokensForSize(SIZE, PRICE0, true), PRICE0);
        assertEq(pnl, -1000);
        int256 effective = int256(4000e18 - FEE - OPEN_IMPACT - FEE) + pnl;
        _expectCancel(id, abi.encodeWithSelector(IPerpsMarket.MarginTooLow.selector, effective, 5000e18));
        vm.prank(keeper);
        orderBook.executeOrder(id, _reports(PRICE0));
        assertEq(usd.balanceOf(alice) - aliceBefore, 4000e18, "collateral refunded");
        assertEq(usd.balanceOf(keeper) - keeperBefore, _minFee(), "keeper still paid");
        assertEq(market.getPosition(alice, true).sizeUsd, 0);
        _assertConservation();

        // Below minimum collateral: $100 at 10x leaves 10 - 0.05 fee - impact dust.
        id = _createOrder(alice, IOrderBook.OrderType.MarketIncrease, true, 100e18, 10e18, 0);
        skip(1);
        // The first order was cancelled, so the book is empty: 5e8 * (100e18)^2 / 1e36 = 5e12 wei of impact.
        uint256 impact = 5e12;
        _expectCancel(
            id, abi.encodeWithSelector(IPerpsMarket.CollateralBelowMinimum.selector, 10e18 - 0.05e18 - impact, 10e18)
        );
        vm.prank(keeper);
        orderBook.executeOrder(id, _reports(PRICE0));

        // Slippage: long fill above the acceptable price.
        uint256 fee = _minFee();
        _fund(alice, COLLATERAL + fee);
        vm.prank(alice);
        id = orderBook.createOrder(IOrderBook.OrderType.MarketIncrease, true, SIZE, COLLATERAL, 0, 2999e18, fee);
        skip(1);
        _expectCancel(id, abi.encodeWithSelector(IPerpsMarket.AcceptablePriceExceeded.selector, PRICE0, 2999e18));
        vm.prank(keeper);
        orderBook.executeOrder(id, _reports(PRICE0));

        // Decrease without a position.
        id = _createOrder(bob, IOrderBook.OrderType.MarketDecrease, true, SIZE, 0, 0);
        skip(1);
        _expectCancel(id, abi.encodeWithSelector(IPerpsMarket.NoPosition.selector, bob, true));
        vm.prank(keeper);
        orderBook.executeOrder(id, _reports(PRICE0));
        _assertConservation();
    }

    function test_increase_openInterestCaps() public {
        // Reserve cap: 80% of the pool per side.
        uint256 poolNow = market.poolAmount();
        uint256 id = _createOrder(alice, IOrderBook.OrderType.MarketIncrease, true, 900_000e18, 100_000e18, 0);
        skip(1);
        _expectCancel(
            id,
            abi.encodeWithSelector(
                IPerpsMarket.OpenInterestCapExceeded.selector, 900_000e18, (poolNow + 450e18) * 8 / 10
            )
        );
        vm.prank(keeper);
        orderBook.executeOrder(id, _reports(PRICE0));

        // Hard cap: lower the long cap through the timelock, then exceed it.
        IPerpsMarket.RiskParams memory p = _staticRiskParams();
        p.maxLongOpenInterest = 50_000e18;
        _setParams(p);
        id = _createOrder(alice, IOrderBook.OrderType.MarketIncrease, true, SIZE, COLLATERAL, 0);
        skip(1);
        _expectCancel(id, abi.encodeWithSelector(IPerpsMarket.OpenInterestCapExceeded.selector, SIZE, 50_000e18));
        vm.prank(keeper);
        orderBook.executeOrder(id, _reports(PRICE0));
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Decrease
    // ---------------------------------------------------------------------------------------------------------------

    function test_decrease_fullCloseInProfit() public {
        _open(alice, true, SIZE, COLLATERAL, PRICE0);
        uint256 tokens = market.getPosition(alice, true).sizeInTokens;
        int256 pnl = PerpMath.pnl(true, SIZE, tokens, 3300e18);
        uint256 expectedOut = COLLATERAL - FEE - OPEN_IMPACT + uint256(pnl) - FEE + CLOSE_IMPACT;

        uint256 before = usd.balanceOf(alice);
        uint256 id = _createOrder(alice, IOrderBook.OrderType.MarketDecrease, true, SIZE, 0, 0);
        skip(1);
        vm.expectEmit(address(market));
        emit IPerpsMarket.PositionDecreased(alice, true, SIZE, 3300e18, pnl, FEE, int256(CLOSE_IMPACT), expectedOut, 0);
        vm.prank(keeper);
        orderBook.executeOrder(id, _reports(3300e18));

        assertEq(usd.balanceOf(alice) - before + _minFee(), expectedOut + _minFee());
        assertEq(market.getPosition(alice, true).sizeUsd, 0);
        assertEq(market.getSide(true).openInterest, 0);
        assertEq(market.getSide(true).openInterestInTokens, 0);
        assertEq(market.totalCollateral(), 0);
        // The close's accrual also handed one second's share of the $5 impact pool to the LPs.
        uint256 distributed = OPEN_IMPACT / market.IMPACT_POOL_DISTRIBUTION_PERIOD();
        assertEq(market.poolAmount(), POOL + 2 * FEE - uint256(pnl) + distributed);
        assertEq(market.getStats().traderProfits, uint256(pnl));
        assertEq(market.getStats().impactDistributed, distributed);
        _assertConservation();
    }

    function test_decrease_fullCloseAtLoss() public {
        _open(alice, true, SIZE, COLLATERAL, PRICE0);
        uint256 tokens = market.getPosition(alice, true).sizeInTokens;
        int256 pnl = PerpMath.pnl(true, SIZE, tokens, 2850e18);
        uint256 before = usd.balanceOf(alice);
        _close(alice, true, 2850e18);
        // `_close` funds and escrows exactly one execution fee, so the balance delta is the collateral paid out.
        uint256 expectedOut = COLLATERAL - FEE - OPEN_IMPACT - uint256(-pnl) - FEE + CLOSE_IMPACT;
        assertEq(usd.balanceOf(alice) - before, expectedOut);
        assertEq(market.getStats().traderLosses, uint256(-pnl));
        _assertConservation();
    }

    function test_decrease_partialRealisesProportionalPnlAndWithdraws() public {
        _open(alice, true, SIZE, COLLATERAL, PRICE0);
        IPerpsMarket.Position memory before = market.getPosition(alice, true);
        int256 totalPnl = PerpMath.pnl(true, SIZE, before.sizeInTokens, 3150e18);

        uint256 id = _createOrder(alice, IOrderBook.OrderType.MarketDecrease, true, SIZE / 4, 1000e18, 0);
        uint256 balBefore = usd.balanceOf(alice);
        _execute(id, 3150e18);
        assertEq(usd.balanceOf(alice) - balBefore, 1000e18);

        IPerpsMarket.Position memory p = market.getPosition(alice, true);
        assertEq(p.sizeUsd, SIZE - SIZE / 4);
        // Longs remove rounded-up tokens.
        assertEq(p.sizeInTokens, before.sizeInTokens - _divUp(before.sizeInTokens, 4));
        int256 realised = PerpMath.mulDivFloor(totalPnl, SIZE / 4, SIZE);
        // Removing $25k of a $100k long imbalance: positive factor * (1e46 - 5.625e45) / 1e36 = $1.09375.
        uint256 impact = 1.09375e18;
        uint256 fee = PerpMath.bpsUp(SIZE / 4, 5);
        assertEq(p.collateral, before.collateral + uint256(realised) - fee + impact - 1000e18);
        _assertConservation();
    }

    function test_decrease_partialWithdrawalBreakingMarginIsCancelled() public {
        _open(alice, true, SIZE, COLLATERAL, PRICE0);
        uint256 id = _createOrder(alice, IOrderBook.OrderType.MarketDecrease, true, 0, 6000e18, 0);
        skip(1);
        vm.recordLogs();
        vm.prank(keeper);
        orderBook.executeOrder(id, _reports(PRICE0));
        // The position is untouched: 3,945 left would be below the 5% initial margin on $100k.
        assertEq(_cancelReasonSelector(), IPerpsMarket.MarginTooLow.selector);
        assertEq(market.getPosition(alice, true).collateral, COLLATERAL - FEE - OPEN_IMPACT);
        _assertConservation();
    }

    function test_decrease_partialBelowMinCollateralIsCancelled() public {
        _open(alice, true, 1000e18, 100e18, PRICE0);
        uint256 id = _createOrder(alice, IOrderBook.OrderType.MarketDecrease, true, 0, 95e18, 0);
        skip(1);
        uint256 remaining = market.getPosition(alice, true).collateral - 95e18;
        _expectCancel(id, abi.encodeWithSelector(IPerpsMarket.CollateralBelowMinimum.selector, remaining, 10e18));
        vm.prank(keeper);
        orderBook.executeOrder(id, _reports(PRICE0));
    }

    function test_decrease_sizeLargerThanPositionIsClamped() public {
        _open(alice, true, SIZE, COLLATERAL, PRICE0);
        _close(alice, true, PRICE0);
        assertEq(market.getPosition(alice, true).sizeUsd, 0);
        _assertConservation();
    }

    function test_decrease_shortSellsAtAcceptablePrice() public {
        _open(bob, false, SIZE, COLLATERAL, PRICE0);
        uint256 fee = _minFee();
        _fund(bob, fee);
        vm.prank(bob);
        // Closing a short buys: the fill must not exceed 2,900.
        uint256 id = orderBook.createOrder(IOrderBook.OrderType.MarketDecrease, false, SIZE, 0, 0, 2900e18, fee);
        skip(1);
        _expectCancel(id, abi.encodeWithSelector(IPerpsMarket.AcceptablePriceExceeded.selector, PRICE0, 2900e18));
        vm.prank(keeper);
        orderBook.executeOrder(id, _reports(PRICE0));
        assertEq(market.getPosition(bob, false).sizeUsd, SIZE);
    }

    /// @dev The flagship property on a concrete trade: an open + close at one oracle price loses fees and impact.
    function test_roundTripAtSamePrice_isNotProfitable() public {
        _open(alice, true, SIZE, COLLATERAL, PRICE0);
        _close(alice, true, PRICE0);
        // The helpers funded collateral + two execution fees; everything else came back except the costs.
        uint256 funded = COLLATERAL + 2 * _minFee();
        uint256 spent = funded - usd.balanceOf(alice);
        // $100 position fees + $5 - $2.5 impact + 1000 wei of token rounding + two execution fees.
        assertEq(spent, 2 * FEE + OPEN_IMPACT - CLOSE_IMPACT + 1000 + 2 * _minFee());
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Trigger orders
    // ---------------------------------------------------------------------------------------------------------------

    function test_limitIncrease_fillsOnlyWhenTriggered() public {
        uint256 id = _createOrder(alice, IOrderBook.OrderType.LimitIncrease, true, SIZE, COLLATERAL, 2900e18);
        skip(1);
        assertFalse(orderBook.isExecutable(id, PRICE0));
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IOrderBook.TriggerNotMet.selector, PRICE0, 2900e18));
        orderBook.executeOrder(id, _reports(PRICE0));
        assertTrue(orderBook.isExecutable(id, 2890e18));
        _execute(id, 2890e18);
        assertEq(market.getPosition(alice, true).sizeUsd, SIZE);
    }

    function test_takeProfitAndStopLoss() public {
        _open(alice, true, SIZE, COLLATERAL, PRICE0);
        _open(bob, false, SIZE, COLLATERAL, PRICE0);
        uint256 tp = _createOrder(alice, IOrderBook.OrderType.TakeProfit, true, SIZE, 0, 3200e18);
        uint256 sl = _createOrder(bob, IOrderBook.OrderType.StopLoss, false, SIZE, 0, 3150e18);
        skip(1);
        vm.startPrank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IOrderBook.TriggerNotMet.selector, 3100e18, 3200e18));
        orderBook.executeOrder(tp, _reports(3100e18));
        vm.expectRevert(abi.encodeWithSelector(IOrderBook.TriggerNotMet.selector, 3100e18, 3150e18));
        orderBook.executeOrder(sl, _reports(3100e18));
        orderBook.executeOrder(tp, _reports(3210e18));
        orderBook.executeOrder(sl, _reports(3210e18));
        vm.stopPrank();
        assertEq(market.getPosition(alice, true).sizeUsd, 0);
        assertEq(market.getPosition(bob, false).sizeUsd, 0);
        _assertConservation();
    }

    // ---------------------------------------------------------------------------------------------------------------
    // PnL cap and pool value
    // ---------------------------------------------------------------------------------------------------------------

    function test_poolValue_marksTraderPnl() public {
        _open(alice, true, SIZE, COLLATERAL, PRICE0);
        uint256 tokens = market.getPosition(alice, true).sizeInTokens;
        int256 pnl = PerpMath.pnl(true, SIZE, tokens, 3300e18);
        assertEq(market.poolValueAt(3300e18), market.poolAmount() - uint256(pnl));
        int256 loss = PerpMath.pnl(true, SIZE, tokens, 2700e18);
        assertEq(market.poolValueAt(2700e18), market.poolAmount() + uint256(-loss));
        assertEq(vault.totalAssets(), market.poolValueAt(market.lastPrice()));
    }

    function test_profitCap_scalesPayoutAndPoolValue() public {
        // $800k long; +66.7% move gives $533k PnL against a ~$1M pool, above the 50% cap.
        _open(alice, true, 800_000e18, 60_000e18, PRICE0);
        uint256 pool = market.poolAmount();
        uint256 cap = pool / 2;
        (uint256 factor, uint256 positive) = market.pnlToPoolFactor(5000e18);
        assertGt(positive, cap);
        assertEq(factor, positive * 1e18 / pool);
        // LP valuation only subtracts the capped PnL.
        assertEq(market.poolValueAt(5000e18), pool - cap);

        uint256 before = usd.balanceOf(alice);
        // The close one second later first distributes 1/604,800 of the impact pool, which raises the cap a little.
        cap = (pool + _impactDistribution(1)) / 2;
        _close(alice, true, 5000e18);
        uint256 paidProfit = market.getStats().traderProfits;
        assertEq(paidProfit, cap);
        assertGt(usd.balanceOf(alice) - before, cap);
        assertGe(market.poolAmount(), pool - cap);
        _assertConservation();
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Governance
    // ---------------------------------------------------------------------------------------------------------------

    function _setParams(IPerpsMarket.RiskParams memory p) internal {
        bytes memory data = abi.encodeCall(PerpsMarket.setRiskParams, (p));
        vm.prank(riskAdmin);
        sys.manager.schedule(address(market), data, 0);
        skip(1 days);
        vm.prank(riskAdmin);
        sys.manager.execute(address(market), data);
    }

    function test_setRiskParams_timelocked() public {
        IPerpsMarket.RiskParams memory p = _staticRiskParams();
        p.positionFeeBps = 10;
        vm.prank(riskAdmin);
        vm.expectRevert(); // must be scheduled first
        market.setRiskParams(p);
        _setParams(p);
        assertEq(market.getRiskParams().positionFeeBps, 10);
    }

    function test_revert_setRiskParams_bounds() public {
        IPerpsMarket.RiskParams memory base = _staticRiskParams();
        IPerpsMarket.RiskParams[] memory bad = new IPerpsMarket.RiskParams[](15);
        uint256[] memory code = new uint256[](15);
        for (uint256 i; i < 15; ++i) {
            bad[i] = _staticRiskParams();
        }
        bad[0].reserveFactor = 0;
        code[0] = 1;
        bad[1].adlTargetFactor = base.adlThresholdFactor;
        code[1] = 2;
        bad[2].positionFeeBps = 101;
        code[2] = 3;
        bad[3].maintenanceMarginBps = base.initialMarginBps;
        code[3] = 4;
        bad[4].liquidationFeeBps = base.maintenanceMarginBps;
        code[4] = 5;
        bad[5].positiveImpactFactor = base.negativeImpactFactor + 1;
        code[5] = 6;
        bad[6].skewScale = 0;
        code[6] = 7;
        bad[7].orderTimeout = 9;
        code[7] = 8;
        bad[8].maxPnlFactor = 1e18;
        code[8] = 2;
        // Ceilings: one wei above each of them.
        bad[9].borrowFactor = uint64(MAX_BORROW_FACTOR + 1);
        code[9] = 9;
        bad[10].maxFundingRate = uint64(MAX_FUNDING_RATE + 1);
        code[10] = 10;
        bad[11].maxFundingVelocity = uint64(MAX_FUNDING_VELOCITY + 1);
        code[11] = 10;
        bad[12].negativeImpactFactor = uint128(MAX_IMPACT_FACTOR + 1);
        code[12] = 11;
        bad[13].minExecutionFee = uint128(MAX_EXECUTION_FEE + 1);
        code[13] = 12;
        bad[14].minCollateral = uint128(MAX_MIN_COLLATERAL + 1);
        code[14] = 12;
        for (uint256 i; i < 15; ++i) {
            vm.expectRevert(abi.encodeWithSelector(IPerpsMarket.InvalidRiskParams.selector, code[i]));
            new PerpsMarket(address(sys.manager), IERC20(address(usd)), oracle, MARKET_ID, bad[i], "LP", "LP");
        }
    }

    // Ceilings of `PerpsMarket._setRiskParams`, restated so a silent change to them fails these tests.
    uint256 internal constant MAX_BORROW_FACTOR = 158_548_959_918; // 5 / 31_536_000 per second: 500% APR
    uint256 internal constant MAX_FUNDING_RATE = 2_777_777_777_777; // 0.01 / 3600 per second: 1%/h
    uint256 internal constant MAX_FUNDING_VELOCITY = 40_187_750; // 10x the default 3%/day per day
    uint256 internal constant MAX_IMPACT_FACTOR = 5e9; // $5,000 on a $1M skew
    uint256 internal constant MAX_EXECUTION_FEE = 10e18;
    uint256 internal constant MAX_MIN_COLLATERAL = 1000e18;

    /// @dev A compromised risk admin is limited to the ceilings: exactly at them the parameters are accepted, and
    ///      the worst borrow rate then charges 500% a year at full utilisation instead of the whole collateral.
    function test_setRiskParams_acceptsValuesAtTheCeilings() public {
        IPerpsMarket.RiskParams memory p = _staticRiskParams();
        p.borrowFactor = uint64(MAX_BORROW_FACTOR);
        p.maxFundingRate = uint64(MAX_FUNDING_RATE);
        p.maxFundingVelocity = uint64(MAX_FUNDING_VELOCITY);
        p.negativeImpactFactor = uint128(MAX_IMPACT_FACTOR);
        p.positiveImpactFactor = uint128(MAX_IMPACT_FACTOR);
        p.minExecutionFee = uint128(MAX_EXECUTION_FEE);
        p.minCollateral = uint128(MAX_MIN_COLLATERAL);
        _setParams(p);
        IPerpsMarket.RiskParams memory stored = market.getRiskParams();
        assertEq(stored.borrowFactor, MAX_BORROW_FACTOR);
        assertEq(stored.maxFundingRate, MAX_FUNDING_RATE);
        assertEq(stored.maxFundingVelocity, MAX_FUNDING_VELOCITY);
        assertEq(stored.negativeImpactFactor, MAX_IMPACT_FACTOR);
        assertEq(stored.minExecutionFee, MAX_EXECUTION_FEE);
        assertEq(stored.minCollateral, MAX_MIN_COLLATERAL);
        // 500% APR in WAD per second, within the rounding of the integer division.
        assertApproxEqRel(uint256(stored.borrowFactor) * 365 days, 5e18, 1e9);
    }

    /// @dev The ceilings also bind on the timelocked governance path, not only at construction.
    function test_revert_setRiskParams_ceilingThroughTimelock() public {
        IPerpsMarket.RiskParams memory p = _staticRiskParams();
        p.borrowFactor = type(uint64).max;
        bytes memory data = abi.encodeCall(PerpsMarket.setRiskParams, (p));
        vm.prank(riskAdmin);
        sys.manager.schedule(address(market), data, 0);
        skip(1 days);
        vm.prank(riskAdmin);
        vm.expectRevert(abi.encodeWithSelector(IPerpsMarket.InvalidRiskParams.selector, 9));
        sys.manager.execute(address(market), data);
    }

    function test_pause_blocksNewRiskOnly() public {
        _open(alice, true, SIZE, COLLATERAL, PRICE0);
        vm.prank(guardian);
        market.setPaused(true);
        assertTrue(market.paused());

        _fund(bob, COLLATERAL + _minFee());
        vm.prank(bob);
        vm.expectRevert(IOrderBook.MarketPaused.selector);
        orderBook.createOrder(IOrderBook.OrderType.MarketIncrease, true, SIZE, COLLATERAL, 0, type(uint128).max, 1e18);
        vm.prank(bob);
        vm.expectRevert();
        vault.requestDeposit(1e18, 0, 1e18);

        // Closing still works.
        _close(alice, true, PRICE0);
        assertEq(market.getPosition(alice, true).sizeUsd, 0);

        vm.prank(guardian);
        market.setPaused(false);
        _open(bob, true, SIZE, COLLATERAL, PRICE0);
    }

    function test_positionInfo_emptyPosition() public view {
        IPerpsMarket.PositionInfo memory info = market.positionInfo(alice, true, PRICE0);
        assertEq(info.pnl, 0);
        assertFalse(info.liquidatable);
        assertEq(market.getSide(false).openInterest, 0);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Impact pool distribution
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Negative impact that positive impact never pays back reaches the LPs over 7 days instead of staying
    ///      stranded in the market.
    function test_impactPool_distributesToLpsOverTime() public {
        _open(alice, true, 500_000e18, 50_000e18, PRICE0); // imbalance 0 -> 500k: $125 into the impact pool
        uint256 impactPool = market.impactPoolAmount();
        assertEq(impactPool, 125e18);
        uint256 pool = market.poolAmount();
        uint256 value = market.poolValueAt(PRICE0);

        // An order that cannot fill (bob has no position) still accrues the market when the keeper settles it.
        uint256 id = _createOrder(bob, IOrderBook.OrderType.MarketDecrease, true, 1, 0, 0);
        skip(1 days);
        uint256 expected = impactPool * 1 days / market.IMPACT_POOL_DISTRIBUTION_PERIOD();
        // LP pricing includes the pending distribution before anything accrues.
        assertEq(market.poolValueAt(PRICE0), value + expected);
        vm.expectEmit(address(market));
        emit IPerpsMarket.ImpactPoolDistributed(expected, pool + expected);
        vm.prank(keeper);
        orderBook.executeOrder(id, _reports(PRICE0));
        assertEq(market.impactPoolAmount(), impactPool - expected);
        assertEq(market.poolAmount(), pool + expected);
        assertEq(market.getStats().impactDistributed, expected);
        assertEq(market.poolValueAt(PRICE0), value + expected);

        // After a full period without accrual, the remainder goes in one step.
        id = _createOrder(bob, IOrderBook.OrderType.MarketDecrease, true, 1, 0, 0);
        skip(7 days);
        vm.prank(keeper);
        orderBook.executeOrder(id, _reports(PRICE0));
        assertEq(market.impactPoolAmount(), 0);
        assertEq(market.poolAmount(), pool + impactPool);
        assertEq(market.getStats().impactDistributed, impactPool);
        _assertConservation();
    }

    /// @dev Once every position is closed and the impact pool has been distributed, redeeming every share leaves
    ///      nothing but rounding dust in the market.
    function test_impactPool_lastLpRedeemsEverything() public {
        _open(alice, true, 500_000e18, 50_000e18, PRICE0);
        _close(alice, true, PRICE0);
        assertGt(market.impactPoolAmount(), 0);
        skip(7 days);
        uint256 shares = vault.balanceOf(lp);
        uint256 fee = _minFee();
        _fund(lp, fee);
        vm.prank(lp);
        uint256 id = vault.requestRedeem(shares, 0, fee);
        skip(1);
        vm.prank(keeper);
        vault.executeRequest(id, _reports(PRICE0));
        assertEq(vault.totalSupply(), 0);
        assertEq(market.impactPoolAmount(), 0);
        assertLe(usd.balanceOf(address(market)), 1, "only rounding dust is left");
        _assertConservation();
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Auto-deleveraging with side netting
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Regression for a review finding: a winner on a side whose netted PnL is negative was ranked first by
    ///      PnL per unit of size, and deleveraging it paid ~$89k out of the pool while aggregate positive PnL (the
    ///      other side's) stayed put, so the PnL-to-pool factor rose. ADL now requires the factor to fall; the
    ///      winner on the profitable side can still be deleveraged.
    function test_revert_adl_winnerOnNetLosingSideWouldRaiseFactor() public {
        _deposit(lp, 1_000_000e18, PRICE0); // $2M pool
        _open(bob, true, 1_000_000e18, 1_000_000e18, 4000e18);
        _open(carol, false, 1_500_000e18, 150_000e18, 4000e18);
        _open(alice, true, 100_000e18, 10_000e18, 500e18);
        skip(1);

        uint256 price = 1000e18;
        int256 alicePnl = market.positionInfo(alice, true, price).pnl;
        int256 carolPnl = market.positionInfo(carol, false, price).pnl;
        // Ranked by PnL per unit of size, alice (1.0) comes before carol (0.75)...
        assertGt(uint256(alicePnl) * 1e18 / 100_000e18, uint256(carolPnl) * 1e18 / 1_500_000e18);
        // ...but the long side nets to a loss: only carol's PnL counts as aggregate positive PnL.
        (, uint256 positive) = market.pnlToPoolFactor(price);
        assertEq(positive, uint256(carolPnl));
        uint256 pool = _poolAfterAccrual();
        uint256 factorBefore = positive * 1e18 / pool;
        assertGt(factorBefore, 0.45e18);

        // Paying alice's capped profit shrinks the pool and leaves positive PnL unchanged.
        uint256 paid = uint256(alicePnl) * (pool / 2) / positive;
        uint256 factorAfter = positive * 1e18 / (pool - paid);
        assertGt(factorAfter, factorBefore);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IPerpsMarket.AdlDoesNotReduceFactor.selector, factorBefore, factorAfter));
        market.autoDeleverage(alice, true, _reports(price));

        // The winner on the net-profitable side is deleveraged and the factor falls.
        vm.prank(keeper);
        market.autoDeleverage(carol, false, _reports(price));
        (uint256 afterCarol,) = market.pnlToPoolFactor(price);
        assertLt(afterCarol, factorBefore);
        assertEq(market.getStats().autoDeleverages, 1);
        _assertConservation();
    }

    // ---------------------------------------------------------------------------------------------------------------
    // InsufficientCollateral (all three sites)
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Increase: the position fee ($250) and the impact ($125) of a $500k open exceed $100 of collateral.
    function test_increase_collateralBelowCostsIsCancelled() public {
        uint256 id = _createOrder(alice, IOrderBook.OrderType.MarketIncrease, true, 500_000e18, 100e18, 0);
        skip(1);
        _expectCancel(id, abi.encodeWithSelector(IPerpsMarket.InsufficientCollateral.selector, 100e18, 275e18));
        vm.prank(keeper);
        orderBook.executeOrder(id, _reports(PRICE0));
        assertEq(market.getPosition(alice, true).sizeUsd, 0);
        _assertConservation();
    }

    /// @dev Partial decrease: the realised loss of 90% of an underwater 10x long exceeds its collateral. A partial
    ///      decrease cannot create bad debt; only a full close or a liquidation can.
    function test_decrease_partialLossBeyondCollateralIsCancelled() public {
        _open(alice, true, SIZE, COLLATERAL, PRICE0);
        IPerpsMarket.Position memory pos = market.getPosition(alice, true);
        uint256 price = 2600e18;
        uint256 delta = SIZE * 9 / 10;
        int256 realised = PerpMath.mulDivFloor(PerpMath.pnl(true, SIZE, pos.sizeInTokens, price), delta, SIZE);
        // Removing $90k of a $100k long imbalance earns positive impact: 2.5e8 * (1e46 - 1e44) / 1e36.
        uint256 impact = 2.475e18;
        uint256 shortfall = uint256(-realised) + PerpMath.bpsUp(delta, 5) - (pos.collateral + impact);
        uint256 id = _createOrder(alice, IOrderBook.OrderType.MarketDecrease, true, delta, 0, 0);
        skip(1);
        _expectCancel(
            id, abi.encodeWithSelector(IPerpsMarket.InsufficientCollateral.selector, pos.collateral, shortfall)
        );
        vm.prank(keeper);
        orderBook.executeOrder(id, _reports(price));
        assertEq(market.getPosition(alice, true).sizeUsd, SIZE);
    }

    /// @dev Collateral withdrawal: the error reports what is available and the part of the request it cannot cover.
    function test_decrease_withdrawalAboveCollateralIsCancelled() public {
        _open(alice, true, SIZE, COLLATERAL, PRICE0);
        uint256 collateral = market.getPosition(alice, true).collateral;
        uint256 id = _createOrder(alice, IOrderBook.OrderType.MarketDecrease, true, 0, 20_000e18, 0);
        skip(1);
        _expectCancel(
            id, abi.encodeWithSelector(IPerpsMarket.InsufficientCollateral.selector, collateral, 20_000e18 - collateral)
        );
        vm.prank(keeper);
        orderBook.executeOrder(id, _reports(PRICE0));
        assertEq(market.getPosition(alice, true).collateral, collateral);
    }

    function _divUp(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a + b - 1) / b;
    }
}

