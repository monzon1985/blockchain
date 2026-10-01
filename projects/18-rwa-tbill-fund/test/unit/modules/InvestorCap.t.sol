// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IAccessManaged} from "@openzeppelin-contracts/access/manager/IAccessManaged.sol";
import {ComplianceEngine} from "../../../src/compliance/ComplianceEngine.sol";
import {ComplianceModuleBase} from "../../../src/compliance/modules/ComplianceModuleBase.sol";
import {InvestorCapModule} from "../../../src/compliance/modules/InvestorCapModule.sol";
import {TransferContext, TransferKind} from "../../../src/interfaces/ICompliance.sol";
import {FundVault} from "../../../src/vault/FundVault.sol";
import {FundFixture} from "../../utils/FundFixture.sol";

contract InvestorCapTest is FundFixture {
    uint256 internal constant CAP = 500 * USDC;

    function setUp() public override {
        super.setUp();
        _seed(alice, 400 * USDC);
        _seed(bob, 400 * USDC);
        vm.prank(complianceOfficer);
        investorCap.setMaxPerInvestor(CAP);
    }

    function _rejection(address from, address to, uint256 amount, TransferKind kind)
        internal
        view
        returns (bytes memory)
    {
        return abi.encodeWithSelector(
            ComplianceEngine.ComplianceModuleRejected.selector, address(investorCap), kind, from, to, amount
        );
    }

    function test_metadata() public view {
        assertEq(investorCap.name(), "InvestorCap");
        assertFalse(investorCap.isStateful());
        assertEq(investorCap.maxPerInvestor(), CAP);
    }

    function test_constructor_rejectsZeroEngine() public {
        vm.expectRevert(ComplianceModuleBase.InvalidEngine.selector);
        new InvestorCapModule(address(manager), address(0));
    }

    function test_setMaxPerInvestor_emits() public {
        vm.expectEmit(address(investorCap));
        emit InvestorCapModule.InvestorCapSet(1);
        vm.prank(complianceOfficer);
        investorCap.setMaxPerInvestor(1);
    }

    function test_setMaxPerInvestor_restricted() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        investorCap.setMaxPerInvestor(1);
    }

    function test_transferUpToCapAllowed() public {
        vm.prank(alice);
        share.transfer(bob, 100 * USDC);
        assertEq(engine.investorBalance(ID_BOB), CAP);
    }

    function test_transferAboveCapRejected() public {
        vm.prank(alice);
        vm.expectRevert(_rejection(alice, bob, 100 * USDC + 1, TransferKind.Transfer));
        share.transfer(bob, 100 * USDC + 1);
    }

    function test_subscriptionAboveCapRejectedAtRequest() public {
        _fund(alice, 200 * USDC);
        vm.prank(alice);
        // 400 held + ceil(200e6 / 0.98) at the lowest NAV the circuit breaker allows > 500.
        vm.expectRevert(abi.encodeWithSelector(FundVault.SubscriptionNotAdmissible.selector, alice, 204_081_633));
        vault.requestDeposit(200 * USDC, alice, alice);
    }

    function test_subscriptionRequestUsesTheLowestAcceptableNav() public {
        _fund(alice, 100 * USDC);
        vm.startPrank(alice);
        // 98 USDC is at most 100 shares at NAV 0.98: 400 + 100 = 500 fits exactly; one more unit does not.
        vm.expectRevert(abi.encodeWithSelector(FundVault.SubscriptionNotAdmissible.selector, alice, 100 * USDC + 2));
        vault.requestDeposit(98 * USDC + 1, alice, alice);
        vault.requestDeposit(98 * USDC, alice, alice);
        vm.stopPrank();
    }

    function test_mintAboveCapRejected() public {
        _requestDeposit(alice, 50 * USDC); // admissible when requested
        vm.prank(complianceOfficer);
        investorCap.setMaxPerInvestor(420 * USDC); // the cap drops before the claim
        _closeAndSettle(NAV_ONE);
        vm.prank(alice);
        vm.expectRevert(_rejection(address(0), alice, 50 * USDC, TransferKind.Mint));
        vault.deposit(50 * USDC, alice, alice);
    }

    function test_capAggregatesAcrossWalletsOfSameInvestor() public {
        _bind(alice2, ID_ALICE);
        vm.prank(bob);
        vm.expectRevert(_rejection(bob, alice2, 100 * USDC + 1, TransferKind.Transfer));
        share.transfer(alice2, 100 * USDC + 1);
    }

    function test_movesBetweenOwnWalletsIgnoreCap() public {
        vm.prank(complianceOfficer);
        investorCap.setMaxPerInvestor(1); // far below alice's holding
        _bind(alice2, ID_ALICE);
        vm.prank(alice);
        share.transfer(alice2, 400 * USDC);
        assertEq(share.balanceOf(alice2), 400 * USDC);
    }

    function test_check_edgeCases() public view {
        TransferContext memory ctx;
        ctx.kind = TransferKind.Burn;
        ctx.from = alice;
        ctx.amount = 1;
        assertTrue(investorCap.check(ctx), "burns always pass");

        ctx.kind = TransferKind.Transfer;
        ctx.to = bob;
        ctx.amount = 0;
        ctx.toInvestorBalance = CAP + 1;
        assertTrue(investorCap.check(ctx), "zero amount passes");

        ctx.amount = 1;
        ctx.fromId = ID_ALICE;
        ctx.toId = ID_BOB;
        assertFalse(investorCap.check(ctx), "already above a lowered cap");

        ctx.toInvestorBalance = 0;
        ctx.amount = type(uint256).max;
        assertFalse(investorCap.check(ctx), "no overflow on huge amounts");
    }
}
