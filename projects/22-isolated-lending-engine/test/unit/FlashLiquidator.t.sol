// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {BaseTest} from "../utils/BaseTest.sol";

import {ILendingEngine} from "../../src/interfaces/ILendingEngine.sol";
import {MarketParamsLib} from "../../src/libraries/MarketParamsLib.sol";
import {FlashLiquidator} from "../../src/periphery/FlashLiquidator.sol";
import {ISwapVenue} from "../../src/periphery/ISwapVenue.sol";
import {MockSwapVenue} from "../mocks/MockSwapVenue.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract FlashLiquidatorTest is BaseTest {
    FlashLiquidator internal flash;
    MockSwapVenue internal venue;
    address internal keeper = makeAddr("keeper");

    function setUp() public override {
        super.setUp();
        _supply(supplier, 1000e18);
        _supplyCollateral(borrower, 100e18);
        _borrow(borrower, 80e18);

        flash = new FlashLiquidator(engine, keeper);
        venue = new MockSwapVenue(oracle, address(collateralToken), address(loanToken), 30); // 0.3 % spread
        loanToken.mint(address(venue), 1_000_000e18);
    }

    function _order(uint256 seized, uint256 repaidShares) internal view returns (FlashLiquidator.Order memory) {
        return FlashLiquidator.Order({
            marketParams: marketParams,
            borrower: borrower,
            seizedAssets: seized,
            repaidShares: repaidShares,
            venue: ISwapVenue(address(venue)),
            minAmountOut: 0
        });
    }

    function test_liquidate_profitableWithoutCapital() public {
        oracle.setPrice(0.9e36); // 5 % bonus vs 0.3 % venue spread
        assertEq(loanToken.balanceOf(address(flash)), 0);

        uint256 expectedRepaid = 8_571_428_571_428_571_429; // ceil(9e18 / 1.05)
        uint256 expectedProceeds = uint256(10e18) * 0.9e36 / 1e36 * 9970 / 10_000;
        vm.expectEmit(address(flash));
        emit FlashLiquidator.Liquidation(
            MarketParamsLib.id(marketParams),
            borrower,
            10e18,
            expectedRepaid,
            expectedProceeds,
            expectedProceeds - expectedRepaid
        );
        vm.prank(keeper);
        uint256 profit = flash.liquidate(_order(10e18, 0), 10e18, 0);

        assertEq(profit, expectedProceeds - expectedRepaid);
        assertEq(loanToken.balanceOf(keeper), profit);
        assertEq(loanToken.balanceOf(address(flash)), 0);
        assertEq(collateralToken.balanceOf(address(flash)), 0);
        assertEq(loanToken.allowance(address(flash), address(engine)), 0, "flash repayment consumed the allowance");
    }

    function test_liquidate_underwaterCloseout() public {
        oracle.setPrice(0.7e36); // collateral worth 70 < debt 80: all of it is seized at the full 5 % bonus
        uint256 supplyBefore = _market().totalSupplyAssets;
        vm.prank(keeper);
        uint256 profit = flash.liquidate(_order(type(uint256).max, 0), 80e18, 1e18);
        assertGt(profit, 1e18);
        assertEq(_position(borrower).collateral, 0);
        assertEq(_position(borrower).borrowShares, 0);
        assertLt(_market().totalSupplyAssets, supplyBefore, "bad debt realized");
    }

    function test_liquidate_bandCloseoutRepaysTheWholeDebt() public {
        oracle.setPrice(0.83e36); // collateral worth 83 covers the 80 debt but not the 5 % bonus
        vm.prank(keeper);
        uint256 profit = flash.liquidate(_order(0, type(uint256).max), 80e18, 1e18);
        // 100 collateral sold at 0.83 minus the 0.3 % spread, for 80 repaid.
        assertEq(profit, uint256(100e18) * 0.83e36 / 1e36 * 9970 / 10_000 - 80e18);
        assertEq(_position(borrower).collateral, 0);
        assertEq(_position(borrower).borrowShares, 0);
        assertEq(_market().totalSupplyAssets, 1000e18, "no supplier loss");
    }

    function test_liquidate_revertsBelowMinProfit() public {
        oracle.setPrice(0.9e36);
        vm.expectPartialRevert(FlashLiquidator.InsufficientProfit.selector);
        vm.prank(keeper);
        flash.liquidate(_order(10e18, 0), 10e18, 1e18);
    }

    function test_liquidate_revertsWhenUnprofitable() public {
        oracle.setPrice(0.9e36);
        venue.setSpreadBps(1000); // 10 % slippage > 5 % bonus: proceeds cannot repay the flash loan
        vm.expectRevert();
        vm.prank(keeper);
        flash.liquidate(_order(10e18, 0), 10e18, 0);
    }

    function test_liquidate_revertsOnSlippageBound() public {
        oracle.setPrice(0.9e36);
        FlashLiquidator.Order memory order = _order(10e18, 0);
        order.minAmountOut = 9e18; // venue returns 8.973e18
        vm.expectPartialRevert(MockSwapVenue.Slippage.selector);
        vm.prank(keeper);
        flash.liquidate(order, 10e18, 0);
    }

    function test_liquidate_onlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        flash.liquidate(_order(10e18, 0), 10e18, 0);
    }

    function test_onFlashLoan_rejectsStrangers() public {
        vm.expectRevert(abi.encodeWithSelector(FlashLiquidator.NotEngine.selector, address(this)));
        flash.onFlashLoan(1, abi.encode(_order(1, 0)));
    }

    function test_onFlashLoan_rejectsUnsolicitedEngineCallback() public {
        vm.expectRevert(FlashLiquidator.UnexpectedCallback.selector);
        vm.prank(address(engine));
        flash.onFlashLoan(1, abi.encode(_order(1, 0)));
    }

    function test_rescue() public {
        loanToken.mint(address(flash), 5e18);
        vm.expectEmit(address(flash));
        emit FlashLiquidator.Rescue(address(loanToken), keeper, 5e18);
        vm.prank(keeper);
        flash.rescue(loanToken, keeper, 5e18);
        assertEq(loanToken.balanceOf(keeper), 5e18);
    }

    function test_rescue_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        flash.rescue(loanToken, keeper, 1);
        vm.expectRevert(FlashLiquidator.ZeroAddress.selector);
        vm.prank(keeper);
        flash.rescue(loanToken, address(0), 1);
    }

    function test_constructor_revertsOnZeroEngine() public {
        vm.expectRevert(FlashLiquidator.ZeroAddress.selector);
        new FlashLiquidator(ILendingEngine(address(0)), keeper);
    }
}
