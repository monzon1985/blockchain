// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";

import {LendingEngine} from "../../src/LendingEngine.sol";
import {ILendingEngine, Id, Market, MarketParams, Position} from "../../src/interfaces/ILendingEngine.sol";
import {FixedRateIrm} from "../mocks/FixedRateIrm.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockOracle} from "../mocks/MockOracle.sol";

/// @notice Differential test: replays the 100 scenarios written by `cascade-sim export-vectors` (expectations
///         computed by the Rust `risk-math` crate) against a freshly deployed engine and requires identical results:
///         health factor, bonus, seized and repaid amounts, bad debt, resulting state, or the exact revert.
/// @dev Pre-state is written with `vm.store` into the engine's storage (layout checked by
///      `test_storageHelperMatchesGetters`), so arbitrary share prices and positions can be reproduced exactly.
contract HealthVectorsTest is Test {
    string internal constant VECTORS = "test/vectors/liquidation-vectors.json";
    uint256 internal constant MARKET_SLOT = 9;
    uint256 internal constant POSITION_SLOT = 10;

    address internal borrower = makeAddr("borrower");
    string internal json;

    struct Fixture {
        LendingEngine engine;
        MockERC20 loanToken;
        MockERC20 collateralToken;
        MarketParams params;
        Id id;
    }

    struct Expectation {
        string outcome;
        uint256[] errorArgs;
        uint256 healthBefore;
        uint256 bonus;
        uint256 seizedAssets;
        uint256 repaidShares;
        uint256 repaidAssets;
        uint256 badDebtAssets;
        uint256 badDebtShares;
        uint256 healthAfter;
        uint256 collateralAfter;
        uint256 borrowSharesAfter;
        uint256 totalSupplyAssetsAfter;
        uint256 totalBorrowAssetsAfter;
        uint256 totalBorrowSharesAfter;
    }

    function setUp() public {
        json = vm.readFile(VECTORS);
    }

    function _key(uint256 i, string memory field) internal pure returns (string memory) {
        return string.concat(".vectors[", vm.toString(i), "].", field);
    }

    function _u(uint256 i, string memory field) internal view returns (uint256) {
        return vm.parseJsonUint(json, _key(i, field));
    }

    function _deploy(uint256 i) internal returns (Fixture memory f) {
        f.engine = new LendingEngine(address(this), address(this));
        f.loanToken = new MockERC20("Loan", "LOAN", 18);
        f.collateralToken = new MockERC20("Collateral", "COLL", 18);
        MockOracle oracle = new MockOracle(_u(i, "price"));
        FixedRateIrm irm = new FixedRateIrm(0);
        f.engine.enableIrm(address(irm));
        f.engine.enableLltv(_u(i, "lltv"), _u(i, "maxBonus"), _u(i, "bonusSlope"));
        f.params = MarketParams(
            address(f.loanToken), address(f.collateralToken), address(oracle), address(irm), _u(i, "lltv")
        );
        f.id = f.engine.createMarket(f.params);
    }

    /// @dev Writes market totals and the borrower's position straight into the engine's storage.
    function _writeState(
        Fixture memory f,
        uint256 totalSupplyAssets,
        uint256 totalSupplyShares,
        uint256 totalBorrowAssets,
        uint256 totalBorrowShares,
        uint256 collateral,
        uint256 borrowShares
    ) internal {
        bytes32 marketSlot = keccak256(abi.encode(f.id, MARKET_SLOT));
        vm.store(address(f.engine), marketSlot, bytes32(totalSupplyAssets | (totalSupplyShares << 128)));
        vm.store(
            address(f.engine), bytes32(uint256(marketSlot) + 1), bytes32(totalBorrowAssets | (totalBorrowShares << 128))
        );
        bytes32 positionSlot = keccak256(abi.encode(borrower, keccak256(abi.encode(f.id, POSITION_SLOT))));
        vm.store(address(f.engine), bytes32(uint256(positionSlot) + 1), bytes32(borrowShares | (collateral << 128)));
    }

    function _expectation(uint256 i) internal view returns (Expectation memory e) {
        e.outcome = vm.parseJsonString(json, _key(i, "expected.outcome"));
        e.errorArgs = vm.parseJsonUintArray(json, _key(i, "expected.errorArgs"));
        e.healthBefore = _u(i, "expected.healthBefore");
        e.bonus = _u(i, "expected.bonus");
        e.seizedAssets = _u(i, "expected.seizedAssets");
        e.repaidShares = _u(i, "expected.repaidShares");
        e.repaidAssets = _u(i, "expected.repaidAssets");
        e.badDebtAssets = _u(i, "expected.badDebtAssets");
        e.badDebtShares = _u(i, "expected.badDebtShares");
        e.healthAfter = _u(i, "expected.healthAfter");
        e.collateralAfter = _u(i, "expected.collateralAfter");
        e.borrowSharesAfter = _u(i, "expected.borrowSharesAfter");
        e.totalSupplyAssetsAfter = _u(i, "expected.totalSupplyAssetsAfter");
        e.totalBorrowAssetsAfter = _u(i, "expected.totalBorrowAssetsAfter");
        e.totalBorrowSharesAfter = _u(i, "expected.totalBorrowSharesAfter");
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    function _expectedRevert(Expectation memory e) internal pure returns (bytes memory) {
        if (_eq(e.outcome, "HealthyPosition")) {
            return abi.encodeWithSelector(ILendingEngine.HealthyPosition.selector, e.errorArgs[0]);
        }
        if (_eq(e.outcome, "HealthDecreased")) {
            return abi.encodeWithSelector(ILendingEngine.HealthDecreased.selector, e.errorArgs[0], e.errorArgs[1]);
        }
        if (_eq(e.outcome, "RepayExceedsDebt")) {
            return abi.encodeWithSelector(ILendingEngine.RepayExceedsDebt.selector, e.errorArgs[0], e.errorArgs[1]);
        }
        if (_eq(e.outcome, "SeizeExceedsCollateral")) {
            return
                abi.encodeWithSelector(ILendingEngine.SeizeExceedsCollateral.selector, e.errorArgs[0], e.errorArgs[1]);
        }
        revert(string.concat("unknown outcome ", e.outcome));
    }

    function _replay(uint256 i) internal {
        string memory name = vm.parseJsonString(json, _key(i, "name"));
        Fixture memory f = _deploy(i);
        uint256 totalSupplyShares = _u(i, "totalSupplyShares");
        _writeState(
            f,
            _u(i, "totalSupplyAssets"),
            totalSupplyShares,
            _u(i, "totalBorrowAssets"),
            _u(i, "totalBorrowShares"),
            _u(i, "collateral"),
            _u(i, "borrowShares")
        );
        f.collateralToken.mint(address(f.engine), _u(i, "collateral"));
        f.loanToken.mint(address(this), type(uint128).max);
        f.loanToken.approve(address(f.engine), type(uint256).max);

        Expectation memory e = _expectation(i);
        uint256 seizedIn = _u(i, "seizedAssets");
        uint256 repaidIn = _u(i, "repaidShares");

        if (!_eq(e.outcome, "ok")) {
            vm.expectRevert(_expectedRevert(e));
            f.engine.liquidate(f.params, borrower, seizedIn, repaidIn, "");
            return;
        }

        assertEq(f.engine.healthFactor(f.params, borrower), e.healthBefore, string.concat(name, ": health before"));
        vm.expectEmit(address(f.engine));
        emit ILendingEngine.Liquidate(
            f.id,
            address(this),
            borrower,
            e.repaidAssets,
            e.repaidShares,
            e.seizedAssets,
            e.badDebtAssets,
            e.badDebtShares,
            e.healthBefore,
            e.bonus
        );
        (uint256 seized, uint256 repaid) = f.engine.liquidate(f.params, borrower, seizedIn, repaidIn, "");
        assertEq(seized, e.seizedAssets, string.concat(name, ": seized"));
        assertEq(repaid, e.repaidAssets, string.concat(name, ": repaid"));

        Position memory p = f.engine.position(f.id, borrower);
        Market memory m = f.engine.market(f.id);
        assertEq(p.collateral, e.collateralAfter, string.concat(name, ": collateral after"));
        assertEq(p.borrowShares, e.borrowSharesAfter, string.concat(name, ": borrow shares after"));
        assertEq(m.totalSupplyAssets, e.totalSupplyAssetsAfter, string.concat(name, ": total supply after"));
        assertEq(m.totalSupplyShares, totalSupplyShares, string.concat(name, ": supply shares unchanged"));
        assertEq(m.totalBorrowAssets, e.totalBorrowAssetsAfter, string.concat(name, ": total borrow after"));
        assertEq(m.totalBorrowShares, e.totalBorrowSharesAfter, string.concat(name, ": total borrow shares after"));
        assertEq(f.engine.healthFactor(f.params, borrower), e.healthAfter, string.concat(name, ": health after"));
    }

    function test_vectorFileHeader() public view {
        assertEq(vm.parseJsonString(json, ".schema"), "isolated-lending/liquidation-vectors/v1");
        assertEq(vm.parseJsonUint(json, ".count"), 100);
    }

    function test_replayVectors_0_to_24() public {
        for (uint256 i = 0; i < 25; ++i) {
            _replay(i);
        }
    }

    function test_replayVectors_25_to_49() public {
        for (uint256 i = 25; i < 50; ++i) {
            _replay(i);
        }
    }

    function test_replayVectors_50_to_74() public {
        for (uint256 i = 50; i < 75; ++i) {
            _replay(i);
        }
    }

    function test_replayVectors_75_to_99() public {
        for (uint256 i = 75; i < 100; ++i) {
            _replay(i);
        }
    }

    function test_storageHelperMatchesGetters() public {
        Fixture memory f = _deploy(0);
        _writeState(f, 11, 22, 33, 44, 55, 66);
        Market memory m = f.engine.market(f.id);
        Position memory p = f.engine.position(f.id, borrower);
        assertEq(m.totalSupplyAssets, 11);
        assertEq(m.totalSupplyShares, 22);
        assertEq(m.totalBorrowAssets, 33);
        assertEq(m.totalBorrowShares, 44);
        assertEq(p.collateral, 55);
        assertEq(p.borrowShares, 66);
        assertEq(m.lastUpdate, block.timestamp, "lastUpdate untouched, so liquidate accrues nothing");
    }
}
