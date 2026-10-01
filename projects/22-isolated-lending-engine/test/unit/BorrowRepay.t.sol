// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {BaseTest} from "../utils/BaseTest.sol";

import {IRepayCallback, ISupplyCollateralCallback} from "../../src/interfaces/ILendingCallbacks.sol";
import {ILendingEngine, Market, MarketParams} from "../../src/interfaces/ILendingEngine.sol";
import {MarketParamsLib} from "../../src/libraries/MarketParamsLib.sol";
import {SharesMathLib} from "../../src/libraries/SharesMathLib.sol";
import {MockOracle} from "../mocks/MockOracle.sol";

contract BorrowRepayTest is BaseTest {
    using MarketParamsLib for MarketParams;
    using SharesMathLib for uint256;

    function setUp() public override {
        super.setUp();
        _supply(supplier, 1000e18);
        _supplyCollateral(borrower, 100e18);
    }

    // --- borrow ------------------------------------------------------------------------------------------------

    function test_borrow_assets() public {
        vm.expectEmit(address(engine));
        emit ILendingEngine.Borrow(id, borrower, borrower, borrower, 50e18, 50e18 * 1e6);
        vm.prank(borrower);
        (uint256 assets, uint256 shares) = engine.borrow(marketParams, 50e18, 0, borrower, borrower);
        assertEq(assets, 50e18);
        assertEq(shares, 50e18 * 1e6);
        assertEq(_position(borrower).borrowShares, shares);
        assertEq(_market().totalBorrowAssets, 50e18);
        assertEq(_market().totalBorrowShares, shares);
        assertEq(loanToken.balanceOf(borrower), 50e18);
    }

    function test_borrow_shares_roundsAssetsDown() public {
        vm.prank(borrower);
        (uint256 assets, uint256 shares) = engine.borrow(marketParams, 0, 1_500_000, borrower, borrower);
        assertEq(shares, 1_500_000);
        assertEq(assets, 1, "1.5 units of debt value pays out 1 unit");
    }

    function test_borrow_upToLltv() public {
        _borrow(borrower, 86e18);
        assertEq(_healthOf(borrower), 1e18);
        vm.expectRevert(abi.encodeWithSelector(ILendingEngine.InsufficientCollateral.selector, 86e18 + 1, 86e18));
        _borrow(borrower, 1);
    }

    function test_borrow_revertsOnInsufficientLiquidity() public {
        _supplyCollateral(borrower, 10_000e18);
        vm.expectRevert(abi.encodeWithSelector(ILendingEngine.InsufficientLiquidity.selector, 1001e18, 1000e18));
        _borrow(borrower, 1001e18);
    }

    function test_borrow_reverts() public {
        address stranger = makeAddr("stranger");
        vm.expectRevert(abi.encodeWithSelector(ILendingEngine.Unauthorized.selector, stranger, borrower));
        vm.prank(stranger);
        engine.borrow(marketParams, 1e18, 0, borrower, stranger);

        vm.startPrank(borrower);
        vm.expectRevert(abi.encodeWithSelector(ILendingEngine.InconsistentInput.selector, 0, 0));
        engine.borrow(marketParams, 0, 0, borrower, borrower);
        vm.expectRevert(ILendingEngine.ZeroAddress.selector);
        engine.borrow(marketParams, 1, 0, borrower, address(0));
        MarketParams memory unknown = marketParams;
        unknown.lltv = 0.5e18;
        vm.expectRevert(abi.encodeWithSelector(ILendingEngine.MarketNotCreated.selector, unknown.id()));
        engine.borrow(unknown, 1, 0, borrower, borrower);
        vm.stopPrank();
    }

    function test_borrow_revertsWhenOracleDown() public {
        oracle.setDown(true);
        vm.expectRevert(MockOracle.OracleDown.selector);
        _borrow(borrower, 1e18);
    }

    function test_borrow_withoutCollateralReverts() public {
        address empty = makeAddr("empty");
        vm.expectRevert(abi.encodeWithSelector(ILendingEngine.InsufficientCollateral.selector, 1, 0));
        _borrow(empty, 1);
    }

    // --- repay -------------------------------------------------------------------------------------------------

    function test_repay_assets() public {
        uint256 shares = _borrow(borrower, 50e18);
        vm.expectEmit(address(engine));
        emit ILendingEngine.Repay(id, borrower, borrower, 20e18, 20e18 * 1e6);
        vm.prank(borrower);
        (uint256 assets, uint256 repaidShares) = engine.repay(marketParams, 20e18, 0, borrower, "");
        assertEq(assets, 20e18);
        assertEq(repaidShares, 20e18 * 1e6);
        assertEq(_position(borrower).borrowShares, shares - repaidShares);
        assertEq(_market().totalBorrowAssets, 30e18);
    }

    function test_repay_allShares_afterInterest() public {
        irm.setRate(uint256(0.1e18) / 365 days);
        uint256 shares = _borrow(borrower, 50e18);
        skip(365 days);
        loanToken.mint(borrower, 10e18);
        vm.prank(borrower);
        (uint256 assets,) = engine.repay(marketParams, 0, shares, borrower, "");
        assertGt(assets, 50e18 * 1.105e18 / 1e18, "~10.5 % compounded interest");
        assertEq(_position(borrower).borrowShares, 0);
        assertEq(_market().totalBorrowShares, 0);
        assertEq(_market().totalBorrowAssets, 0);
    }

    function test_repay_onBehalfByThirdParty() public {
        _borrow(borrower, 10e18);
        address helper = makeAddr("helper");
        _approveAll(helper);
        loanToken.mint(helper, 10e18);
        vm.prank(helper);
        engine.repay(marketParams, 10e18, 0, borrower, "");
        assertEq(_position(borrower).borrowShares, 0);
    }

    function test_repay_reverts() public {
        uint256 shares = _borrow(borrower, 10e18);
        vm.startPrank(borrower);
        vm.expectRevert(abi.encodeWithSelector(ILendingEngine.InconsistentInput.selector, 1, 1));
        engine.repay(marketParams, 1, 1, borrower, "");
        vm.expectRevert(ILendingEngine.ZeroAddress.selector);
        engine.repay(marketParams, 1, 0, address(0), "");
        vm.expectRevert(abi.encodeWithSelector(ILendingEngine.RepayExceedsDebt.selector, shares + 1, shares));
        engine.repay(marketParams, 0, shares + 1, borrower, "");
        MarketParams memory unknown = marketParams;
        unknown.lltv = 0.5e18;
        vm.expectRevert(abi.encodeWithSelector(ILendingEngine.MarketNotCreated.selector, unknown.id()));
        engine.repay(unknown, 1, 0, borrower, "");
        vm.stopPrank();
    }

    function test_repay_callback() public {
        _borrow(borrower, 10e18);
        RepayCallbackUser helper = new RepayCallbackUser(engine, marketParams);
        loanToken.mint(address(helper), 10e18);
        helper.repayFor(borrower, 10e18);
        assertEq(helper.seenAssets(), 10e18);
        assertEq(_position(borrower).borrowShares, 0);
    }

    // --- collateral --------------------------------------------------------------------------------------------

    function test_supplyCollateral() public {
        collateralToken.mint(borrower, 5e18);
        vm.expectEmit(address(engine));
        emit ILendingEngine.SupplyCollateral(id, borrower, borrower, 5e18);
        vm.prank(borrower);
        engine.supplyCollateral(marketParams, 5e18, borrower, "");
        assertEq(_position(borrower).collateral, 105e18);
    }

    function test_supplyCollateral_reverts() public {
        vm.startPrank(borrower);
        vm.expectRevert(ILendingEngine.ZeroAmount.selector);
        engine.supplyCollateral(marketParams, 0, borrower, "");
        vm.expectRevert(ILendingEngine.ZeroAddress.selector);
        engine.supplyCollateral(marketParams, 1, address(0), "");
        MarketParams memory unknown = marketParams;
        unknown.lltv = 0.5e18;
        vm.expectRevert(abi.encodeWithSelector(ILendingEngine.MarketNotCreated.selector, unknown.id()));
        engine.supplyCollateral(unknown, 1, borrower, "");
        vm.stopPrank();
    }

    function test_supplyCollateral_callback() public {
        CollateralCallbackUser user = new CollateralCallbackUser(engine, marketParams);
        collateralToken.mint(address(user), 3e18);
        user.post(3e18);
        assertEq(user.seenAssets(), 3e18);
        assertEq(_position(address(user)).collateral, 3e18);
    }

    function test_withdrawCollateral() public {
        _borrow(borrower, 43e18); // needs 50e18 collateral at 86 % LLTV
        vm.expectEmit(address(engine));
        emit ILendingEngine.WithdrawCollateral(id, borrower, borrower, borrower, 50e18);
        vm.prank(borrower);
        engine.withdrawCollateral(marketParams, 50e18, borrower, borrower);
        assertEq(_position(borrower).collateral, 50e18);
        assertEq(_healthOf(borrower), 1e18);
    }

    function test_withdrawCollateral_withoutDebtSkipsOracle() public {
        oracle.setDown(true);
        vm.prank(borrower);
        engine.withdrawCollateral(marketParams, 100e18, borrower, borrower);
        assertEq(collateralToken.balanceOf(borrower), 100e18);
    }

    function test_withdrawCollateral_reverts() public {
        _borrow(borrower, 43e18);
        address stranger = makeAddr("stranger");
        vm.expectRevert(abi.encodeWithSelector(ILendingEngine.Unauthorized.selector, stranger, borrower));
        vm.prank(stranger);
        engine.withdrawCollateral(marketParams, 1, borrower, stranger);

        vm.startPrank(borrower);
        vm.expectRevert(ILendingEngine.ZeroAmount.selector);
        engine.withdrawCollateral(marketParams, 0, borrower, borrower);
        vm.expectRevert(ILendingEngine.ZeroAddress.selector);
        engine.withdrawCollateral(marketParams, 1, borrower, address(0));
        vm.expectRevert(abi.encodeWithSelector(ILendingEngine.InsufficientBalance.selector, 100e18, 100e18 + 1));
        engine.withdrawCollateral(marketParams, 100e18 + 1, borrower, borrower);
        vm.expectRevert(
            abi.encodeWithSelector(ILendingEngine.InsufficientCollateral.selector, 43e18, 42_999_999_999_999_999_999)
        );
        engine.withdrawCollateral(marketParams, 50e18 + 1, borrower, borrower);
        MarketParams memory unknown = marketParams;
        unknown.lltv = 0.5e18;
        vm.expectRevert(abi.encodeWithSelector(ILendingEngine.MarketNotCreated.selector, unknown.id()));
        engine.withdrawCollateral(unknown, 1, borrower, borrower);
        vm.stopPrank();
    }
}

contract RepayCallbackUser is IRepayCallback {
    ILendingEngine internal immutable ENGINE;
    MarketParams internal params;
    uint256 public seenAssets;

    constructor(ILendingEngine engine, MarketParams memory marketParams) {
        ENGINE = engine;
        params = marketParams;
    }

    function repayFor(address onBehalf, uint256 assets) external {
        ENGINE.repay(params, assets, 0, onBehalf, hex"01");
    }

    function onRepay(uint256 assets, bytes calldata) external {
        seenAssets = assets;
        (bool ok,) = params.loanToken.call(abi.encodeWithSignature("approve(address,uint256)", address(ENGINE), assets));
        require(ok, "approve");
    }
}

contract CollateralCallbackUser is ISupplyCollateralCallback {
    ILendingEngine internal immutable ENGINE;
    MarketParams internal params;
    uint256 public seenAssets;

    constructor(ILendingEngine engine, MarketParams memory marketParams) {
        ENGINE = engine;
        params = marketParams;
    }

    function post(uint256 assets) external {
        ENGINE.supplyCollateral(params, assets, address(this), hex"01");
    }

    function onSupplyCollateral(uint256 assets, bytes calldata) external {
        seenAssets = assets;
        (bool ok,) =
            params.collateralToken.call(abi.encodeWithSignature("approve(address,uint256)", address(ENGINE), assets));
        require(ok, "approve");
    }
}
