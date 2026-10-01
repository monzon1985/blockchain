// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {BaseTest} from "../utils/BaseTest.sol";

import {LendingEngine} from "../../src/LendingEngine.sol";
import {ILendingEngine, Id, LiquidationConfig, MarketParams} from "../../src/interfaces/ILendingEngine.sol";
import {MarketParamsLib} from "../../src/libraries/MarketParamsLib.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract GovernanceTest is BaseTest {
    using MarketParamsLib for MarketParams;

    address internal stranger = makeAddr("stranger");

    // --- constructor -------------------------------------------------------------------------------------------

    function test_constructor_setsOwnerAndFeeRecipient() public view {
        assertEq(engine.owner(), owner);
        assertEq(engine.feeRecipient(), feeRecipient);
    }

    function test_constructor_revertsOnZeroFeeRecipient() public {
        vm.expectRevert(ILendingEngine.ZeroAddress.selector);
        new LendingEngine(owner, address(0));
    }

    function test_constructor_revertsOnZeroOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new LendingEngine(address(0), feeRecipient);
    }

    // --- enableIrm ---------------------------------------------------------------------------------------------

    function test_enableIrm() public {
        address newIrm = makeAddr("newIrm");
        vm.expectEmit(address(engine));
        emit ILendingEngine.EnableIrm(newIrm);
        vm.prank(owner);
        engine.enableIrm(newIrm);
        assertTrue(engine.isIrmEnabled(newIrm));
    }

    function test_enableIrm_revertsForNonOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        engine.enableIrm(makeAddr("newIrm"));
    }

    function test_enableIrm_revertsOnZeroAddress() public {
        vm.expectRevert(ILendingEngine.ZeroAddress.selector);
        vm.prank(owner);
        engine.enableIrm(address(0));
    }

    function test_enableIrm_revertsWhenAlreadyEnabled() public {
        vm.expectRevert(abi.encodeWithSelector(ILendingEngine.IrmAlreadyEnabled.selector, address(irm)));
        vm.prank(owner);
        engine.enableIrm(address(irm));
    }

    // --- enableLltv --------------------------------------------------------------------------------------------

    function test_enableLltv() public {
        vm.expectEmit(address(engine));
        emit ILendingEngine.EnableLltv(0.77e18, 0.08e18, 1e18);
        vm.prank(owner);
        engine.enableLltv(0.77e18, 0.08e18, 1e18);
        LiquidationConfig memory cfg = engine.liquidationConfig(0.77e18);
        assertTrue(cfg.enabled);
        assertEq(cfg.maxBonus, 0.08e18);
        assertEq(cfg.bonusSlope, 1e18);
    }

    function test_enableLltv_revertsForNonOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        engine.enableLltv(0.5e18, 0.05e18, 1e18);
    }

    function test_enableLltv_revertsWhenAlreadyEnabled() public {
        vm.expectRevert(abi.encodeWithSelector(ILendingEngine.LltvAlreadyEnabled.selector, LLTV));
        vm.prank(owner);
        engine.enableLltv(LLTV, 0.01e18, 1e18);
    }

    function test_enableLltv_revertsOnInvalidConfig() public {
        _expectInvalidConfig(0, 0.05e18, 1e18); // zero LLTV
        _expectInvalidConfig(1e18, 0.05e18, 1e18); // LLTV = 100 %
        _expectInvalidConfig(0.5e18, 0, 1e18); // zero bonus cap
        _expectInvalidConfig(0.5e18, 0.25e18 + 1, 1e18); // bonus cap above MAX_BONUS
        _expectInvalidConfig(0.5e18, 0.05e18, 0); // zero slope
        _expectInvalidConfig(0.5e18, 0.05e18, 20e18 + 1); // slope above MAX_BONUS_SLOPE
        _expectInvalidConfig(0.96e18, 0.05e18, 1e18); // 0.96 * 1.05 >= 1: max-bonus liquidation at LLTV is insolvent
    }

    function test_enableLltv_acceptsBoundaryConfig() public {
        vm.startPrank(owner);
        engine.enableLltv(0.5e18, engine.MAX_BONUS(), engine.MAX_BONUS_SLOPE());
        // 0.95 * 1.05 = 0.9975 < 1
        engine.enableLltv(0.95e18, 0.05e18, 1);
        vm.stopPrank();
        assertTrue(engine.liquidationConfig(0.95e18).enabled);
    }

    function _expectInvalidConfig(uint256 lltv, uint256 maxBonus, uint256 slope) internal {
        vm.expectRevert(abi.encodeWithSelector(ILendingEngine.InvalidLiquidationConfig.selector, lltv, maxBonus, slope));
        vm.prank(owner);
        engine.enableLltv(lltv, maxBonus, slope);
    }

    // --- setFee ------------------------------------------------------------------------------------------------

    function test_setFee() public {
        vm.expectEmit(address(engine));
        emit ILendingEngine.SetFee(id, 0.1e18);
        vm.prank(owner);
        engine.setFee(marketParams, 0.1e18);
        assertEq(engine.market(id).fee, 0.1e18);
    }

    function test_setFee_accruesAtOldFeeFirst() public {
        irm.setRate(uint256(0.1e18) / 365 days);
        _openPosition(borrower, 100e18, 0.5e18);
        skip(30 days);
        vm.prank(owner);
        engine.setFee(marketParams, 0.2e18);
        // Interest accrued under a zero fee: no fee shares.
        assertEq(engine.position(id, feeRecipient).supplyShares, 0);
        assertEq(engine.market(id).lastUpdate, block.timestamp);
    }

    function test_setFee_revertsForNonOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        engine.setFee(marketParams, 0.1e18);
    }

    function test_setFee_revertsOnUnknownMarket() public {
        MarketParams memory unknown = marketParams;
        unknown.lltv = 0.5e18;
        vm.expectRevert(abi.encodeWithSelector(ILendingEngine.MarketNotCreated.selector, unknown.id()));
        vm.prank(owner);
        engine.setFee(unknown, 0.1e18);
    }

    function test_setFee_revertsWhenUnchanged() public {
        vm.expectRevert(abi.encodeWithSelector(ILendingEngine.FeeAlreadySet.selector, 0));
        vm.prank(owner);
        engine.setFee(marketParams, 0);
    }

    function test_setFee_revertsAboveMax() public {
        vm.expectRevert(abi.encodeWithSelector(ILendingEngine.MaxFeeExceeded.selector, 0.25e18 + 1));
        vm.prank(owner);
        engine.setFee(marketParams, 0.25e18 + 1);
    }

    // --- setFeeRecipient ---------------------------------------------------------------------------------------

    function test_setFeeRecipient() public {
        address newRecipient = makeAddr("newRecipient");
        vm.expectEmit(address(engine));
        emit ILendingEngine.SetFeeRecipient(newRecipient);
        vm.prank(owner);
        engine.setFeeRecipient(newRecipient);
        assertEq(engine.feeRecipient(), newRecipient);
    }

    function test_setFeeRecipient_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        engine.setFeeRecipient(stranger);

        vm.startPrank(owner);
        vm.expectRevert(ILendingEngine.ZeroAddress.selector);
        engine.setFeeRecipient(address(0));
        vm.expectRevert(abi.encodeWithSelector(ILendingEngine.FeeRecipientAlreadySet.selector, feeRecipient));
        engine.setFeeRecipient(feeRecipient);
        vm.stopPrank();
    }

    // --- ownership ---------------------------------------------------------------------------------------------

    function test_ownershipTransferIsTwoStep() public {
        address newOwner = makeAddr("newOwner");
        vm.prank(owner);
        engine.transferOwnership(newOwner);
        assertEq(engine.owner(), owner);
        assertEq(engine.pendingOwner(), newOwner);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        engine.acceptOwnership();

        vm.prank(newOwner);
        engine.acceptOwnership();
        assertEq(engine.owner(), newOwner);
    }

    // --- market creation ---------------------------------------------------------------------------------------

    function test_createMarket_storesParamsAndEmits() public {
        MarketParams memory params = marketParams;
        params.collateralToken = makeAddr("otherCollateral");
        Id expectedId = Id.wrap(keccak256(abi.encode(params)));

        vm.expectEmit(address(engine));
        emit ILendingEngine.CreateMarket(expectedId, params);
        vm.prank(stranger); // permissionless
        Id newId = engine.createMarket(params);

        assertEq(Id.unwrap(newId), Id.unwrap(expectedId));
        assertEq(engine.market(newId).lastUpdate, block.timestamp);
        MarketParams memory stored = engine.idToMarketParams(newId);
        assertEq(stored.loanToken, params.loanToken);
        assertEq(stored.collateralToken, params.collateralToken);
        assertEq(stored.oracle, params.oracle);
        assertEq(stored.irm, params.irm);
        assertEq(stored.lltv, params.lltv);
    }

    function test_createMarket_revertsOnDisabledIrm() public {
        MarketParams memory params = marketParams;
        params.irm = stranger;
        vm.expectRevert(abi.encodeWithSelector(ILendingEngine.IrmNotEnabled.selector, stranger));
        engine.createMarket(params);
    }

    function test_createMarket_revertsOnDisabledLltv() public {
        MarketParams memory params = marketParams;
        params.lltv = 0.5e18;
        vm.expectRevert(abi.encodeWithSelector(ILendingEngine.LltvNotEnabled.selector, 0.5e18));
        engine.createMarket(params);
    }

    function test_createMarket_revertsOnZeroAddresses() public {
        MarketParams memory params = marketParams;
        params.loanToken = address(0);
        vm.expectRevert(ILendingEngine.ZeroAddress.selector);
        engine.createMarket(params);

        params = marketParams;
        params.collateralToken = address(0);
        vm.expectRevert(ILendingEngine.ZeroAddress.selector);
        engine.createMarket(params);

        params = marketParams;
        params.oracle = address(0);
        vm.expectRevert(ILendingEngine.ZeroAddress.selector);
        engine.createMarket(params);
    }

    function test_createMarket_revertsOnSameTokens() public {
        MarketParams memory params = marketParams;
        params.collateralToken = params.loanToken;
        vm.expectRevert(abi.encodeWithSelector(ILendingEngine.SameTokens.selector, params.loanToken));
        engine.createMarket(params);
    }

    function test_createMarket_revertsWhenExists() public {
        vm.expectRevert(abi.encodeWithSelector(ILendingEngine.MarketAlreadyCreated.selector, id));
        engine.createMarket(marketParams);
    }

    function test_marketId_matchesAbiEncodeHash(MarketParams memory params) public pure {
        assertEq(Id.unwrap(params.id()), keccak256(abi.encode(params)));
    }
}
