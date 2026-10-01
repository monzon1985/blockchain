// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {PerpsDeployment} from "../../script/PerpsDeployment.sol";
import {PerpsMarket} from "../../src/PerpsMarket.sol";
import {IOracleVerifier} from "../../src/interfaces/IOracleVerifier.sol";
import {IOrderBook} from "../../src/interfaces/IOrderBook.sol";
import {IPerpsMarket} from "../../src/interfaces/IPerpsMarket.sol";
import {PerpMath} from "../../src/libraries/PerpMath.sol";
import {PerpsTestBase} from "../utils/PerpsTestBase.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice Funding, borrow fees, liquidations and auto-deleveraging with the default (live) risk parameters.
contract PerpsMarketRiskTest is PerpsTestBase {
    uint256 internal constant POOL = 1_000_000e18;

    function setUp() public override {
        super.setUp();
        _deposit(lp, POOL, PRICE0);
    }

    /// @dev Settles an order that only exists to accrue indices and refresh the price at `price`.
    function _poke(uint256 price) internal {
        uint256 id = _createOrder(makeAddr("poker"), IOrderBook.OrderType.MarketDecrease, true, 1, 0, 0);
        _execute(id, price);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Funding
    // ---------------------------------------------------------------------------------------------------------------

    function test_funding_rateDriftsWithSkewAndLongsPay() public {
        _open(alice, true, 1_000_000e18 * 8 / 10, 80_000e18, PRICE0);
        _open(bob, false, 100_000e18, 10_000e18, PRICE0);
        uint256 t0 = block.timestamp;
        int256 r0 = market.fundingRate(); // drifted for one second at the 800k skew before bob's fill
        IPerpsMarket.RiskParams memory p = market.getRiskParams();
        int256 v = PerpMath.fundingVelocity(800_000e18, 100_000e18, p.skewScale, p.maxFundingVelocity);
        assertGt(v, 0);

        skip(3600);
        IPerpsMarket.PositionInfo memory longInfo = market.positionInfo(alice, true, PRICE0);
        IPerpsMarket.PositionInfo memory shortInfo = market.positionInfo(bob, false, PRICE0);
        assertGt(longInfo.fundingFee, 0, "longs owe");
        assertLt(shortInfo.fundingFee, 0, "shorts receive");

        _poke(PRICE0);
        // Below the cap the rate is exactly v * elapsed.
        assertEq(market.fundingRate(), r0 + v * int256(block.timestamp - t0));
        // The pool is the counterparty of the net: it earns funding on the 700k skew.
        uint256 before = usd.balanceOf(bob);
        _close(bob, false, PRICE0);
        assertGt(usd.balanceOf(bob), before);
        IPerpsMarket.MarketStats memory st = market.getStats();
        assertGt(st.fundingPaidToTraders, 0);
        _assertConservation();
    }

    function test_funding_projectionMatchesSettlement() public {
        _open(alice, true, 500_000e18, 50_000e18, PRICE0);
        skip(7200);
        uint256 id = _createOrder(alice, IOrderBook.OrderType.MarketDecrease, true, 100_000e18, 0, 0);
        skip(1);
        IPerpsMarket.PositionInfo memory info = market.positionInfo(alice, true, PRICE0);
        vm.expectEmit(address(market));
        emit IPerpsMarket.FeesSettled(alice, true, info.borrowFee, info.fundingFee);
        vm.prank(keeper);
        orderBook.executeOrder(id, _reports(PRICE0));
    }

    function test_funding_rateSaturatesAtCap() public {
        _open(alice, true, 800_000e18, 80_000e18, PRICE0);
        skip(30 days);
        _poke(PRICE0);
        assertEq(market.fundingRate(), int256(uint256(market.getRiskParams().maxFundingRate)));
    }

    function test_setRiskParams_clampsFundingRate() public {
        _open(alice, true, 800_000e18, 80_000e18, PRICE0);
        skip(30 days);
        _poke(PRICE0);
        IPerpsMarket.RiskParams memory p = market.getRiskParams();
        p.maxFundingRate = 1000;
        bytes memory data = abi.encodeCall(PerpsMarket.setRiskParams, (p));
        vm.prank(riskAdmin);
        sys.manager.schedule(address(market), data, 0);
        skip(1 days);
        vm.prank(riskAdmin);
        sys.manager.execute(address(market), data);
        assertEq(market.fundingRate(), 1000);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Borrow fees
    // ---------------------------------------------------------------------------------------------------------------

    function test_borrowFee_scalesWithUtilisationAndAccruesToPool() public {
        _open(alice, true, 400_000e18, 40_000e18, PRICE0);
        uint256 pool = market.poolAmount();
        uint256 valueBefore = market.poolValueAt(PRICE0);
        skip(1 days);
        uint256 rate = PerpMath.borrowRate(400_000e18, pool, market.getRiskParams().borrowFactor);
        uint256 expected = (rate * 1 days * 400_000e18 + 1e18 - 1) / 1e18;
        IPerpsMarket.PositionInfo memory info = market.positionInfo(alice, true, PRICE0);
        assertEq(info.borrowFee, expected);
        // ~$219/day at 40% utilisation and 50% APR at full utilisation.
        assertApproxEqRel(info.borrowFee, 219e18, 0.01e18);
        // LPs see pending borrow fees immediately (and funding owed by the long skew).
        assertGe(market.poolValueAt(PRICE0), valueBefore + expected - 1);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Liquidation
    // ---------------------------------------------------------------------------------------------------------------

    function test_revert_liquidate_healthyPosition() public {
        _open(alice, true, 100_000e18, 10_000e18, PRICE0);
        skip(1);
        IPerpsMarket.PositionInfo memory info = market.positionInfo(alice, true, PRICE0);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPerpsMarket.NotLiquidatable.selector, info.remainingCollateral, info.maintenanceMargin
            )
        );
        vm.prank(keeper);
        market.liquidate(alice, true, _reports(PRICE0));
    }

    function test_revert_liquidate_noPosition() public {
        vm.expectRevert(abi.encodeWithSelector(IPerpsMarket.NoPosition.selector, alice, true));
        vm.prank(keeper);
        market.liquidate(alice, true, _reports(PRICE0));
    }

    function test_revert_liquidate_withReportNotNewerThanPosition() public {
        _open(alice, true, 100_000e18, 10_000e18, PRICE0);
        // Same second as the fill: the reports do not postdate the position's last update.
        vm.expectRevert(
            abi.encodeWithSelector(
                IOracleVerifier.ReportPredatesRequest.selector, signer1, block.timestamp, block.timestamp
            )
        );
        vm.prank(keeper);
        market.liquidate(alice, true, _reports(2500e18));
    }

    function test_liquidate_paysKeeperAndReturnsRemainder() public {
        _open(alice, true, 100_000e18, 10_000e18, PRICE0);
        skip(1);
        IPerpsMarket.PositionInfo memory info = market.positionInfo(alice, true, 2730e18);
        assertTrue(info.liquidatable);
        assertGt(info.remainingCollateral, 200e18);
        uint256 reward = 100_000e18 * 20 / 10_000;

        uint256 keeperBefore = usd.balanceOf(keeper);
        uint256 aliceBefore = usd.balanceOf(alice);
        vm.expectEmit(address(market));
        emit IPerpsMarket.PositionLiquidated(
            alice,
            true,
            keeper,
            2730e18,
            100_000e18,
            info.remainingCollateral,
            reward,
            uint256(info.remainingCollateral) - reward,
            0
        );
        vm.prank(keeper);
        market.liquidate(alice, true, _reports(2730e18));

        assertEq(usd.balanceOf(keeper) - keeperBefore, reward);
        assertEq(usd.balanceOf(alice) - aliceBefore, uint256(info.remainingCollateral) - reward);
        assertEq(market.getPosition(alice, true).sizeUsd, 0);
        assertEq(market.getStats().liquidations, 1);
        _assertConservation();
    }

    function test_liquidate_gapDownRecordsBadDebt() public {
        _open(alice, true, 100_000e18, 10_000e18, PRICE0);
        skip(1);
        // The liquidation first accrues, which hands one second's share of the impact pool to the LPs.
        uint256 poolBefore = _poolAfterAccrual();
        uint256 collateral = market.getPosition(alice, true).collateral;
        vm.prank(keeper);
        market.liquidate(alice, true, _reports(2500e18));
        IPerpsMarket.MarketStats memory st = market.getStats();
        assertGt(st.badDebt, 0);
        // The pool receives every unit of collateral and nothing more; the keeper gets nothing (pool-first).
        assertEq(market.poolAmount(), poolBefore + collateral);
        _assertConservation();
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Auto-deleveraging
    // ---------------------------------------------------------------------------------------------------------------

    function test_revert_adl_notRequired() public {
        _open(alice, true, 100_000e18, 10_000e18, PRICE0);
        skip(1);
        (, uint256 positive) = market.pnlToPoolFactor(3300e18);
        // The factor is measured after the call accrues (and distributes one second of the impact pool).
        uint256 factor = positive * 1e18 / _poolAfterAccrual();
        vm.expectRevert(abi.encodeWithSelector(IPerpsMarket.AdlNotRequired.selector, factor, 0.45e18));
        vm.prank(keeper);
        market.autoDeleverage(alice, true, _reports(3300e18));
    }

    function test_adl_reducesFactorToTarget() public {
        _open(alice, true, 800_000e18, 60_000e18, PRICE0);
        skip(1);
        (uint256 before,) = market.pnlToPoolFactor(5000e18);
        assertGt(before, 0.45e18);

        vm.prank(keeper);
        market.autoDeleverage(alice, true, _reports(5000e18));
        (uint256 afterFactor,) = market.pnlToPoolFactor(5000e18);
        assertApproxEqAbs(afterFactor, 0.4e18, 0.002e18);
        assertLt(market.getPosition(alice, true).sizeUsd, 800_000e18);
        assertGt(market.getPosition(alice, true).sizeUsd, 0);
        assertEq(market.getStats().autoDeleverages, 1);
        _assertConservation();

        // Below the threshold again: a second ADL is refused.
        skip(1);
        (, uint256 positive) = market.pnlToPoolFactor(5000e18);
        uint256 factorAtCall = positive * 1e18 / _poolAfterAccrual();
        assertLe(factorAtCall, afterFactor);
        vm.expectRevert(abi.encodeWithSelector(IPerpsMarket.AdlNotRequired.selector, factorAtCall, 0.45e18));
        vm.prank(keeper);
        market.autoDeleverage(alice, true, _reports(5000e18));
    }

    function test_revert_adl_unprofitablePosition() public {
        _open(alice, true, 800_000e18, 60_000e18, PRICE0);
        _open(bob, false, 10_000e18, 5000e18, PRICE0);
        skip(1);
        int256 bobPnl = PerpMath.pnl(false, 10_000e18, market.getPosition(bob, false).sizeInTokens, 5000e18);
        vm.expectRevert(abi.encodeWithSelector(IPerpsMarket.AdlPositionNotProfitable.selector, bobPnl));
        vm.prank(keeper);
        market.autoDeleverage(bob, false, _reports(5000e18));
    }

    function test_adl_smallWinnerIsClosedFully() public {
        _open(alice, true, 700_000e18, 60_000e18, PRICE0);
        _open(bob, true, 50_000e18, 5000e18, 4500e18);
        skip(1);
        uint256 before = usd.balanceOf(bob);
        vm.prank(keeper);
        market.autoDeleverage(bob, true, _reports(5200e18));
        assertEq(market.getPosition(bob, true).sizeUsd, 0);
        assertGt(usd.balanceOf(bob) - before, 5000e18);
        _assertConservation();
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Payout backstop
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Funding credits are fronted by the pool. If payers are never liquidated for years (keepers down), a
    ///      receiver's credit can exceed the pool; the settlement then pays at most `maxPnlFactor` of the pool and
    ///      records the rest as a haircut, instead of overdrawing the pool.
    function test_payoutBackstop_haircutsFundingCreditFrontedForDefaultedPayers() public {
        _open(alice, true, 800_000e18, 80_000e18, PRICE0);
        _open(bob, false, 20_000e18, 2000e18, PRICE0);
        skip(6 * 365 days);
        IPerpsMarket.PositionInfo memory info = market.positionInfo(bob, false, PRICE0);
        // After six years the close's accrual first hands the whole impact pool to the LPs.
        uint256 poolBefore = market.poolAmount() + market.impactPoolAmount();
        assertGt(uint256(-info.fundingFee), poolBefore / 2, "credit larger than the payout bound");

        uint256 before = usd.balanceOf(bob);
        _close(bob, false, PRICE0);
        assertEq(market.getPosition(bob, false).sizeUsd, 0, "closed, not refused");
        IPerpsMarket.MarketStats memory st = market.getStats();
        assertGt(st.haircuts, 0);
        assertLe(st.fundingPaidToTraders, poolBefore / 2 + 1);
        assertGt(usd.balanceOf(bob), before);
        assertGe(market.poolAmount(), poolBefore / 2);
        _assertConservation();
    }

    /// @dev Regression (found by the strengthened solvency invariant's payout model): when the backstop cut a
    ///      winner's profit, it also overwrote the funding the winner owed with zero, so a long on a long-heavy book
    ///      escaped its funding payment. Only a funding credit may be cut; funding owed is still collected.
    function test_payoutBackstop_keepsFundingOwedByAHaircutWinner() public {
        _open(alice, true, 700_000e18, 70_000e18, PRICE0);
        _open(bob, true, 100_000e18, 20_000e18, 8000e18);
        skip(1 days);
        uint256 price = 6000e18;
        uint256 id = _createOrder(alice, IOrderBook.OrderType.MarketDecrease, true, type(uint128).max, 0, 0);
        skip(1);
        IPerpsMarket.PositionInfo memory info = market.positionInfo(alice, true, price);
        assertGt(info.fundingFee, 1e18, "longs owe funding on a long-heavy book");
        uint256 paidByTradersBefore = market.getStats().fundingPaidByTraders;

        vm.expectEmit(address(market));
        emit IPerpsMarket.FeesSettled(alice, true, info.borrowFee, info.fundingFee);
        vm.prank(keeper);
        orderBook.executeOrder(id, _reports(price));
        IPerpsMarket.MarketStats memory st = market.getStats();
        assertGt(st.haircuts, 0, "the backstop cut the profit");
        assertEq(st.fundingPaidByTraders - paidByTradersBefore, uint256(info.fundingFee), "funding owed collected");
        _assertConservation();
    }

    /// @dev Regression (found by Medusa through the payout model): when the backstop cut a funding credit, it also
    ///      overwrote the PnL with the capped profit, i.e. zero for a losing position, so the loss was never
    ///      collected. A loser whose pool-fronted credit exceeds the bound now still pays its loss.
    function test_payoutBackstop_keepsLossOfAHaircutLoser() public {
        _open(alice, true, 800_000e18, 80_000e18, PRICE0);
        _open(bob, false, 20_000e18, 2000e18, PRICE0);
        skip(6 * 365 days);
        uint256 price = 3030e18; // +1%: the short loses about $200
        int256 loss = PerpMath.pnl(false, 20_000e18, market.getPosition(bob, false).sizeInTokens, price);
        assertLt(loss, -199e18);
        uint256 id = _createOrder(bob, IOrderBook.OrderType.MarketDecrease, false, type(uint128).max, 0, 0);
        skip(1);
        IPerpsMarket.PositionInfo memory info = market.positionInfo(bob, false, price);
        assertGt(uint256(-info.fundingFee), (market.poolAmount() + market.impactPoolAmount()) / 2, "credit above bound");

        vm.recordLogs();
        vm.prank(keeper);
        orderBook.executeOrder(id, _reports(price));
        IPerpsMarket.MarketStats memory st = market.getStats();
        assertGt(st.haircuts, 0, "the backstop cut the credit");
        assertEq(st.traderLosses, uint256(-loss), "the loss is still collected");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == IPerpsMarket.PositionDecreased.selector) {
                (,, int256 realizedPnl,,,,) =
                    abi.decode(logs[i].data, (uint256, uint256, int256, uint256, int256, uint256, uint256));
                assertEq(realizedPnl, loss, "event reports the loss");
            }
        }
        _assertConservation();
    }

    /// @dev Within-side netting: a winner's PnL can exceed its side's netted PnL (a later long is losing), so the
    ///      pro-rata cap alone would let one settlement take more than the bound. The backstop limits it.
    function test_payoutBackstop_nettedWinnerIsHaircut() public {
        _open(alice, true, 700_000e18, 70_000e18, PRICE0);
        _open(bob, true, 100_000e18, 20_000e18, 8000e18);
        skip(1);
        uint256 pool = market.poolAmount();
        (, uint256 positive) = market.pnlToPoolFactor(6000e18);
        int256 alicePnl = market.positionInfo(alice, true, 6000e18).pnl;
        assertGt(uint256(alicePnl), positive, "winner exceeds the netted side PnL");

        _close(alice, true, 6000e18);
        IPerpsMarket.MarketStats memory st = market.getStats();
        uint256 bound_ = pool * 5 / 10;
        assertApproxEqAbs(st.traderProfits, bound_, 1e18);
        assertGt(st.haircuts, 0);
        assertGe(market.poolAmount(), pool - bound_ - 1e18);
        _assertConservation();
    }
}
