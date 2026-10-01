// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {BaseTest} from "../utils/BaseTest.sol";

import {ISupplyCallback} from "../../src/interfaces/ILendingCallbacks.sol";
import {ILendingEngine, Market, MarketParams} from "../../src/interfaces/ILendingEngine.sol";
import {MarketParamsLib} from "../../src/libraries/MarketParamsLib.sol";
import {SharesMathLib} from "../../src/libraries/SharesMathLib.sol";

contract SupplyWithdrawTest is BaseTest {
    using MarketParamsLib for MarketParams;
    using SharesMathLib for uint256;

    // --- supply ------------------------------------------------------------------------------------------------

    function test_supply_assets() public {
        loanToken.mint(supplier, 100e18);
        vm.expectEmit(address(engine));
        emit ILendingEngine.Supply(id, supplier, supplier, 100e18, 100e18 * 1e6);
        vm.prank(supplier);
        (uint256 assets, uint256 shares) = engine.supply(marketParams, 100e18, 0, supplier, "");

        assertEq(assets, 100e18);
        assertEq(shares, 100e18 * 1e6, "first supply mints assets * 1e6 shares");
        assertEq(_position(supplier).supplyShares, shares);
        Market memory m = _market();
        assertEq(m.totalSupplyAssets, 100e18);
        assertEq(m.totalSupplyShares, shares);
        assertEq(loanToken.balanceOf(address(engine)), 100e18);
    }

    function test_supply_shares_roundsAssetsUp() public {
        _supply(supplier, 100e18);
        // Make the share price non-trivial: donate interest through a borrow at a positive rate.
        irm.setRate(uint256(0.2e18) / 365 days);
        _openPosition(borrower, 100e18, 0.5e18);
        skip(90 days);
        engine.accrueInterest(marketParams);

        Market memory m = _market();
        uint256 sharesWanted = 12_345_678_901;
        uint256 expectedAssets = sharesWanted.toAssetsUp(m.totalSupplyAssets, m.totalSupplyShares);
        loanToken.mint(supplier, expectedAssets);
        vm.prank(supplier);
        (uint256 assets, uint256 shares) = engine.supply(marketParams, 0, sharesWanted, supplier, "");
        assertEq(shares, sharesWanted);
        assertEq(assets, expectedAssets);
        assertGe(assets * (m.totalSupplyShares + 1e6), sharesWanted * (m.totalSupplyAssets + 1), "rounded up");
    }

    function test_supply_onBehalf() public {
        address beneficiary = makeAddr("beneficiary");
        loanToken.mint(supplier, 1e18);
        vm.prank(supplier);
        engine.supply(marketParams, 1e18, 0, beneficiary, "");
        assertEq(_position(beneficiary).supplyShares, 1e24);
        assertEq(_position(supplier).supplyShares, 0);
    }

    function test_supply_reverts() public {
        vm.startPrank(supplier);
        vm.expectRevert(abi.encodeWithSelector(ILendingEngine.InconsistentInput.selector, 0, 0));
        engine.supply(marketParams, 0, 0, supplier, "");
        vm.expectRevert(abi.encodeWithSelector(ILendingEngine.InconsistentInput.selector, 1, 1));
        engine.supply(marketParams, 1, 1, supplier, "");
        vm.expectRevert(ILendingEngine.ZeroAddress.selector);
        engine.supply(marketParams, 1, 0, address(0), "");
        MarketParams memory unknown = marketParams;
        unknown.lltv = 0.5e18;
        vm.expectRevert(abi.encodeWithSelector(ILendingEngine.MarketNotCreated.selector, unknown.id()));
        engine.supply(unknown, 1, 0, supplier, "");
        vm.stopPrank();
    }

    function test_supply_callbackPaysAfterCredit() public {
        SupplyCallbackUser user = new SupplyCallbackUser(engine, marketParams);
        loanToken.mint(address(user), 5e18);
        user.supplyWithCallback(5e18);
        assertEq(user.seenAssets(), 5e18);
        assertTrue(user.sawLock(), "market is locked during the callback");
        assertEq(_position(address(user)).supplyShares, 5e24);
        assertEq(loanToken.balanceOf(address(engine)), 5e18);
    }

    function test_firstDepositorCannotInflateSharePrice() public {
        // Attacker supplies 1 wei, then donates a large amount directly to the engine.
        address attacker = makeAddr("attacker");
        _approveAll(attacker);
        _supply(attacker, 1);
        loanToken.mint(address(engine), 1000e18); // donation does not touch accounting

        // The victim still receives shares worth what they deposited.
        uint256 victimShares = _supply(supplier, 10e18);
        Market memory m = _market();
        uint256 victimAssets = victimShares.toAssetsDown(m.totalSupplyAssets, m.totalSupplyShares);
        assertApproxEqAbs(victimAssets, 10e18, 1);
    }

    // --- withdraw ----------------------------------------------------------------------------------------------

    function test_withdraw_assets() public {
        uint256 shares = _supply(supplier, 100e18);
        vm.expectEmit(address(engine));
        emit ILendingEngine.Withdraw(id, supplier, supplier, supplier, 40e18, 40e18 * 1e6);
        vm.prank(supplier);
        (uint256 assets, uint256 burned) = engine.withdraw(marketParams, 40e18, 0, supplier, supplier);
        assertEq(assets, 40e18);
        assertEq(burned, 40e18 * 1e6);
        assertEq(_position(supplier).supplyShares, shares - burned);
        assertEq(loanToken.balanceOf(supplier), 40e18);
    }

    function test_withdraw_allShares() public {
        uint256 shares = _supply(supplier, 100e18);
        vm.prank(supplier);
        (uint256 assets,) = engine.withdraw(marketParams, 0, shares, supplier, supplier);
        assertEq(assets, 100e18);
        assertEq(_market().totalSupplyAssets, 0);
        assertEq(_market().totalSupplyShares, 0);
    }

    function test_withdraw_byAuthorizedManager() public {
        _supply(supplier, 10e18);
        address manager = makeAddr("manager");
        vm.prank(supplier);
        engine.setAuthorization(manager, true);
        vm.prank(manager);
        engine.withdraw(marketParams, 1e18, 0, supplier, manager);
        assertEq(loanToken.balanceOf(manager), 1e18);
    }

    function test_withdraw_reverts() public {
        _supply(supplier, 10e18);
        address stranger = makeAddr("stranger");

        vm.expectRevert(abi.encodeWithSelector(ILendingEngine.Unauthorized.selector, stranger, supplier));
        vm.prank(stranger);
        engine.withdraw(marketParams, 1e18, 0, supplier, stranger);

        vm.startPrank(supplier);
        vm.expectRevert(abi.encodeWithSelector(ILendingEngine.InconsistentInput.selector, 1, 1));
        engine.withdraw(marketParams, 1, 1, supplier, supplier);
        vm.expectRevert(ILendingEngine.ZeroAddress.selector);
        engine.withdraw(marketParams, 1, 0, supplier, address(0));
        vm.expectRevert(abi.encodeWithSelector(ILendingEngine.InsufficientBalance.selector, 10e24, 11e24));
        engine.withdraw(marketParams, 11e18, 0, supplier, supplier);
        MarketParams memory unknown = marketParams;
        unknown.lltv = 0.5e18;
        vm.expectRevert(abi.encodeWithSelector(ILendingEngine.MarketNotCreated.selector, unknown.id()));
        engine.withdraw(unknown, 1, 0, supplier, supplier);
        vm.stopPrank();
    }

    function test_withdraw_revertsOnInsufficientLiquidity() public {
        _openPosition(borrower, 100e18, 0.8e18); // supplies 161e18, borrows 80e18
        uint256 shares = _position(supplier).supplyShares;
        vm.expectRevert(abi.encodeWithSelector(ILendingEngine.InsufficientLiquidity.selector, 80e18, 0));
        vm.prank(supplier);
        engine.withdraw(marketParams, 0, shares, supplier, supplier);
    }
}

/// @dev Supplies through the callback path and records what it observed mid-operation.
contract SupplyCallbackUser is ISupplyCallback {
    ILendingEngine internal immutable ENGINE;
    MarketParams internal params;
    uint256 public seenAssets;
    bool public sawLock;

    constructor(ILendingEngine engine, MarketParams memory marketParams) {
        ENGINE = engine;
        params = marketParams;
    }

    function supplyWithCallback(uint256 assets) external {
        ENGINE.supply(params, assets, 0, address(this), hex"01");
    }

    function onSupply(uint256 assets, bytes calldata) external {
        seenAssets = assets;
        sawLock = ENGINE.isMarketLocked(MarketParamsLib.id(params));
        // Pay only now: the engine pulls after the callback.
        (bool ok,) = params.loanToken.call(abi.encodeWithSignature("approve(address,uint256)", address(ENGINE), assets));
        require(ok, "approve");
    }
}
