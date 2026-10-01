// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {BaseTest} from "../utils/BaseTest.sol";

import {ILendingEngine, Market, MarketParams} from "../../src/interfaces/ILendingEngine.sol";
import {MarketParamsLib} from "../../src/libraries/MarketParamsLib.sol";
import {MathLib} from "../../src/libraries/MathLib.sol";
import {SharesMathLib} from "../../src/libraries/SharesMathLib.sol";

contract InterestTest is BaseTest {
    using MathLib for uint256;
    using MarketParamsLib for MarketParams;
    using SharesMathLib for uint256;

    uint256 internal constant RATE = uint256(0.1e18) / 365 days; // 10 % APR

    function setUp() public override {
        super.setUp();
        irm.setRate(RATE);
        _openPosition(borrower, 100e18, 0.5e18); // 50e18 borrowed, 101e18 supplied
    }

    function test_accrueInterest_taylorCompounding() public {
        skip(365 days);
        uint256 expectedInterest = uint256(50e18).wMulDown(RATE.wTaylorCompounded(365 days));
        vm.expectEmit(address(engine));
        emit ILendingEngine.AccrueInterest(id, RATE, expectedInterest, 0);
        engine.accrueInterest(marketParams);

        Market memory m = _market();
        assertEq(m.totalBorrowAssets, 50e18 + expectedInterest);
        assertEq(m.totalSupplyAssets, 101e18 + expectedInterest);
        assertEq(m.lastUpdate, block.timestamp);
        // 1 + 0.1 + 0.005 + 0.000166... = 1.10516..., within 0.0001 of e^0.1.
        assertApproxEqRel(expectedInterest, 5.2585e18, 0.0001e18);
    }

    function test_accrueInterest_noopWithinSameBlock() public {
        engine.accrueInterest(marketParams);
        Market memory before = _market();
        engine.accrueInterest(marketParams);
        Market memory afterwards = _market();
        assertEq(afterwards.totalBorrowAssets, before.totalBorrowAssets);
    }

    function test_accrueInterest_mintsFeeShares() public {
        vm.prank(owner);
        engine.setFee(marketParams, 0.2e18);
        skip(365 days);
        Market memory before = _market();
        engine.accrueInterest(marketParams);
        Market memory m = _market();

        uint256 interest = m.totalBorrowAssets - before.totalBorrowAssets;
        uint256 feeAmount = interest.wMulDown(0.2e18);
        uint256 feeShares = engine.position(id, feeRecipient).supplyShares;
        assertEq(feeShares, feeAmount.toSharesDown(m.totalSupplyAssets - feeAmount, before.totalSupplyShares));
        assertEq(m.totalSupplyShares, before.totalSupplyShares + feeShares);
        // The fee recipient's shares are worth (almost exactly) 20 % of the interest.
        assertApproxEqAbs(feeShares.toAssetsDown(m.totalSupplyAssets, m.totalSupplyShares), feeAmount, 1);
    }

    function test_expectedMarketBalances_matchesAccrual() public {
        vm.prank(owner);
        engine.setFee(marketParams, 0.1e18);
        skip(200 days);
        (uint256 tsa, uint256 tss, uint256 tba, uint256 tbs) = engine.expectedMarketBalances(marketParams);
        engine.accrueInterest(marketParams);
        Market memory m = _market();
        assertEq(tsa, m.totalSupplyAssets);
        assertEq(tss, m.totalSupplyShares);
        assertEq(tba, m.totalBorrowAssets);
        assertEq(tbs, m.totalBorrowShares);
    }

    function test_expectedMarketBalances_noBorrowsNoInterest() public {
        uint256 shares = _position(borrower).borrowShares;
        vm.prank(borrower);
        engine.repay(marketParams, 0, shares, borrower, "");
        skip(10 days);
        (uint256 tsa,, uint256 tba,) = engine.expectedMarketBalances(marketParams);
        assertEq(tba, 0);
        assertEq(tsa, _market().totalSupplyAssets);
    }

    function test_expectedMarketBalances_revertsOnUnknownMarket() public {
        MarketParams memory unknown = marketParams;
        unknown.lltv = 0.5e18;
        vm.expectRevert(abi.encodeWithSelector(ILendingEngine.MarketNotCreated.selector, unknown.id()));
        engine.expectedMarketBalances(unknown);
    }

    function test_accrueInterest_revertsOnUnknownMarket() public {
        MarketParams memory unknown = marketParams;
        unknown.lltv = 0.5e18;
        vm.expectRevert(abi.encodeWithSelector(ILendingEngine.MarketNotCreated.selector, unknown.id()));
        engine.accrueInterest(unknown);
    }

    function test_healthFactor_includesPendingInterest() public {
        uint256 before = _healthOf(borrower);
        skip(365 days);
        uint256 afterYear = _healthOf(borrower);
        assertLt(afterYear, before);
        engine.accrueInterest(marketParams);
        assertEq(_healthOf(borrower), afterYear, "view equals post-accrual state");
    }

    function test_healthFactor_noDebtIsMax() public view {
        assertEq(_healthOf(supplier), type(uint256).max);
    }

    function test_supplyShareValueGrowsWithInterest() public {
        Market memory m0 = _market();
        skip(100 days);
        engine.accrueInterest(marketParams);
        Market memory m1 = _market();
        // (TSA + 1) / (TSS + 1e6) is non-decreasing.
        assertGt(
            (uint256(m1.totalSupplyAssets) + 1) * (uint256(m0.totalSupplyShares) + 1e6),
            (uint256(m0.totalSupplyAssets) + 1) * (uint256(m1.totalSupplyShares) + 1e6)
        );
    }
}
