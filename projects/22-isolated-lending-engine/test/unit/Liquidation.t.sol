// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {BaseTest} from "../utils/BaseTest.sol";

import {ILiquidateCallback} from "../../src/interfaces/ILendingCallbacks.sol";
import {ILendingEngine, Id, Market, MarketParams} from "../../src/interfaces/ILendingEngine.sol";
import {MarketParamsLib} from "../../src/libraries/MarketParamsLib.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockOracle} from "../mocks/MockOracle.sol";

/// @notice Liquidation paths with hand-computed expected values.
/// @dev Fixture: 100 collateral, 80 debt, LLTV 86 %, bonus = min(5 %, 2 * deficit). With a 1:1 starting price the
///      health factor is `1.075 * price`, so price 0.9 gives health 0.9675 (bonus capped at 5 %) and price 0.92 gives
///      0.989 (bonus 2.2 %). Below price 0.84 the collateral no longer covers debt plus the 5 % bonus (84): between
///      0.8 and 0.84 it still covers the debt (the closeout caps the bonus at the borrower's equity), and below 0.8
///      the position is under water (the closeout realizes bad debt).
contract LiquidationTest is BaseTest {
    using MarketParamsLib for MarketParams;

    uint256 internal constant COLLATERAL = 100e18;
    uint256 internal constant DEBT = 80e18;
    uint256 internal constant DEBT_SHARES = DEBT * 1e6;

    function setUp() public override {
        super.setUp();
        _supply(supplier, 1000e18);
        _supplyCollateral(borrower, COLLATERAL);
        _borrow(borrower, DEBT);
        loanToken.mint(liquidator, 1000e18);
    }

    function test_liquidate_revertsOnHealthyPosition() public {
        vm.expectRevert(abi.encodeWithSelector(ILendingEngine.HealthyPosition.selector, 1.075e18));
        vm.prank(liquidator);
        engine.liquidate(marketParams, borrower, 1e18, 0, "");
    }

    function test_liquidate_boundaryIsHealthOne() public {
        // Borrow up to the LLTV: debt == maxBorrow exactly, so the health factor is exactly 1 and not liquidatable.
        _borrow(borrower, 6e18);
        vm.expectRevert(abi.encodeWithSelector(ILendingEngine.HealthyPosition.selector, 1e18));
        vm.prank(liquidator);
        engine.liquidate(marketParams, borrower, 1e15, 0, "");

        // One wei of price lower and the position crosses the threshold.
        oracle.setPrice(INITIAL_PRICE - 1);
        assertLt(_healthOf(borrower), 1e18);
        vm.prank(liquidator);
        engine.liquidate(marketParams, borrower, 1e15, 0, "");
    }

    function test_liquidate_partialBySeizedAssets() public {
        oracle.setPrice(0.9e36);
        uint256 expectedRepaid = 8_571_428_571_428_571_429; // ceil(9e18 / 1.05)
        vm.expectEmit(address(engine));
        emit ILendingEngine.Liquidate(
            id, liquidator, borrower, expectedRepaid, expectedRepaid * 1e6, 10e18, 0, 0, 0.9675e18, 0.05e18
        );
        vm.prank(liquidator);
        (uint256 seized, uint256 repaid) = engine.liquidate(marketParams, borrower, 10e18, 0, "");

        assertEq(seized, 10e18);
        assertEq(repaid, expectedRepaid);
        assertEq(_position(borrower).collateral, 90e18);
        assertEq(_position(borrower).borrowShares, DEBT_SHARES - expectedRepaid * 1e6);
        assertEq(collateralToken.balanceOf(liquidator), 10e18);
        assertEq(loanToken.balanceOf(liquidator), 1000e18 - expectedRepaid);
        assertGt(_healthOf(borrower), 0.9675e18, "health improved");
        Market memory m = _market();
        assertEq(m.totalSupplyAssets, 1000e18, "no bad debt");
        assertEq(m.totalBorrowAssets, DEBT - expectedRepaid);
    }

    function test_liquidate_partialByRepaidShares() public {
        oracle.setPrice(0.9e36);
        uint256 repaidShares = 20e18 * 1e6; // 20 units of debt
        // seized = floor(20e18 * 1.05 / 0.9) = 23.333...e18
        uint256 expectedSeized = 23_333_333_333_333_333_333;
        vm.prank(liquidator);
        (uint256 seized, uint256 repaid) = engine.liquidate(marketParams, borrower, 0, repaidShares, "");
        assertEq(seized, expectedSeized);
        assertEq(repaid, 20e18);
        assertEq(_position(borrower).borrowShares, DEBT_SHARES - repaidShares);
        assertEq(_position(borrower).collateral, COLLATERAL - expectedSeized);
    }

    function test_liquidate_bonusFollowsReverseDutchSchedule() public {
        oracle.setPrice(0.92e36); // health 0.989 -> deficit 1.1 % -> bonus 2.2 %
        vm.expectEmit(address(engine));
        // seized = floor(10e18 * 1.022 / 0.92)
        emit ILendingEngine.Liquidate(
            id, liquidator, borrower, 10e18, 10e24, 11_108_695_652_173_913_043, 0, 0, 0.989e18, 0.022e18
        );
        vm.prank(liquidator);
        engine.liquidate(marketParams, borrower, 0, 10e24, "");
    }

    function test_liquidate_fullRepayWhenSolvent() public {
        oracle.setPrice(0.9e36);
        vm.prank(liquidator);
        (uint256 seized, uint256 repaid) = engine.liquidate(marketParams, borrower, 0, DEBT_SHARES, "");
        assertEq(repaid, DEBT);
        assertEq(seized, 93_333_333_333_333_333_333); // 80 * 1.05 / 0.9
        assertEq(_position(borrower).borrowShares, 0);
        assertEq(_position(borrower).collateral, COLLATERAL - seized, "borrower keeps the excess collateral");
        assertEq(_healthOf(borrower), type(uint256).max);
        assertEq(_market().totalSupplyAssets, 1000e18);
    }

    function test_liquidate_insolventPartialReverts() public {
        oracle.setPrice(0.8e36); // collateral value 80 < debt * 1.05 = 84
        vm.expectPartialRevert(ILendingEngine.HealthDecreased.selector);
        vm.prank(liquidator);
        engine.liquidate(marketParams, borrower, 10e18, 0, "");
    }

    function test_liquidate_underwaterCloseoutRealizesBadDebt() public {
        oracle.setPrice(0.7e36); // collateral worth 70 < debt 80
        uint256 expectedRepaid = 66_666_666_666_666_666_667; // ceil(70e18 / 1.05)
        uint256 expectedBadDebt = DEBT - expectedRepaid;

        vm.expectEmit(address(engine));
        emit ILendingEngine.Liquidate(
            id,
            liquidator,
            borrower,
            expectedRepaid,
            expectedRepaid * 1e6,
            COLLATERAL,
            expectedBadDebt,
            DEBT_SHARES - expectedRepaid * 1e6,
            0.7525e18,
            0.05e18
        );
        vm.prank(liquidator);
        engine.liquidate(marketParams, borrower, COLLATERAL, 0, "");

        assertEq(_position(borrower).collateral, 0);
        assertEq(_position(borrower).borrowShares, 0, "residual debt written off");
        Market memory m = _market();
        assertEq(m.totalBorrowAssets, 0);
        assertEq(m.totalBorrowShares, 0);
        assertEq(m.totalSupplyAssets, 1000e18 - expectedBadDebt, "suppliers absorb the bad debt");
    }

    /// Regression (collateral covers the debt but not debt plus bonus): the closeout used to pay the full scheduled
    /// bonus by writing 0.95 of debt off against suppliers on a position worth 83 against 80 of debt. Now the
    /// liquidator repays all 80 for the 100 collateral: its bonus is the borrower's equity (3 / 80 = 3.75 %).
    function test_liquidate_bandCloseoutCapsBonusAtEquity() public {
        oracle.setPrice(0.83e36);
        vm.expectEmit(address(engine));
        emit ILendingEngine.Liquidate(
            id, liquidator, borrower, DEBT, DEBT_SHARES, COLLATERAL, 0, 0, 0.89225e18, 0.0375e18
        );
        vm.prank(liquidator);
        (uint256 seized, uint256 repaid) = engine.liquidate(marketParams, borrower, COLLATERAL, 0, "");

        assertEq(seized, COLLATERAL);
        assertEq(repaid, DEBT);
        assertEq(_position(borrower).collateral, 0);
        assertEq(_position(borrower).borrowShares, 0);
        Market memory m = _market();
        assertEq(m.totalSupplyAssets, 1000e18, "suppliers lose nothing on a position that is not under water");
        assertEq(m.totalBorrowAssets, 0);
        assertEq(m.totalBorrowShares, 0);
    }

    /// At the boundary (collateral worth exactly the debt) the closeout pays no bonus and realizes no bad debt.
    function test_liquidate_bandBoundaryPaysNoBonus() public {
        oracle.setPrice(0.8e36);
        vm.expectEmit(address(engine));
        emit ILendingEngine.Liquidate(id, liquidator, borrower, DEBT, DEBT_SHARES, COLLATERAL, 0, 0, 0.86e18, 0);
        vm.prank(liquidator);
        engine.liquidate(marketParams, borrower, 0, type(uint256).max, "");
        assertEq(_market().totalSupplyAssets, 1000e18);
    }

    /// Regression (self-liquidation PoC): a borrower whose collateral still covers the debt cannot use a closeout to
    /// recover the collateral for less than the debt; suppliers are untouched and the borrower's equity is unchanged.
    function test_liquidate_selfLiquidationCannotShiftLossToSuppliers() public {
        oracle.setPrice(0.83e36);
        loanToken.mint(borrower, DEBT);
        uint256 collateralBefore = collateralToken.balanceOf(borrower);
        vm.prank(borrower);
        (, uint256 repaid) = engine.liquidate(marketParams, borrower, type(uint256).max, 0, "");

        assertEq(repaid, DEBT, "the borrower pays the whole debt");
        assertEq(collateralToken.balanceOf(borrower) - collateralBefore, COLLATERAL);
        assertEq(loanToken.balanceOf(borrower), DEBT, "80 borrowed at the start, 80 repaid now");
        assertEq(_market().totalSupplyAssets, 1000e18, "no supplier loss");
    }

    /// Regression (dust front-run PoC): a 1-wei collateral deposit in front of an exact-amount closeout turns it
    /// into a partial liquidation that is rejected, but a close request (`type(uint256).max`, or anything at least
    /// the collateral) is priced on the current state and cannot be blocked, in the band or under water.
    function test_liquidate_dustDepositCannotBlockClose() public {
        uint256[2] memory prices = [uint256(0.7e36), 0.83e36];
        for (uint256 i; i < prices.length; ++i) {
            uint256 snapshot = vm.snapshotState();
            oracle.setPrice(prices[i]);
            _supplyCollateral(borrower, 1); // the front-run

            vm.prank(liquidator);
            vm.expectPartialRevert(ILendingEngine.HealthDecreased.selector);
            engine.liquidate(marketParams, borrower, COLLATERAL, 0, "");

            uint256 inner = vm.snapshotState();
            vm.prank(liquidator);
            (uint256 seized,) = engine.liquidate(marketParams, borrower, type(uint256).max, 0, "");
            assertEq(seized, COLLATERAL + 1);
            assertEq(_position(borrower).borrowShares, 0);
            vm.revertToState(inner);

            vm.prank(liquidator);
            (seized,) = engine.liquidate(marketParams, borrower, 0, type(uint256).max, "");
            assertEq(seized, COLLATERAL + 1);
            assertEq(_position(borrower).borrowShares, 0);
            vm.revertToState(snapshot);
        }
    }

    /// Regression (repay front-run PoC): repaying one share in front of a full repayment used to make it revert with
    /// `RepayExceedsDebt`. A request for at least the owed shares now repays whatever is owed.
    function test_liquidate_repayFrontRunCannotBlockFullRepay() public {
        oracle.setPrice(0.9e36);
        loanToken.mint(borrower, 1e18);
        vm.prank(borrower);
        engine.repay(marketParams, 0, 1, borrower, "");

        vm.prank(liquidator);
        (, uint256 repaid) = engine.liquidate(marketParams, borrower, 0, DEBT_SHARES, "");
        assertEq(repaid, DEBT, "DEBT_SHARES - 1 shares still round up to the whole debt");
        assertEq(_position(borrower).borrowShares, 0);
        assertGt(_position(borrower).collateral, 0, "borrower keeps the excess collateral");
    }

    /// A partial repayment whose seizure would take exactly all the collateral while debt remains is rejected:
    /// only a close may exhaust the collateral (and only a close can realize bad debt).
    function test_liquidate_partialCannotExhaustCollateral() public {
        oracle.setPrice(0.7e36);
        // floor(66.666...667 * 1.05) = 70 of value buys exactly the 100 collateral at price 0.7.
        uint256 shares = 66_666_666_666_666_666_667 * 1e6;
        vm.expectRevert(abi.encodeWithSelector(ILendingEngine.HealthDecreased.selector, 0.7525e18, 0));
        vm.prank(liquidator);
        engine.liquidate(marketParams, borrower, 0, shares, "");
    }

    function test_liquidate_badDebtStaysInItsMarket() public {
        // A second market with the same loan token but a different collateral and oracle.
        MockERC20 otherCollateral = new MockERC20("Other", "OTH", 18);
        MockOracle otherOracle = new MockOracle(1e36);
        MarketParams memory otherParams = marketParams;
        otherParams.collateralToken = address(otherCollateral);
        otherParams.oracle = address(otherOracle);
        Id otherId = engine.createMarket(otherParams);
        loanToken.mint(supplier, 500e18);
        vm.prank(supplier);
        engine.supply(otherParams, 500e18, 0, supplier, "");
        Market memory otherBefore = engine.market(otherId);
        uint256 engineBalanceBefore = loanToken.balanceOf(address(engine));

        oracle.setPrice(0.5e36); // crash only the first market's collateral
        vm.prank(liquidator);
        engine.liquidate(marketParams, borrower, COLLATERAL, 0, "");

        Market memory otherAfter = engine.market(otherId);
        assertEq(otherAfter.totalSupplyAssets, otherBefore.totalSupplyAssets);
        assertEq(otherAfter.totalSupplyShares, otherBefore.totalSupplyShares);
        assertLt(_market().totalSupplyAssets, 1000e18);
        // The engine still holds every unit the second market's suppliers can withdraw.
        assertGe(loanToken.balanceOf(address(engine)), engineBalanceBefore);
        vm.prank(supplier);
        engine.withdraw(otherParams, 500e18, 0, supplier, supplier);
    }

    function test_liquidate_afterInterestPushesHealthBelowOne() public {
        irm.setRate(uint256(0.5e18) / 365 days);
        skip(60 days);
        assertLt(_healthOf(borrower), 1e18);
        vm.prank(liquidator);
        engine.liquidate(marketParams, borrower, 1e18, 0, "");
    }

    function test_liquidate_reverts() public {
        oracle.setPrice(0.9e36);
        vm.startPrank(liquidator);
        vm.expectRevert(abi.encodeWithSelector(ILendingEngine.InconsistentInput.selector, 0, 0));
        engine.liquidate(marketParams, borrower, 0, 0, "");
        vm.expectRevert(abi.encodeWithSelector(ILendingEngine.InconsistentInput.selector, 1, 1));
        engine.liquidate(marketParams, borrower, 1, 1, "");
        // A partial seizure (99 of 100 collateral) that would repay ceil(89.1 / 1.05) = 84.857... > 80 of debt.
        vm.expectRevert(
            abi.encodeWithSelector(
                ILendingEngine.RepayExceedsDebt.selector, 84_857_142_857_142_857_143 * 1e6, DEBT_SHARES
            )
        );
        engine.liquidate(marketParams, borrower, 99e18, 0, "");
        // A partial repayment (70 of 80 debt) that would seize 70 * 1.05 / 0.7 = 105 > 100 of collateral.
        oracle.setPrice(0.7e36);
        vm.expectRevert(abi.encodeWithSelector(ILendingEngine.SeizeExceedsCollateral.selector, 105e18, COLLATERAL));
        engine.liquidate(marketParams, borrower, 0, 70e24, "");
        MarketParams memory unknown = marketParams;
        unknown.lltv = 0.5e18;
        vm.expectRevert(abi.encodeWithSelector(ILendingEngine.MarketNotCreated.selector, unknown.id()));
        engine.liquidate(unknown, borrower, 1, 0, "");
        vm.stopPrank();
    }

    /// Requests larger than the position close it instead of reverting, on either side.
    function test_liquidate_oversizedRequestsClose() public {
        uint256 snapshot = vm.snapshotState();
        oracle.setPrice(0.9e36);
        vm.prank(liquidator);
        (, uint256 repaid) = engine.liquidate(marketParams, borrower, 0, DEBT_SHARES + 1, "");
        assertEq(repaid, DEBT);
        vm.revertToState(snapshot);

        oracle.setPrice(0.9e36);
        vm.prank(liquidator);
        (uint256 seized,) = engine.liquidate(marketParams, borrower, COLLATERAL + 1e18, 0, "");
        assertEq(seized, 93_333_333_333_333_333_333, "solvent close seizes only what the full repayment buys");
        vm.revertToState(snapshot);

        oracle.setPrice(0.7e36);
        vm.prank(liquidator);
        (seized,) = engine.liquidate(marketParams, borrower, COLLATERAL + 1e18, 0, "");
        assertEq(seized, COLLATERAL);
        assertEq(_position(borrower).borrowShares, 0);
    }

    function test_liquidate_revertsOnZeroPrice() public {
        oracle.setPrice(0);
        vm.expectRevert(ILendingEngine.ZeroPrice.selector);
        vm.prank(liquidator);
        engine.liquidate(marketParams, borrower, 1e18, 0, "");
    }

    function test_liquidate_revertsWhenOracleDown() public {
        oracle.setPrice(0.8e36);
        oracle.setDown(true);
        vm.expectRevert(MockOracle.OracleDown.selector);
        vm.prank(liquidator);
        engine.liquidate(marketParams, borrower, 1e18, 0, "");
    }

    function test_liquidate_callbackReceivesCollateralBeforePaying() public {
        oracle.setPrice(0.9e36);
        CallbackLiquidator cb = new CallbackLiquidator(engine, marketParams);
        loanToken.mint(address(cb), 100e18);
        cb.liquidate(borrower, 10e18);
        assertEq(cb.collateralSeenInCallback(), 10e18, "collateral arrives before the repayment is pulled");
        assertTrue(cb.lockedInCallback());
    }
}

contract CallbackLiquidator is ILiquidateCallback {
    ILendingEngine internal immutable ENGINE;
    MarketParams internal params;
    uint256 public collateralSeenInCallback;
    bool public lockedInCallback;

    constructor(ILendingEngine engine, MarketParams memory marketParams) {
        ENGINE = engine;
        params = marketParams;
    }

    function liquidate(address borrower, uint256 seized) external {
        ENGINE.liquidate(params, borrower, seized, 0, hex"01");
    }

    function onLiquidate(uint256 repaidAssets, bytes calldata) external {
        collateralSeenInCallback = MockERC20(params.collateralToken).balanceOf(address(this));
        lockedInCallback = ENGINE.isMarketLocked(MarketParamsLib.id(params));
        MockERC20(params.loanToken).approve(address(ENGINE), repaidAssets);
    }
}
