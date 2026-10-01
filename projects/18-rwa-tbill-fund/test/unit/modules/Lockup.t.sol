// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IAccessManaged} from "@openzeppelin-contracts/access/manager/IAccessManaged.sol";
import {ComplianceEngine} from "../../../src/compliance/ComplianceEngine.sol";
import {LockupModule} from "../../../src/compliance/modules/LockupModule.sol";
import {TransferContext, TransferKind} from "../../../src/interfaces/ICompliance.sol";
import {FundFixture} from "../../utils/FundFixture.sol";

contract LockupTest is FundFixture {
    function _rejection(address from, address to, uint256 amount, TransferKind kind)
        internal
        view
        returns (bytes memory)
    {
        return abi.encodeWithSelector(
            ComplianceEngine.ComplianceModuleRejected.selector, address(lockup), kind, from, to, amount
        );
    }

    function test_metadata() public view {
        assertEq(lockup.name(), "Lockup");
        assertTrue(lockup.isStateful());
        assertEq(lockup.lockupPeriod(), LOCKUP);
    }

    function test_constructor_revertsAboveMax() public {
        vm.expectRevert(abi.encodeWithSelector(LockupModule.LockupTooLong.selector, uint64(366 days), uint64(365 days)));
        new LockupModule(address(manager), address(engine), 366 days);
    }

    function test_setLockupPeriod_emitsAndBounds() public {
        vm.startPrank(complianceOfficer);
        vm.expectEmit(address(lockup));
        emit LockupModule.LockupPeriodSet(7 days);
        lockup.setLockupPeriod(7 days);
        vm.expectRevert(abi.encodeWithSelector(LockupModule.LockupTooLong.selector, uint64(366 days), uint64(365 days)));
        lockup.setLockupPeriod(366 days);
        vm.stopPrank();
    }

    function test_setLockupPeriod_restricted() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        lockup.setLockupPeriod(0);
    }

    function test_mintLocksUntilPeriodEnds() public {
        uint256 shares = _subscribe(alice, 100 * USDC);
        assertEq(lockup.lockedBalanceOf(alice), shares);
        vm.prank(alice);
        vm.expectRevert(_rejection(alice, bob, 1, TransferKind.Transfer));
        share.transfer(bob, 1);
        assertFalse(share.canTransfer(alice, bob, 1));

        vm.warp(block.timestamp + LOCKUP);
        assertEq(lockup.lockedBalanceOf(alice), 0);
        vm.prank(alice);
        share.transfer(bob, 1);
    }

    function test_lockBlocksRedemptionRequest() public {
        _subscribe(alice, 100 * USDC);
        vm.prank(alice);
        vm.expectRevert(_rejection(alice, address(0), 1, TransferKind.Burn));
        vault.requestRedeem(1, alice, alice);
    }

    function test_unlockedPortionStaysTransferable() public {
        _seed(alice, 100 * USDC); // unlocked
        _subscribe(alice, 50 * USDC); // 50 locked
        assertEq(lockup.lockedBalanceOf(alice), 50 * USDC);
        vm.startPrank(alice);
        share.transfer(bob, 100 * USDC);
        vm.expectRevert(_rejection(alice, bob, 1, TransferKind.Transfer));
        share.transfer(bob, 1);
        vm.stopPrank();
    }

    function test_secondMintRestartsWholeLock() public {
        _subscribe(alice, 100 * USDC);
        (, uint64 firstUntil) = lockup.locks(alice);
        vm.warp(block.timestamp + 12 hours);
        _subscribe(alice, 10 * USDC);
        (uint192 amount, uint64 until) = lockup.locks(alice);
        assertEq(amount, 110 * USDC);
        assertGt(until, firstUntil);
    }

    function test_noLockWhenPeriodZero() public {
        vm.prank(complianceOfficer);
        lockup.setLockupPeriod(0);
        _subscribe(alice, 100 * USDC);
        assertEq(lockup.lockedBalanceOf(alice), 0);
        vm.prank(alice);
        share.transfer(bob, 100 * USDC);
    }

    function test_forcedTransferShrinksLock() public {
        _subscribe(alice, 100 * USDC);
        bytes32 order = keccak256("order");
        _issueOrder(order, alice, bob, 70 * USDC);
        vm.prank(transferAgent);
        share.forcedTransfer(alice, bob, 70 * USDC, order);
        assertEq(lockup.lockedBalanceOf(alice), 30 * USDC);
        assertEq(lockup.lockedBalanceOf(bob), 0, "forced credits are not locked");
    }

    function test_forcedTransferOfUnlockedPartKeepsLock() public {
        _seed(alice, 100 * USDC);
        _subscribe(alice, 50 * USDC);
        bytes32 order = keccak256("order");
        _issueOrder(order, alice, bob, 60 * USDC);
        vm.prank(transferAgent);
        share.forcedTransfer(alice, bob, 60 * USDC, order);
        assertEq(lockup.lockedBalanceOf(alice), 50 * USDC);
    }

    // ------------------------------------------------ direct hook tests on a module bound to this contract

    function _ctx(TransferKind kind, address from, address to, uint256 amount, uint256 fromBalance)
        internal
        pure
        returns (TransferContext memory ctx)
    {
        ctx.kind = kind;
        ctx.from = from;
        ctx.to = to;
        ctx.amount = amount;
        ctx.fromBalance = fromBalance;
    }

    function test_hooks_moveLockKeepsLaterUnlock() public {
        LockupModule m = new LockupModule(address(manager), address(this), 10 days);
        m.onTransfer(_ctx(TransferKind.Mint, address(0), alice, 100, 0));
        vm.warp(block.timestamp + 1 days);
        m.onTransfer(_ctx(TransferKind.Mint, address(0), bob, 5, 0)); // bob's lock ends later
        (, uint64 bobUntil) = m.locks(bob);

        m.onTransfer(_ctx(TransferKind.Recovery, alice, bob, 100, 100));
        (uint192 amount, uint64 until) = m.locks(bob);
        assertEq(amount, 105);
        assertEq(until, bobUntil);
        assertEq(m.lockedBalanceOf(alice), 0);
    }

    function test_hooks_moveLockTakesSenderUnlockWhenLater() public {
        LockupModule m = new LockupModule(address(manager), address(this), 10 days);
        m.onTransfer(_ctx(TransferKind.Mint, address(0), bob, 5, 0));
        vm.warp(block.timestamp + 1 days);
        m.onTransfer(_ctx(TransferKind.Mint, address(0), alice, 100, 0));
        (, uint64 aliceUntil) = m.locks(alice);
        m.onTransfer(_ctx(TransferKind.Recovery, alice, bob, 100, 100));
        (uint192 amount, uint64 until) = m.locks(bob);
        assertEq(amount, 105);
        assertEq(until, aliceUntil);
    }

    function test_hooks_moveWithoutActiveLockIsNoop() public {
        LockupModule m = new LockupModule(address(manager), address(this), 10 days);
        m.onTransfer(_ctx(TransferKind.Recovery, alice, bob, 100, 100));
        assertEq(m.lockedBalanceOf(bob), 0);
    }

    function test_hooks_zeroMintDoesNotLock() public {
        LockupModule m = new LockupModule(address(manager), address(this), 10 days);
        m.onTransfer(_ctx(TransferKind.Mint, address(0), alice, 0, 0));
        (, uint64 until) = m.locks(alice);
        assertEq(until, 0);
    }

    function test_hooks_transferAndBurnDoNotTouchLocks() public {
        LockupModule m = new LockupModule(address(manager), address(this), 10 days);
        m.onTransfer(_ctx(TransferKind.Mint, address(0), alice, 100, 0));
        m.onTransfer(_ctx(TransferKind.Transfer, alice, bob, 0, 100));
        m.onTransfer(_ctx(TransferKind.Burn, alice, address(0), 0, 100));
        assertEq(m.lockedBalanceOf(alice), 100);
    }

    function test_check_ignoresOtherKindsAndBalanceShortfalls() public {
        LockupModule m = new LockupModule(address(manager), address(this), 10 days);
        assertTrue(m.check(_ctx(TransferKind.Transfer, alice, bob, 500, 100)), "no lock: silent on balance");
        m.onTransfer(_ctx(TransferKind.Mint, address(0), alice, 100, 0));
        assertFalse(m.check(_ctx(TransferKind.Transfer, alice, bob, 1, 100)));
        assertFalse(m.check(_ctx(TransferKind.Burn, alice, address(0), 1, 50)), "locked above balance");
        assertTrue(m.check(_ctx(TransferKind.Forced, alice, bob, 100, 100)));
        assertTrue(m.check(_ctx(TransferKind.Recovery, alice, bob, 100, 100)));
        assertTrue(m.check(_ctx(TransferKind.Mint, address(0), alice, 100, 0)));
    }
}
