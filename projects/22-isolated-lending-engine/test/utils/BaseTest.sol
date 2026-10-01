// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";

import {LendingEngine} from "../../src/LendingEngine.sol";
import {ILendingEngine, Id, Market, MarketParams, Position} from "../../src/interfaces/ILendingEngine.sol";
import {LiquidationMath, ORACLE_PRICE_SCALE} from "../../src/libraries/LiquidationMath.sol";
import {MarketParamsLib} from "../../src/libraries/MarketParamsLib.sol";
import {WAD} from "../../src/libraries/MathLib.sol";
import {SharesMathLib} from "../../src/libraries/SharesMathLib.sol";

import {FixedRateIrm} from "../mocks/FixedRateIrm.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockOracle} from "../mocks/MockOracle.sol";

/// @notice Shared fixture: one engine, one market (loan/collateral at a 1:1 price, LLTV 86 %, 5 % max bonus,
///         slope 2) with a zero-rate IRM so balances only move when a test moves them.
abstract contract BaseTest is Test {
    using MarketParamsLib for MarketParams;
    using SharesMathLib for uint256;

    uint256 internal constant LLTV = 0.86e18;
    uint256 internal constant MAX_BONUS = 0.05e18;
    uint256 internal constant BONUS_SLOPE = 2e18;
    uint256 internal constant INITIAL_PRICE = ORACLE_PRICE_SCALE; // 1 collateral unit = 1 loan unit.

    address internal owner = makeAddr("owner");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal supplier = makeAddr("supplier");
    address internal borrower = makeAddr("borrower");
    address internal liquidator = makeAddr("liquidator");

    LendingEngine internal engine;
    MockERC20 internal loanToken;
    MockERC20 internal collateralToken;
    MockOracle internal oracle;
    FixedRateIrm internal irm;
    MarketParams internal marketParams;
    Id internal id;

    function setUp() public virtual {
        engine = new LendingEngine(owner, feeRecipient);
        loanToken = new MockERC20("Loan", "LOAN", 18);
        collateralToken = new MockERC20("Collateral", "COLL", 18);
        oracle = new MockOracle(INITIAL_PRICE);
        irm = new FixedRateIrm(0);

        vm.startPrank(owner);
        engine.enableIrm(address(irm));
        engine.enableLltv(LLTV, MAX_BONUS, BONUS_SLOPE);
        vm.stopPrank();

        marketParams = MarketParams({
            loanToken: address(loanToken),
            collateralToken: address(collateralToken),
            oracle: address(oracle),
            irm: address(irm),
            lltv: LLTV
        });
        id = engine.createMarket(marketParams);

        _approveAll(supplier);
        _approveAll(borrower);
        _approveAll(liquidator);
    }

    // ---------------------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------------------

    function _approveAll(address user) internal {
        vm.startPrank(user);
        loanToken.approve(address(engine), type(uint256).max);
        collateralToken.approve(address(engine), type(uint256).max);
        vm.stopPrank();
    }

    function _supply(address user, uint256 assets) internal returns (uint256 shares) {
        loanToken.mint(user, assets);
        vm.prank(user);
        (, shares) = engine.supply(marketParams, assets, 0, user, "");
    }

    function _supplyCollateral(address user, uint256 assets) internal {
        collateralToken.mint(user, assets);
        vm.prank(user);
        engine.supplyCollateral(marketParams, assets, user, "");
    }

    function _borrow(address user, uint256 assets) internal returns (uint256 shares) {
        vm.prank(user);
        (, shares) = engine.borrow(marketParams, assets, 0, user, user);
    }

    /// @dev Opens a position with `collateral` and borrows `ltv` of its value (WAD) against a fresh supply.
    function _openPosition(address user, uint256 collateral, uint256 ltv) internal returns (uint256 borrowed) {
        borrowed = collateral * oracle.currentPrice() / ORACLE_PRICE_SCALE * ltv / WAD;
        _supply(supplier, borrowed * 2 + 1e18);
        _supplyCollateral(user, collateral);
        if (borrowed > 0) _borrow(user, borrowed);
    }

    function _market() internal view returns (Market memory) {
        return engine.market(id);
    }

    function _position(address user) internal view returns (Position memory) {
        return engine.position(id, user);
    }

    function _debtOf(address user) internal view returns (uint256) {
        Market memory m = engine.market(id);
        return uint256(engine.position(id, user).borrowShares).toAssetsUp(m.totalBorrowAssets, m.totalBorrowShares);
    }

    function _healthOf(address user) internal view returns (uint256) {
        return engine.healthFactor(marketParams, user);
    }

    /// @dev Sets the collateral price so that `user`'s health factor lands at (or just below) `targetHealth`.
    function _setHealth(address user, uint256 targetHealth) internal {
        Position memory p = engine.position(id, user);
        uint256 debt = _debtOf(user);
        // health = collateral * price / 1e36 * lltv / debt  =>  price = health * debt * 1e36 / (collateral * lltv)
        uint256 newPrice = targetHealth * debt / WAD * ORACLE_PRICE_SCALE / (uint256(p.collateral) * LLTV / WAD);
        oracle.setPrice(newPrice);
    }
}
