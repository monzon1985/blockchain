// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";

import {LendingSystem} from "./LendingSystem.sol";

/// @notice Scripted runs of the invariant handler proving its actions reach every liquidation outcome, all eight
///         conversions and the flash-loan callbacks, so the invariant campaign is not vacuous.
contract LendingSystemSmokeTest is Test {
    LendingSystem internal system;

    function setUp() public {
        system = new LendingSystem();
    }

    function _assertAllPropertiesHold() internal view {
        assertTrue(system.property_liquidationNeverLowersHealth(), "health");
        assertTrue(system.property_badDebtOnlyOnCloseout(), "bad debt");
        assertTrue(system.property_marketsAreIsolated(), "isolation");
        assertTrue(system.property_supplyShareValueMonotonic(), "share value");
        assertTrue(system.property_engineIsSolvent(), "solvency");
        assertTrue(system.property_noZombiePositions(), "zombies");
        assertTrue(system.property_borrowSharesTimesIndexEqualsTotalBorrow(), "borrow shares");
        assertTrue(system.property_supplySharesAddUp(), "supply shares");
        assertTrue(system.property_borrowsCoveredBySupply(), "coverage");
        assertTrue(system.property_locksReleasedWithinTransaction(), "locks");
        assertTrue(system.property_noSupplierLossWhileCollateralCoversDebt(), "supplier loss above water");
    }

    function test_handlerReachesEveryLiquidationOutcome() public {
        for (uint256 m; m < 3; ++m) {
            system.openPosition(m, 0, 100e18, 9900);
            system.openPosition(m, 2, 50e18, 7000);
        }
        // A moderate drop makes the most leveraged positions liquidatable while still solvent.
        for (uint256 m; m < 3; ++m) {
            system.shockPrice(m, 9000);
            system.liquidate(m, 0, 2000, 1); // partial repayment
        }
        assertGt(system.partialLiquidations() + system.fullRepayments(), 0, "no solvent liquidation");
        // Pushed just below the threshold: the threshold borrowers are repaid in full (they keep collateral).
        system.liquidate(0, 3, 10, 3);
        // A crash pushes the rest into insolvency: only closeouts are valid.
        for (uint256 m; m < 3; ++m) {
            system.shockPrice(m, 4000);
            system.liquidate(m, 2, 0, 2); // close by type(uint256).max
            system.liquidate(m, 0, 0, 4); // close by the observed collateral
        }
        assertGt(system.badDebtEvents(), 0, "no under-water closeout");
        assertGt(system.liquidations(), 5);
        _assertAllPropertiesHold();
    }

    function test_handlerReachesCloseoutsCappedAtEquity() public {
        // Nobody is liquidatable yet, so the action moves M0's price until the threshold borrower's health is 0.88:
        // at LLTV 86 % its collateral is worth 0.88 / 0.86 = 1.023x the debt, which covers the debt but not the 5 %
        // bonus. The partial seizure (mode 0) is rejected and the handler closes the position instead.
        system.liquidate(0, 3, 1200, 0);
        assertEq(system.closeoutsWithoutBadDebt(), 1, "no closeout capped at the borrower's equity");
        assertEq(system.badDebtEvents(), 0);
        _assertAllPropertiesHold();
    }

    function test_handlerReachesEveryConversionAndFlashCallback() public {
        for (uint256 m; m < 3; ++m) {
            system.supply(m, 0, 10e18, false);
            system.supply(m, 1, 10e24, true);
            system.withdraw(m, 0, 5000, true);
            system.withdraw(m, 1, 5000, false);
            system.openPosition(m, 1, 20e18, 5000);
            system.borrow(m, 1, 1000, false);
            system.borrow(m, 1, 1000, true);
            system.repay(m, 1, 2000, true);
            system.repay(m, 1, 2000, false);
        }
        for (uint256 i; i < 8; ++i) {
            assertGt(system.conversionCalls(i), 0, "a conversion was never exercised");
        }
        system.flashLoan(0, 5e18, 1, 0); // supply then withdraw inside the callback
        system.shockPrice(0, 4000);
        system.flashLoan(0, 5e18, 2, 0); // flash-funded close
        assertEq(system.flashCallbackActions(), 2);
        _assertAllPropertiesHold();
    }
}
