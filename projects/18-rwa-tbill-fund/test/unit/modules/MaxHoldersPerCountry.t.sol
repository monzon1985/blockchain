// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IAccessManaged} from "@openzeppelin-contracts/access/manager/IAccessManaged.sol";
import {ComplianceEngine} from "../../../src/compliance/ComplianceEngine.sol";
import {ComplianceModuleBase} from "../../../src/compliance/modules/ComplianceModuleBase.sol";
import {MaxHoldersPerCountryModule} from "../../../src/compliance/modules/MaxHoldersPerCountryModule.sol";
import {TransferContext, TransferKind} from "../../../src/interfaces/ICompliance.sol";
import {FundVault} from "../../../src/vault/FundVault.sol";
import {FundFixture} from "../../utils/FundFixture.sol";

contract MaxHoldersPerCountryTest is FundFixture {
    function setUp() public override {
        super.setUp();
        _seed(alice, 1000 * USDC); // US holder #1
    }

    function _capCountry(uint16 country, uint64 limit) internal {
        vm.prank(complianceOfficer);
        maxHolders.setCountryCap(country, limit);
    }

    function _rejection(address from, address to, uint256 amount, TransferKind kind)
        internal
        view
        returns (bytes memory)
    {
        return abi.encodeWithSelector(
            ComplianceEngine.ComplianceModuleRejected.selector, address(maxHolders), kind, from, to, amount
        );
    }

    function test_metadata() public view {
        assertEq(maxHolders.name(), "MaxHoldersPerCountry");
        assertFalse(maxHolders.isStateful());
        assertEq(maxHolders.engine(), address(engine));
    }

    function test_setCountryCap_emitsAndStores() public {
        vm.expectEmit(address(maxHolders));
        emit MaxHoldersPerCountryModule.CountryCapSet(US, true, 5);
        _capCountry(US, 5);
        (bool capped, uint64 limit) = maxHolders.countryCap(US);
        assertTrue(capped);
        assertEq(limit, 5);
    }

    function test_setCountryCap_restricted() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        maxHolders.setCountryCap(US, 1);
    }

    function test_capBlocksNewHolderOnTransfer() public {
        _capCountry(US, 1);
        vm.prank(alice);
        vm.expectRevert(_rejection(alice, bob, 1, TransferKind.Transfer));
        share.transfer(bob, 1);
        assertFalse(share.canTransfer(alice, bob, 1));
    }

    function test_capBlocksNewHolderAtSubscriptionRequest() public {
        _capCountry(US, 1);
        _fund(bob, 100 * USDC);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(FundVault.SubscriptionNotAdmissible.selector, bob, uint256(102_040_817)));
        vault.requestDeposit(100 * USDC, bob, bob); // ceil(100e6 / 0.98) shares at the lowest acceptable NAV
        assertEq(usdc.balanceOf(bob), 100 * USDC, "no cash moved");
    }

    function test_capBlocksNewHolderOnSubscriptionClaim() public {
        _requestDeposit(bob, 100 * USDC); // admissible when requested
        _capCountry(US, 1); // the country fills up before the claim
        _closeAndSettle(NAV_ONE);
        vm.prank(bob);
        vm.expectRevert(_rejection(address(0), bob, 100 * USDC, TransferKind.Mint));
        vault.deposit(100 * USDC, bob, bob);
    }

    function test_capAllowsExistingHolderToReceive() public {
        _seed(bob, 10 * USDC);
        _capCountry(US, 2);
        vm.prank(alice);
        share.transfer(bob, 5);
        assertEq(engine.holderCount(US), 2);
    }

    function test_capAllowsFullExitIntoSameCountry() public {
        _capCountry(US, 1);
        uint256 balance = share.balanceOf(alice);
        assertTrue(share.canTransfer(alice, bob, balance));
        vm.prank(alice);
        share.transfer(bob, balance);
        assertEq(engine.holderCount(US), 1);
    }

    function test_capBlocksFullExitIntoOtherCappedCountry() public {
        _seed(carol, 10 * USDC); // DE holder
        _capCountry(US, 1);
        uint256 balance = share.balanceOf(carol);
        vm.prank(carol);
        vm.expectRevert(_rejection(carol, bob, balance, TransferKind.Transfer));
        share.transfer(bob, balance);
    }

    function test_capZeroBansNewHoldersFromCountry() public {
        _capCountry(SG, 0);
        vm.prank(alice);
        vm.expectRevert(_rejection(alice, dave, 1, TransferKind.Transfer));
        share.transfer(dave, 1);
    }

    function test_capAppliesToForcedTransfers() public {
        bytes32 order = keccak256("order-1");
        _issueOrder(order, alice, bob, 1);
        _capCountry(US, 1);
        vm.prank(transferAgent);
        vm.expectRevert(_rejection(alice, bob, 1, TransferKind.Forced));
        share.forcedTransfer(alice, bob, 1, order);
    }

    function test_clearCountryCap_removesLimit() public {
        _capCountry(US, 1);
        vm.expectEmit(address(maxHolders));
        emit MaxHoldersPerCountryModule.CountryCapSet(US, false, 0);
        vm.prank(complianceOfficer);
        maxHolders.clearCountryCap(US);
        vm.prank(alice);
        share.transfer(bob, 1);
        assertEq(engine.holderCount(US), 2);
    }

    function test_globalCap_blocksBeyondLimit() public {
        _seed(carol, 10 * USDC);
        vm.expectEmit(address(maxHolders));
        emit MaxHoldersPerCountryModule.GlobalCapSet(true, 2);
        vm.prank(complianceOfficer);
        maxHolders.setGlobalCap(true, 2);
        vm.prank(alice);
        vm.expectRevert(_rejection(alice, dave, 1, TransferKind.Transfer));
        share.transfer(dave, 1);
    }

    function test_globalCap_allowsFullExitSwap() public {
        _seed(carol, 10 * USDC);
        vm.prank(complianceOfficer);
        maxHolders.setGlobalCap(true, 2);
        uint256 balance = share.balanceOf(carol);
        vm.prank(carol);
        share.transfer(dave, balance);
        assertEq(engine.totalHolders(), 2);
    }

    function test_globalCap_clearStoresZeroLimit() public {
        vm.startPrank(complianceOfficer);
        maxHolders.setGlobalCap(true, 1);
        vm.expectEmit(address(maxHolders));
        emit MaxHoldersPerCountryModule.GlobalCapSet(false, 0);
        maxHolders.setGlobalCap(false, 7);
        vm.stopPrank();
        (bool capped, uint64 limit) = maxHolders.globalCap();
        assertFalse(capped);
        assertEq(limit, 0);
        vm.prank(alice);
        share.transfer(bob, 1);
    }

    function test_check_passesWhenRecipientAlreadyHolds() public view {
        TransferContext memory ctx;
        ctx.kind = TransferKind.Transfer;
        ctx.toBecomesHolder = false;
        assertTrue(maxHolders.check(ctx));
    }

    function test_onTransfer_onlyEngine() public {
        TransferContext memory ctx;
        vm.expectRevert(abi.encodeWithSelector(ComplianceModuleBase.NotEngine.selector, address(this)));
        maxHolders.onTransfer(ctx);
        vm.prank(address(engine));
        maxHolders.onTransfer(ctx); // no-op for stateless modules
    }
}
