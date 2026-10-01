// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";

import {LendingSystem} from "./LendingSystem.sol";

/// @notice Foundry stateful invariants over three isolated markets with price shocks, time jumps, liquidations and
///         flash loans. The handler is `LendingSystem`, which Medusa also fuzzes as-is.
contract LendingInvariantsTest is Test {
    LendingSystem internal system;

    function setUp() public {
        system = new LendingSystem();
        bytes4[] memory selectors = new bytes4[](16);
        selectors[0] = LendingSystem.supply.selector;
        selectors[1] = LendingSystem.withdraw.selector;
        selectors[2] = LendingSystem.supplyCollateral.selector;
        selectors[3] = LendingSystem.withdrawCollateral.selector;
        selectors[4] = LendingSystem.borrow.selector;
        selectors[5] = LendingSystem.repay.selector;
        selectors[6] = LendingSystem.liquidate.selector;
        selectors[7] = LendingSystem.liquidate.selector; // liquidations are weighted triple
        selectors[8] = LendingSystem.liquidate.selector;
        selectors[9] = LendingSystem.shockPrice.selector;
        selectors[10] = LendingSystem.shockPrice.selector; // shocks are weighted double
        selectors[11] = LendingSystem.warp.selector;
        selectors[12] = LendingSystem.accrue.selector;
        selectors[13] = LendingSystem.flashLoan.selector;
        selectors[14] = LendingSystem.openPosition.selector;
        selectors[15] = LendingSystem.flashLoan.selector; // flash loans (and their callbacks) are weighted double
        targetSelector(FuzzSelector({addr: address(system), selectors: selectors}));
        targetContract(address(system));
    }

    /// Invariant 1: borrow shares x index == total borrow, within rounding.
    function invariant_borrowSharesTimesIndexEqualsTotalBorrow() public view {
        assertTrue(system.property_borrowSharesTimesIndexEqualsTotalBorrow());
    }

    /// Invariant 2: supply shares add up and claims never exceed total supply.
    function invariant_supplySharesAddUp() public view {
        assertTrue(system.property_supplySharesAddUp());
    }

    /// Invariant 3: no market lends more than it holds.
    function invariant_borrowsCoveredBySupply() public view {
        assertTrue(system.property_borrowsCoveredBySupply());
    }

    /// Invariant 4: the engine holds every token it owes, per token, across markets.
    function invariant_engineIsSolvent() public view {
        assertTrue(system.property_engineIsSolvent());
    }

    /// Invariant 5: no position keeps debt after its collateral is gone.
    function invariant_noZombiePositions() public view {
        assertTrue(system.property_noZombiePositions());
    }

    /// Invariant 6: a liquidation never lowers health except when bad debt is realized.
    function invariant_liquidationNeverLowersHealth() public view {
        assertTrue(system.property_liquidationNeverLowersHealth());
    }

    /// Invariant 7: bad debt is only realized by closeouts that exhaust the collateral.
    function invariant_badDebtOnlyOnCloseout() public view {
        assertTrue(system.property_badDebtOnlyOnCloseout());
    }

    /// Invariant 8: markets are isolated (bad debt and shocks never leak across markets).
    function invariant_marketsAreIsolated() public view {
        assertTrue(system.property_marketsAreIsolated());
    }

    /// Invariant 9: supply share value only decreases through bad debt.
    function invariant_supplyShareValueMonotonic() public view {
        assertTrue(system.property_supplyShareValueMonotonic());
    }

    /// Invariant 10: every operation releases its market lock within its own transaction.
    function invariant_locksReleasedWithinTransaction() public view {
        assertTrue(system.property_locksReleasedWithinTransaction());
    }

    /// Invariant 11: suppliers lose nothing to the liquidation of a position whose collateral still covers its debt.
    function invariant_noSupplierLossWhileCollateralCoversDebt() public view {
        assertTrue(system.property_noSupplierLossWhileCollateralCoversDebt());
    }

    /// Campaign coverage, asserted after every run (and printed with `-vv`): the run liquidated at least one
    /// position, so the liquidation invariants were exercised rather than holding vacuously. Every `liquidate`
    /// action finds or creates a liquidatable position and closes it if the partial it tried is rejected, so a run
    /// without a liquidation means the handler, not the dice, is broken.
    function afterInvariant() public {
        emit log_named_uint("liquidations", system.liquidations());
        emit log_named_uint("  partial", system.partialLiquidations());
        emit log_named_uint("  full repayments", system.fullRepayments());
        emit log_named_uint("  closeouts without bad debt", system.closeoutsWithoutBadDebt());
        emit log_named_uint("  closeouts with bad debt", system.badDebtEvents());
        emit log_named_uint("flash-loan callback actions", system.flashCallbackActions());
        for (uint256 i; i < 8; ++i) {
            emit log_named_uint("conversion calls", system.conversionCalls(i));
        }
        assertGt(system.liquidations(), 0, "the run never liquidated anything");
    }
}
