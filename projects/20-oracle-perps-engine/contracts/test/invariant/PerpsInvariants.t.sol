// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IPerpsMarket} from "../../src/interfaces/IPerpsMarket.sol";
import {PerpsTestBase} from "../utils/PerpsTestBase.sol";
import {ForgePerpsHandler, InvariantParams, PerpsHandler} from "./PerpsHandler.sol";
import {console2} from "forge-std/console2.sol";

/// @notice Stateful invariants over fuzzed price paths. The numbered comments match the README's invariant list.
contract PerpsInvariantTest is PerpsTestBase {
    ForgePerpsHandler internal handler;

    /// @dev Hard open-interest caps low enough to bind (see `InvariantParams`).
    function _riskParams() internal pure override returns (IPerpsMarket.RiskParams memory) {
        return InvariantParams.riskParams();
    }

    function setUp() public override {
        super.setUp();
        handler = new ForgePerpsHandler(market, usd, keeper, [SIGNER1_PK, SIGNER2_PK, SIGNER3_PK], MARKET_ID, PRICE0);

        bytes4[] memory selectors = new bytes4[](15);
        selectors[0] = PerpsHandler.movePrice.selector;
        selectors[1] = PerpsHandler.movePrice.selector; // price moves are weighted double
        selectors[2] = PerpsHandler.passTime.selector;
        selectors[3] = PerpsHandler.openPosition.selector;
        selectors[4] = PerpsHandler.openPosition.selector;
        selectors[5] = PerpsHandler.closePosition.selector;
        selectors[6] = PerpsHandler.withdrawCollateral.selector;
        selectors[7] = PerpsHandler.placeTriggerOrder.selector;
        selectors[8] = PerpsHandler.executeTriggeredOrders.selector;
        selectors[9] = PerpsHandler.cancelExpiredOrders.selector;
        selectors[10] = PerpsHandler.liquidateUnhealthy.selector;
        selectors[11] = PerpsHandler.autoDeleverage.selector;
        selectors[12] = PerpsHandler.lpDeposit.selector;
        selectors[13] = PerpsHandler.lpRedeem.selector;
        selectors[14] = PerpsHandler.roundTrip.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        bytes4[] memory extra = new bytes4[](2);
        extra[0] = PerpsHandler.attemptStaleExecution.selector;
        extra[1] = PerpsHandler.priceShock.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: extra}));
        targetContract(address(handler));
    }

    /// I1. Solvency: at every step, after accruing fees to now, all open positions can be closed at the current
    ///     price, each close pays exactly what an independent model of the capped PnL, fees, impact and payout
    ///     backstop predicts, and the LPs can then redeem the whole pool.
    function invariant_I1_solvency_closeAllThenRedeemAll() public {
        (bool ok, bytes memory detail) = handler.checkSolvency();
        if (!ok) emit log_named_bytes("close-all failure", detail);
        assertTrue(ok, "pool cannot cover the positions, or a payout differs from the model");
    }

    /// I2. Token conservation: each custody contract holds exactly the sum of its accounting buckets.
    function invariant_I2_tokenConservation() public view {
        assertEq(
            usd.balanceOf(address(market)),
            market.poolAmount() + market.impactPoolAmount() + market.totalCollateral(),
            "market"
        );
        assertEq(usd.balanceOf(address(orderBook)), orderBook.totalEscrow(), "order book");
        assertEq(usd.balanceOf(address(vault)), vault.escrowedAssets(), "vault assets");
        assertEq(vault.balanceOf(address(vault)), vault.escrowedShares(), "vault shares");
    }

    /// I3. Open interest (USD and index tokens), collateral and entry sums equal the sums over positions.
    function invariant_I3_openInterestEqualsSumOfPositions() public view {
        for (uint256 s; s < 2; ++s) {
            bool isLong = s == 0;
            IPerpsMarket.SideState memory side = market.getSide(isLong);
            (uint256 size, uint256 tokens,, uint256 bSum, int256 fSum) = handler.sumPositions(isLong);
            assertEq(side.openInterest, size, "OI");
            assertEq(side.openInterestInTokens, tokens, "OI tokens");
            assertEq(side.borrowEntrySum, bSum, "borrow entry sum");
            assertEq(side.fundingEntrySum, fSum, "funding entry sum");
        }
        assertTrue(handler.checkOpenInterest(), "total collateral");
    }

    /// I4. Fee conservation (internal bookkeeping): the pool and impact-pool balances reconcile with the flow
    ///     counters, including the impact pool handed to the LPs.
    function invariant_I4_feeConservation_counters() public view {
        IPerpsMarket.MarketStats memory st = market.getStats();
        assertEq(
            market.poolAmount() + st.lpWithdrawn + st.fundingPaidToTraders + st.traderProfits,
            uint256(st.lpDeposited) + st.positionFees + st.borrowFees + st.fundingPaidByTraders + st.traderLosses
                + st.impactDistributed,
            "pool"
        );
        assertEq(market.impactPoolAmount() + st.impactPaid + st.impactDistributed, st.impactCollected, "impact pool");
    }

    /// I5. Fee conservation (external): tokens traders and LPs moved across the system boundary reconcile with
    ///     positions, escrows, the pool, the impact pool and keeper income.
    function invariant_I5_feeConservation_externalFlows() public view {
        assertTrue(handler.checkFlowConservation(), "flows");
    }

    /// I6. No free round trips: opening and closing at the same oracle price never returns the collateral.
    function invariant_I6_noFreeRoundTrips() public view {
        assertEq(handler.ghostFreeRoundTrips(), 0);
    }

    /// I7. No latency arbitrage: no order was ever filled with reports that are not newer than the order.
    function invariant_I7_noStaleFills() public view {
        assertEq(handler.ghostStaleFills(), 0);
    }

    /// I8. Borrow indices never decrease, and open interest stays within the hard caps (which bind in this
    ///     campaign: see `InvariantParams`).
    function invariant_I8_monotonicIndicesAndCaps() public view {
        assertTrue(handler.checkBorrowIndicesMonotonic(), "borrow index decreased");
        IPerpsMarket.RiskParams memory p = market.getRiskParams();
        assertEq(p.maxLongOpenInterest, InvariantParams.HARD_CAP);
        assertLe(market.getSide(true).openInterest, p.maxLongOpenInterest);
        assertLe(market.getSide(false).openInterest, p.maxShortOpenInterest);
    }

    /// I9. Auto-deleveraging only ever lowers the PnL-to-pool factor.
    function invariant_I9_adlLowersPnlFactor() public view {
        assertFalse(handler.ghostAdlRaisedFactor());
    }

    /// Coverage report of the run (visible with -vv): how often each path was exercised.
    function afterInvariant() external view {
        IPerpsMarket.MarketStats memory st = market.getStats();
        console2.log(
            string.concat(
                "COVERAGE liq=",
                vm.toString(uint256(st.liquidations)),
                " adl=",
                vm.toString(uint256(st.autoDeleverages)),
                " adlRefused=",
                vm.toString(handler.ghostAdlRefusals()),
                " rt=",
                vm.toString(handler.ghostRoundTrips()),
                " stale=",
                vm.toString(handler.ghostStaleAttempts()),
                " badDebt=",
                vm.toString(uint256(st.badDebt) > 0 ? 1 : 0),
                " profits=",
                vm.toString(uint256(st.traderProfits) > 0 ? 1 : 0),
                " haircuts=",
                vm.toString(uint256(st.haircuts) > 0 ? 1 : 0),
                " hardCapBinding=",
                vm.toString(handler.ghostHardCapBinding()),
                " impactDistributed=",
                vm.toString(uint256(st.impactDistributed) > 0 ? 1 : 0)
            )
        );
    }
}
