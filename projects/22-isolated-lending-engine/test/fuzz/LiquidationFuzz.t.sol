// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {BaseTest} from "../utils/BaseTest.sol";

import {ILendingEngine, Market, Position} from "../../src/interfaces/ILendingEngine.sol";
import {LiquidationMath, ORACLE_PRICE_SCALE} from "../../src/libraries/LiquidationMath.sol";
import {WAD} from "../../src/libraries/MathLib.sol";

/// @notice Exposes the pure schedule for property tests.
contract LiquidationMathHarness {
    function bonus(uint256 health, uint256 maxBonus, uint256 slope) external pure returns (uint256) {
        return LiquidationMath.liquidationBonus(health, maxBonus, slope);
    }

    function healthFactor(uint256 maxBorrow, uint256 debt) external pure returns (uint256) {
        return LiquidationMath.healthFactor(maxBorrow, debt);
    }
}

/// @notice Bounded fuzz of the liquidation rules on the real engine.
/// @dev With LLTV 86 % and a 5 % bonus cap, a position is "solvent for the bonus" (collateral value >= debt * (1 +
///      bonus)) whenever its health is at least ~0.903, and "above water" (collateral value >= debt) whenever it is at
///      least 0.86. The tests use health >= 0.91 for the solvent region and <= 0.89 for the insolvent one so the
///      fuzzed price rounding never straddles the boundary.
///
///      Every fuzzed position shares its market with a second borrower and is opened after interest has accrued at a
///      30 % rate for a fuzzed time, so the debt share price is not the round 1e-6 of a fresh market and share
///      rounding is exercised on both sides of every liquidation.
contract LiquidationFuzzTest is BaseTest {
    LiquidationMathHarness internal harness;

    function setUp() public override {
        super.setUp();
        harness = new LiquidationMathHarness();
        loanToken.mint(liquidator, type(uint128).max);
    }

    /// @dev Opens a second borrower's position, lets interest accrue for a time derived from the inputs, opens a
    ///      position of `collateral` at 50-100 % of its borrowing capacity, accrues again, then moves the price so its
    ///      health factor is ~`targetHealth`.
    function _unhealthyPosition(uint256 collateral, uint256 utilization, uint256 targetHealth)
        internal
        returns (uint256 health)
    {
        collateral = bound(collateral, 1e12, 1e30);
        // Below 100 %: at a share price that is not round, borrowing the exact capacity can round the debt one unit
        // above it.
        utilization = bound(utilization, 0.5e18, 0.99e18);
        uint256 entropy = uint256(keccak256(abi.encode(collateral, utilization, targetHealth)));

        address other = makeAddr("otherBorrower");
        _approveAll(other);
        irm.setRate(uint256(0.3e18) / 365 days);
        _openPosition(other, 1e18 + entropy % 1e27, 0.7e18);
        skip(1 + entropy % 400 days);
        engine.accrueInterest(marketParams);

        _openPosition(borrower, collateral, LLTV * utilization / WAD);
        skip(1 + (entropy >> 128) % 30 days);
        engine.accrueInterest(marketParams);
        irm.setRate(0);

        Market memory m = _market();
        assertTrue(uint256(m.totalBorrowShares) != uint256(m.totalBorrowAssets) * 1e6, "share price is still round");
        _setHealth(borrower, targetHealth);
        health = _healthOf(borrower);
    }

    function _isExpectedLiquidationRevert(bytes memory reason) internal pure returns (bool) {
        bytes4 selector = bytes4(reason);
        return selector == ILendingEngine.HealthDecreased.selector
            || selector == ILendingEngine.RepayExceedsDebt.selector
            || selector == ILendingEngine.SeizeExceedsCollateral.selector;
    }

    /// Property: a successful liquidation either realizes bad debt (collateral exhausted, debt written off) or leaves
    /// the health factor at least where it was.
    function testFuzz_liquidationNeverLowersHealthUnlessBadDebt(
        uint256 collateral,
        uint256 utilization,
        uint256 targetHealth,
        uint256 amount,
        bool bySeizure
    ) public {
        targetHealth = bound(targetHealth, 0.2e18, 0.9999e18);
        uint256 healthBefore = _unhealthyPosition(collateral, utilization, targetHealth);
        Position memory p = _position(borrower);

        // Up to 1.2x the position, so closes (requests covering the whole position) are included.
        uint256 seized = bySeizure ? bound(amount, 1, uint256(p.collateral) * 12 / 10) : 0;
        uint256 repaidShares = bySeizure ? 0 : bound(amount, 1, uint256(p.borrowShares) * 12 / 10);

        vm.prank(liquidator);
        try engine.liquidate(marketParams, borrower, seized, repaidShares, "") {
            Position memory after_ = _position(borrower);
            if (after_.collateral == 0) {
                assertEq(after_.borrowShares, 0, "exhausted collateral must write off the residual debt");
            } else {
                assertGe(_healthOf(borrower), healthBefore, "health decreased without bad debt");
            }
        } catch (bytes memory reason) {
            assertTrue(_isExpectedLiquidationRevert(reason), "unexpected revert");
        }
    }

    /// Property (liveness): every unhealthy position can be closed in one call, denominated on either side, and the
    /// close leaves no debt.
    function testFuzz_unhealthyPositionCanAlwaysBeClosed(
        uint256 collateral,
        uint256 utilization,
        uint256 targetHealth,
        bool bySeizure
    ) public {
        targetHealth = bound(targetHealth, 0.05e18, 0.9999e18);
        uint256 health = _unhealthyPosition(collateral, utilization, targetHealth);
        assertLt(health, WAD);
        Position memory p = _position(borrower);

        vm.prank(liquidator);
        if (bySeizure) engine.liquidate(marketParams, borrower, p.collateral, 0, "");
        else engine.liquidate(marketParams, borrower, 0, p.borrowShares, "");
        assertEq(_position(borrower).borrowShares, 0, "debt left after a close");
    }

    /// Property (griefing resistance): a dust collateral deposit or a dust repayment sent in front of a close cannot
    /// make it revert. The repay side works with the observed shares; the seize side with `type(uint256).max`.
    function testFuzz_dustFrontRunCannotBlockClose(
        uint256 collateral,
        uint256 utilization,
        uint256 targetHealth,
        uint256 dust,
        bool repayDust,
        bool bySeizure
    ) public {
        targetHealth = bound(targetHealth, 0.05e18, 0.9999e18);
        _unhealthyPosition(collateral, utilization, targetHealth);
        Position memory observed = _position(borrower);

        if (repayDust) {
            dust = bound(dust, 1, observed.borrowShares > 1e6 ? 1e6 : observed.borrowShares - 1);
            loanToken.mint(borrower, _debtOf(borrower));
            vm.prank(borrower);
            engine.repay(marketParams, 0, dust, borrower, "");
        } else {
            _supplyCollateral(borrower, bound(dust, 1, 1e6));
        }
        vm.assume(_healthOf(borrower) < WAD); // a repayment can make the position healthy again

        vm.prank(liquidator);
        if (bySeizure) engine.liquidate(marketParams, borrower, type(uint256).max, 0, "");
        else engine.liquidate(marketParams, borrower, 0, observed.borrowShares, "");
        assertEq(_position(borrower).borrowShares, 0);
    }

    /// Property: suppliers lose nothing to any liquidation of a position whose collateral is still worth its debt,
    /// and bad debt is written off only when the position was under water.
    function testFuzz_noSupplierLossWhileCollateralCoversDebt(
        uint256 collateral,
        uint256 utilization,
        uint256 targetHealth,
        uint256 amount,
        bool bySeizure
    ) public {
        targetHealth = bound(targetHealth, 0.5e18, 0.9999e18);
        _unhealthyPosition(collateral, utilization, targetHealth);
        Position memory p = _position(borrower);
        bool aboveWater = LiquidationMath.collateralValue(p.collateral, oracle.currentPrice()) >= _debtOf(borrower);
        uint256 supplyBefore = _market().totalSupplyAssets;

        // Anything from a sliver of the position to twice its size (oversized requests close it).
        uint256 seized = bySeizure ? bound(amount, 1, 2 * uint256(p.collateral)) : 0;
        uint256 repaidShares = bySeizure ? 0 : bound(amount, 1, 2 * uint256(p.borrowShares));
        vm.prank(liquidator);
        try engine.liquidate(marketParams, borrower, seized, repaidShares, "") {
            if (aboveWater) assertEq(_market().totalSupplyAssets, supplyBefore, "supplier loss above water");
            else if (_market().totalSupplyAssets < supplyBefore) assertEq(_position(borrower).collateral, 0);
        } catch (bytes memory reason) {
            assertTrue(_isExpectedLiquidationRevert(reason), "unexpected revert");
        }
    }

    /// Property: when collateral covers debt plus bonus, partial liquidations are never blocked and raise health.
    function testFuzz_partialLiquidationImprovesSolventPosition(
        uint256 collateral,
        uint256 utilization,
        uint256 targetHealth,
        uint256 fraction
    ) public {
        targetHealth = bound(targetHealth, 0.91e18, 0.9999e18);
        uint256 healthBefore = _unhealthyPosition(collateral, utilization, targetHealth);
        fraction = bound(fraction, 0.01e18, 0.99e18);
        uint256 repaidShares = uint256(_position(borrower).borrowShares) * fraction / WAD;

        vm.prank(liquidator);
        engine.liquidate(marketParams, borrower, 0, repaidShares, "");
        assertGe(_healthOf(borrower), healthBefore);
        assertGt(_position(borrower).collateral, 0);
    }

    /// Property: when collateral no longer covers debt plus bonus, every partial liquidation is rejected.
    function testFuzz_partialLiquidationRejectedForInsolventPosition(
        uint256 collateral,
        uint256 utilization,
        uint256 targetHealth,
        uint256 fraction
    ) public {
        targetHealth = bound(targetHealth, 0.2e18, 0.89e18);
        _unhealthyPosition(collateral, utilization, targetHealth);
        fraction = bound(fraction, 0.01e18, 0.99e18);
        uint256 seized = uint256(_position(borrower).collateral) * fraction / WAD;

        vm.expectPartialRevert(ILendingEngine.HealthDecreased.selector);
        vm.prank(liquidator);
        engine.liquidate(marketParams, borrower, seized, 0, "");
    }

    /// Property: the bonus is non-decreasing in the health deficit and never exceeds its cap.
    function testFuzz_bonusMonotonicInDeficit(uint256 h1, uint256 h2, uint256 maxBonus, uint256 slope) public view {
        h1 = bound(h1, 0, 2e18);
        h2 = bound(h2, 0, h1); // h2 <= h1: larger deficit
        maxBonus = bound(maxBonus, 1, 0.25e18);
        slope = bound(slope, 1, 20e18);
        uint256 b1 = harness.bonus(h1, maxBonus, slope);
        uint256 b2 = harness.bonus(h2, maxBonus, slope);
        assertLe(b1, b2);
        assertLe(b2, maxBonus);
        if (h1 >= WAD) assertEq(b1, 0);
    }

    /// Property: the engine's view health factor matches the library on the stored state.
    function testFuzz_healthFactorMatchesDefinition(uint256 collateral, uint256 utilization, uint256 price) public {
        collateral = bound(collateral, 1, 1e30);
        utilization = bound(utilization, 0.01e18, 1e18);
        _openPosition(borrower, collateral, LLTV * utilization / WAD);
        price = bound(price, 1, 1e40);
        oracle.setPrice(price);

        Market memory m = _market();
        Position memory p = _position(borrower);
        uint256 debt = _debtOf(borrower);
        uint256 maxBorrow = collateral * price / ORACLE_PRICE_SCALE * LLTV / WAD;
        uint256 expected = debt == 0 ? type(uint256).max : maxBorrow * WAD / debt;
        assertEq(_healthOf(borrower), expected);
        assertEq(harness.healthFactor(maxBorrow, debt), expected);
        assertEq(m.totalBorrowShares, p.borrowShares);
    }

    /// Property: supplying and withdrawing all shares never returns more than supplied, even after interest.
    function testFuzz_supplyWithdrawRoundTrip(uint256 seedAssets, uint256 assets, uint256 elapsed) public {
        irm.setRate(uint256(0.3e18) / 365 days);
        _openPosition(borrower, bound(seedAssets, 1e6, 1e28), 0.5e18);
        skip(bound(elapsed, 0, 365 days));

        assets = bound(assets, 1, 1e28);
        address user = makeAddr("roundTrip");
        _approveAll(user);
        uint256 shares = _supply(user, assets);
        vm.prank(user);
        (uint256 withdrawn,) = engine.withdraw(marketParams, 0, shares, user, user);
        assertLe(withdrawn, assets);
    }

    /// Property: borrowing and immediately repaying all shares costs at least the borrowed amount.
    function testFuzz_borrowRepayRoundTrip(uint256 collateral, uint256 borrowed, uint256 elapsed) public {
        irm.setRate(uint256(0.3e18) / 365 days);
        _openPosition(supplier, 1e30, 0.5e18);
        skip(bound(elapsed, 0, 365 days));

        collateral = bound(collateral, 1e6, 1e28);
        _supplyCollateral(borrower, collateral);
        // Debt is rounded up, so borrowing the full capacity can exceed it by one unit once interest has accrued.
        borrowed = bound(borrowed, 1, collateral * LLTV / WAD - 1);
        uint256 shares = _borrow(borrower, borrowed);
        loanToken.mint(borrower, 1);
        vm.prank(borrower);
        (uint256 repaid,) = engine.repay(marketParams, 0, shares, borrower, "");
        assertGe(repaid, borrowed);
    }
}
