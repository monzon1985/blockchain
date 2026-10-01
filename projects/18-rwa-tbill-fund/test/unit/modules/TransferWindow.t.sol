// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IAccessManaged} from "@openzeppelin-contracts/access/manager/IAccessManaged.sol";
import {ComplianceEngine} from "../../../src/compliance/ComplianceEngine.sol";
import {TransferWindowModule} from "../../../src/compliance/modules/TransferWindowModule.sol";
import {TransferKind} from "../../../src/interfaces/ICompliance.sol";
import {FundFixture} from "../../utils/FundFixture.sol";

contract TransferWindowTest is FundFixture {
    uint8 internal constant WEEKDAYS = 0x1f; // Monday..Friday
    uint32 internal constant OPEN = 9 hours;
    uint32 internal constant CLOSE = 17 hours;
    uint256 internal constant MONDAY = 1_767_571_200; // 2026-01-05 00:00 UTC

    function setUp() public override {
        super.setUp();
        _seed(alice, 100 * USDC);
        vm.prank(complianceOfficer);
        transferWindow.setWindow(WEEKDAYS, OPEN, CLOSE);
    }

    function _rejection(uint256 amount) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            ComplianceEngine.ComplianceModuleRejected.selector,
            address(transferWindow),
            TransferKind.Transfer,
            alice,
            bob,
            amount
        );
    }

    function test_metadata() public view {
        assertEq(transferWindow.name(), "TransferWindow");
        assertTrue(transferWindow.enabled());
        assertEq(transferWindow.weekdayMask(), WEEKDAYS);
        assertEq(transferWindow.openSecond(), OPEN);
        assertEq(transferWindow.closeSecond(), CLOSE);
    }

    function test_isOpenAt_weekdayMath() public view {
        assertTrue(transferWindow.isOpenAt(MONDAY + 7 days + 9 hours), "Monday 09:00");
        assertFalse(transferWindow.isOpenAt(MONDAY + 7 days + 17 hours), "Monday 17:00 is closed");
        assertFalse(transferWindow.isOpenAt(MONDAY + 7 days + 8 hours), "Monday 08:00");
        assertTrue(transferWindow.isOpenAt(MONDAY + 4 days + 12 hours), "Friday noon");
        assertFalse(transferWindow.isOpenAt(MONDAY + 5 days + 12 hours), "Saturday noon");
        assertFalse(transferWindow.isOpenAt(MONDAY + 6 days + 12 hours), "Sunday noon");
        assertTrue(transferWindow.isOpenAt(12 hours), "1970-01-01 (a Thursday) at noon");
    }

    function test_transferInsideWindow() public {
        vm.warp(MONDAY + 14 days + 10 hours);
        vm.prank(alice);
        share.transfer(bob, 1);
    }

    function test_transferOnWeekendRejected() public {
        vm.warp(MONDAY + 12 days + 10 hours); // Saturday
        vm.prank(alice);
        vm.expectRevert(_rejection(1));
        share.transfer(bob, 1);
        assertFalse(share.canTransfer(alice, bob, 1));
    }

    function test_transferAfterHoursRejected() public {
        vm.warp(MONDAY + 14 days + 20 hours);
        vm.prank(alice);
        vm.expectRevert(_rejection(1));
        share.transfer(bob, 1);
    }

    function test_operationalFlowsIgnoreWindow() public {
        vm.warp(MONDAY + 12 days + 23 hours); // Saturday night
        _requestDeposit(bob, 10 * USDC);
        _closeAndSettle(NAV_ONE);
        vm.prank(bob);
        vault.deposit(10 * USDC, bob, bob); // mint
        vm.prank(alice);
        vault.requestRedeem(1, alice, alice); // burn
    }

    function test_disableWindow() public {
        vm.expectEmit(address(transferWindow));
        emit TransferWindowModule.TransferWindowSet(false, WEEKDAYS, OPEN, CLOSE);
        vm.prank(complianceOfficer);
        transferWindow.disableWindow();
        vm.warp(MONDAY + 12 days + 23 hours);
        vm.prank(alice);
        share.transfer(bob, 1);
    }

    function test_setWindow_validation() public {
        vm.startPrank(complianceOfficer);
        vm.expectRevert(abi.encodeWithSelector(TransferWindowModule.InvalidWindow.selector, uint8(0), OPEN, CLOSE));
        transferWindow.setWindow(0, OPEN, CLOSE);
        vm.expectRevert(abi.encodeWithSelector(TransferWindowModule.InvalidWindow.selector, uint8(0x80), OPEN, CLOSE));
        transferWindow.setWindow(0x80, OPEN, CLOSE);
        vm.expectRevert(abi.encodeWithSelector(TransferWindowModule.InvalidWindow.selector, WEEKDAYS, CLOSE, OPEN));
        transferWindow.setWindow(WEEKDAYS, CLOSE, OPEN);
        vm.expectRevert(
            abi.encodeWithSelector(TransferWindowModule.InvalidWindow.selector, WEEKDAYS, OPEN, uint32(86_401))
        );
        transferWindow.setWindow(WEEKDAYS, OPEN, 86_401);
        transferWindow.setWindow(0x7f, 0, 86_400); // whole week, whole day
        vm.stopPrank();
        assertTrue(transferWindow.isOpenAt(MONDAY + 5 days + 23 hours));
    }

    function test_setWindow_restricted() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        transferWindow.setWindow(WEEKDAYS, OPEN, CLOSE);
    }
}
