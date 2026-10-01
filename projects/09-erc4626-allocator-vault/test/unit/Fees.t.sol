// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Vm} from "forge-std/Vm.sol";

import {IAllocatorVault} from "../../src/interfaces/IAllocatorVault.sol";
import {VaultFixture} from "../utils/VaultFixture.sol";

/// @notice Performance fee: charged as shares, only on the unlocked gain above the high-water mark, rounded down.
contract PerformanceFeeTest is VaultFixture {
    function _initialPerformanceFee() internal pure override returns (uint256) {
        return 0.2e18;
    }

    function setUp() public override {
        super.setUp();
        _deposit(alice, 1000 * unit);
        _allocate(liquid, 1000 * unit);
    }

    /// @dev Checks the fee minted by one `accrue()` against an independent bound computed from observables:
    ///      value(fee shares) <= 20 % * (price before fee - HWM before) * supply before.
    function _accrueAndCheckFeeBound() internal returns (uint256 feeValue) {
        uint256 supplyBefore = vault.totalSupply();
        uint256 hwmBefore = vault.highWaterMark();
        uint256 feeSharesBefore = vault.balanceOf(feeRecipient);
        vault.accrue();
        uint256 feeShares = vault.balanceOf(feeRecipient) - feeSharesBefore;
        uint256 ta = vault.totalAssets();
        uint256 priceBeforeFee = (ta + 1) * RAY / (supplyBefore + 1e6);
        uint256 gain = priceBeforeFee > hwmBefore ? (priceBeforeFee - hwmBefore) * supplyBefore / RAY : 0;
        feeValue = feeShares * (ta + 1) / (supplyBefore + feeShares + 1e6);
        assertLe(feeValue, gain * 2 / 10, "fee <= 20% of the gain above the mark");
        assertGe(vault.highWaterMark(), hwmBefore, "mark never decreases");
    }

    function test_performanceFee_isChargedOnUnlockedGainOnly() public {
        liquid.simulateYield(100 * unit);
        assertEq(_accrueAndCheckFeeBound(), 0, "locked profit is not fee-able yet");

        vm.warp(block.timestamp + 7 days);
        uint256 fee = _accrueAndCheckFeeBound();
        assertGe(fee, 20 * unit - 2, "the full 20% of the 100 gain, minus rounding");
        assertApproxEqAbs(vault.convertToAssets(vault.balanceOf(alice)), 1080 * unit, 2);
        assertEq(vault.highWaterMark(), vault.sharePrice(), "the mark moves to the post-fee price");
    }

    function test_performanceFee_accruesProgressivelyAsProfitUnlocks() public {
        liquid.simulateYield(70 * unit);
        vault.accrue();
        uint256 total;
        for (uint256 day = 1; day <= 7; ++day) {
            vm.warp(block.timestamp + 1 days);
            total += _accrueAndCheckFeeBound();
        }
        assertApproxEqAbs(total, 14 * unit, 20, "20% of 70, charged day by day (a few wei of rounding per accrual)");
    }

    function test_performanceFee_notChargedUntilPriceRegainsHighWaterMark() public {
        liquid.simulateYield(100 * unit);
        vault.accrue();
        vm.warp(block.timestamp + 7 days);
        _accrueAndCheckFeeBound();
        uint256 hwm = vault.highWaterMark();
        uint256 feeSharesBefore = vault.balanceOf(feeRecipient);

        // Move half into the lossy strategy, lose ~10 %, then regain half of the loss: still below the mark.
        _allocate(liquid, 500 * unit);
        _allocate(lossy, type(uint256).max);
        lossy.simulateLoss(108 * unit);
        vault.accrue();
        lossy.simulateYield(54 * unit);
        vault.accrue();
        vm.warp(block.timestamp + 7 days);
        _accrueAndCheckFeeBound();
        assertLt(vault.sharePrice(), hwm);
        assertEq(vault.highWaterMark(), hwm, "the mark never moves down");
        assertEq(vault.balanceOf(feeRecipient), feeSharesBefore, "no fee while below the mark");

        // Regain past the mark: the fee applies only to the part above it.
        lossy.simulateYield(154 * unit);
        vault.accrue();
        vm.warp(block.timestamp + 7 days);
        uint256 fee = _accrueAndCheckFeeBound();
        // 54 of the 154 only restores the mark; 100 is new gain above it.
        assertApproxEqAbs(fee, 20 * unit, 2);
    }

    function test_performanceFee_zeroWhenSupplyIsZero() public {
        _redeemAll(alice);
        asset.mint(address(vault), 50 * unit);
        vm.warp(block.timestamp + 30 days);
        vault.accrue();
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.balanceOf(feeRecipient), 0);
    }
}

/// @notice Management fee: per second, minted as shares, rounded down.
contract ManagementFeeTest is VaultFixture {
    function _initialManagementFee() internal pure override returns (uint256) {
        return 0.02e18;
    }

    function test_managementFee_accruesPerSecond() public {
        _deposit(alice, 1000 * unit);
        vm.warp(block.timestamp + 365 days);
        vault.accrue();
        uint256 fee = vault.convertToAssets(vault.balanceOf(feeRecipient));
        assertLe(fee, 20 * unit, "2% of 1000 over a year, never more");
        assertGe(fee, 20 * unit - 1);
        assertApproxEqAbs(vault.convertToAssets(vault.balanceOf(alice)), 980 * unit, 1);
    }

    function test_managementFee_isLinearInTime() public {
        _deposit(alice, 1000 * unit);
        vm.warp(block.timestamp + 365 days / 4);
        vault.accrue();
        uint256 quarter = vault.convertToAssets(vault.balanceOf(feeRecipient));
        assertApproxEqAbs(quarter, 5 * unit, 1);
    }

    function test_managementFee_roundsDownToZeroForDust() public {
        _deposit(alice, 1000);
        vm.warp(block.timestamp + 1);
        vault.accrue();
        assertEq(vault.balanceOf(feeRecipient), 0, "1000 wei * 2% * 1s / 1y rounds down to 0");
    }

    function test_managementFee_notChargedWhileVaultIsEmpty() public {
        vm.warp(block.timestamp + 365 days);
        _deposit(alice, 1000 * unit);
        assertEq(vault.balanceOf(feeRecipient), 0, "the empty year is not billed to the first depositor");
    }

    function test_managementFee_cappedAtTotalAssets() public {
        _deposit(alice, 1000 * unit);
        vm.warp(block.timestamp + 100 * 365 days); // 200% linear fee, capped at 100%
        vault.accrue();
        assertLe(vault.convertToAssets(vault.balanceOf(feeRecipient)), 1000 * unit);
    }
}

/// @notice Fee governance: decreases are immediate, increases are timelocked, the guardian can revoke.
contract FeeGovernanceTest is VaultFixture {
    function _initialPerformanceFee() internal pure override returns (uint256) {
        return 0.1e18;
    }

    function _initialManagementFee() internal pure override returns (uint256) {
        return 0.01e18;
    }

    function test_submitFees_decreaseIsImmediateAfterChargingOldRate() public {
        _deposit(alice, 1000 * unit);
        vm.warp(block.timestamp + 365 days);
        vm.expectEmit(address(vault));
        emit IAllocatorVault.SetFees(curator, 0.05e18, 0);
        vm.prank(curator);
        vault.submitFees(0.05e18, 0);
        assertEq(vault.performanceFee(), 0.05e18);
        assertEq(vault.managementFee(), 0);
        assertApproxEqAbs(vault.convertToAssets(vault.balanceOf(feeRecipient)), 10 * unit, 1, "old 1% was charged");
    }

    function test_submitFees_increaseIsTimelocked() public {
        uint256 validAt = block.timestamp + 3 days;
        vm.expectEmit(address(vault));
        emit IAllocatorVault.SubmitFees(curator, 0.2e18, 0.01e18, validAt);
        vm.prank(curator);
        vault.submitFees(0.2e18, 0.01e18);
        assertEq(vault.performanceFee(), 0.1e18);
        IAllocatorVault.PendingFees memory p = vault.pendingFees();
        assertEq(p.performanceFee, 0.2e18);
        assertEq(p.validAt, validAt);

        vm.expectRevert(abi.encodeWithSelector(IAllocatorVault.TimelockNotElapsed.selector, validAt, block.timestamp));
        vault.acceptFees();

        vm.warp(validAt);
        vm.prank(bob);
        vault.acceptFees();
        assertEq(vault.performanceFee(), 0.2e18);
        assertEq(vault.pendingFees().validAt, 0);
    }

    function test_submitFees_decreaseCancelsPendingIncrease() public {
        vm.prank(curator);
        vault.submitFees(0.2e18, 0.01e18);
        vm.expectEmit(address(vault));
        emit IAllocatorVault.RevokePendingFees(curator); // monitors see the pending increase go away
        vm.expectEmit(address(vault));
        emit IAllocatorVault.SetFees(curator, 0, 0);
        vm.prank(curator);
        vault.submitFees(0, 0);
        assertEq(vault.pendingFees().validAt, 0);
    }

    function test_submitFees_decreaseWithNothingPendingEmitsNoRevoke() public {
        vm.recordLogs();
        vm.prank(curator);
        vault.submitFees(0.05e18, 0.01e18);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != IAllocatorVault.RevokePendingFees.selector);
        }
        assertEq(vault.performanceFee(), 0.05e18);
    }

    function test_submitFees_revertsWhenAlreadyPending() public {
        vm.prank(curator);
        vault.submitFees(0.2e18, 0.01e18);
        uint256 validAt = block.timestamp + 3 days;
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(IAllocatorVault.AlreadyPending.selector, validAt));
        vault.submitFees(0.3e18, 0.01e18);
    }

    function test_submitFees_revertsWhenUnchanged() public {
        vm.prank(curator);
        vm.expectRevert(IAllocatorVault.FeesAlreadySet.selector);
        vault.submitFees(0.1e18, 0.01e18);
    }

    function test_submitFees_revertsAboveMaximums() public {
        vm.startPrank(curator);
        vm.expectRevert(abi.encodeWithSelector(IAllocatorVault.FeeTooHigh.selector, 0.5e18 + 1, 0.5e18));
        vault.submitFees(0.5e18 + 1, 0);
        vm.expectRevert(abi.encodeWithSelector(IAllocatorVault.FeeTooHigh.selector, 0.05e18 + 1, 0.05e18));
        vault.submitFees(0, 0.05e18 + 1);
        vm.stopPrank();
    }

    function test_guardian_revokesPendingFees() public {
        vm.prank(curator);
        vault.submitFees(0.2e18, 0.01e18);
        vm.expectEmit(address(vault));
        emit IAllocatorVault.RevokePendingFees(guardian);
        vm.prank(guardian);
        vault.revokePendingFees();
        vm.warp(block.timestamp + 3 days);
        vm.expectRevert(IAllocatorVault.NoPendingValue.selector);
        vault.acceptFees();
    }

    function test_guardian_revokePendingFeesRevertsWithoutPending() public {
        vm.prank(guardian);
        vm.expectRevert(IAllocatorVault.NoPendingValue.selector);
        vault.revokePendingFees();
    }

    function test_setFeeRecipient_chargesOldRecipientFirst() public {
        _deposit(alice, 1000 * unit);
        vm.warp(block.timestamp + 365 days);
        vm.expectEmit(address(vault));
        emit IAllocatorVault.SetFeeRecipient(curator, carol);
        vm.prank(curator);
        vault.setFeeRecipient(carol);
        assertGt(vault.balanceOf(feeRecipient), 0);
        assertEq(vault.balanceOf(carol), 0);
        assertEq(vault.feeRecipient(), carol);
    }

    function test_setFeeRecipient_revertsWhenUnchanged() public {
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(IAllocatorVault.FeeRecipientAlreadySet.selector, feeRecipient));
        vault.setFeeRecipient(feeRecipient);
    }

    function test_setFeeRecipient_revertsToZeroWhileFeesAreOn() public {
        vm.prank(curator);
        vm.expectRevert(IAllocatorVault.ZeroFeeRecipient.selector);
        vault.setFeeRecipient(address(0));
    }

    function test_feeRecipient_canBeClearedWhenFeesAreZeroButNotReused() public {
        vm.startPrank(curator);
        vault.submitFees(0, 0);
        vault.submitFees(0.1e18, 0); // increase: pending
        vault.setFeeRecipient(address(0));
        vm.expectRevert(IAllocatorVault.ZeroFeeRecipient.selector);
        vault.submitFees(0.2e18, 0);
        vm.stopPrank();

        vm.warp(block.timestamp + 3 days);
        vm.expectRevert(IAllocatorVault.ZeroFeeRecipient.selector);
        vault.acceptFees();
    }
}
