// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Vm} from "forge-std/Vm.sol";

import {IAllocatorVault} from "../../src/interfaces/IAllocatorVault.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockLiquidStrategy} from "../mocks/MockStrategies.sol";
import {VaultFixture} from "../utils/VaultFixture.sol";

/// @notice Caps, strategy additions, the 3-day timelock, the guardian's powers and role enforcement.
contract GovernanceTest is VaultFixture {
    MockLiquidStrategy internal fresh;

    function setUp() public override {
        super.setUp();
        fresh = new MockLiquidStrategy(IERC20(address(asset)));
    }

    /*//////////////////////////////////////////////////////////////
                          ADDING STRATEGIES
    //////////////////////////////////////////////////////////////*/

    function test_submitCap_newStrategyWaitsOutTimelock() public {
        uint256 validAt = block.timestamp + 3 days;
        vm.expectEmit(address(vault));
        emit IAllocatorVault.SubmitCap(curator, fresh, 100 * unit, validAt);
        vm.prank(curator);
        vault.submitCap(fresh, 100 * unit);

        IAllocatorVault.PendingValue memory p = vault.pendingCap(fresh);
        assertEq(p.value, 100 * unit);
        assertEq(p.validAt, validAt);
        assertFalse(vault.config(fresh).enabled);

        vm.warp(validAt - 1);
        vm.expectRevert(abi.encodeWithSelector(IAllocatorVault.TimelockNotElapsed.selector, validAt, validAt - 1));
        vault.acceptCap(fresh);

        vm.warp(validAt);
        vm.expectEmit(address(vault));
        emit IAllocatorVault.StrategyAdded(fresh);
        vm.expectEmit(address(vault));
        emit IAllocatorVault.SetCap(bob, fresh, 100 * unit);
        vm.prank(bob); // permissionless once the timelock has elapsed
        vault.acceptCap(fresh);

        assertTrue(vault.config(fresh).enabled);
        assertEq(vault.config(fresh).cap, 100 * unit);
        assertEq(vault.withdrawQueueLength(), 4);
        assertEq(address(vault.withdrawQueue(3)), address(fresh));
        assertEq(vault.pendingCap(fresh).validAt, 0);
    }

    function test_submitCap_increaseWaitsOutTimelock() public {
        vm.prank(curator);
        vault.submitCap(liquid, _cap() + 1);
        assertEq(vault.config(liquid).cap, _cap(), "not effective yet");
        vm.warp(block.timestamp + 3 days);
        vault.acceptCap(liquid);
        assertEq(vault.config(liquid).cap, _cap() + 1);
        assertEq(vault.withdrawQueueLength(), 3, "an existing strategy is not queued twice");
    }

    function test_submitCap_decreaseIsImmediateAndCancelsPendingIncrease() public {
        vm.prank(curator);
        vault.submitCap(liquid, _cap() + 1);
        vm.expectEmit(address(vault));
        emit IAllocatorVault.RevokePendingCap(curator, liquid); // monitors see the pending increase go away
        vm.expectEmit(address(vault));
        emit IAllocatorVault.SetCap(curator, liquid, 5 * unit);
        vm.prank(curator);
        vault.submitCap(liquid, 5 * unit);
        assertEq(vault.config(liquid).cap, 5 * unit);
        assertEq(vault.pendingCap(liquid).validAt, 0);
    }

    function test_submitCap_revertsWhenUnchanged() public {
        uint256 cap = _cap();
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(IAllocatorVault.CapAlreadySet.selector, liquid, cap));
        vault.submitCap(liquid, cap);
    }

    function test_submitCap_revertsForZeroCapOnNewStrategy() public {
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(IAllocatorVault.CapAlreadySet.selector, fresh, 0));
        vault.submitCap(fresh, 0);
    }

    function test_submitCap_revertsWhenAlreadyPending() public {
        vm.prank(curator);
        vault.submitCap(fresh, 1);
        uint256 validAt = block.timestamp + 3 days;
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(IAllocatorVault.AlreadyPending.selector, validAt));
        vault.submitCap(fresh, 2);
    }

    function test_submitCap_revertsForEoa() public {
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(IAllocatorVault.InvalidStrategy.selector, bob));
        vault.submitCap(IERC4626(bob), 1);
    }

    function test_submitCap_revertsForVaultItself() public {
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(IAllocatorVault.InvalidStrategy.selector, address(vault)));
        vault.submitCap(IERC4626(address(vault)), 1);
    }

    function test_submitCap_revertsForOtherAsset() public {
        MockERC20 other = new MockERC20("Other", "OTH", 18);
        MockLiquidStrategy wrong = new MockLiquidStrategy(IERC20(address(other)));
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(IAllocatorVault.InvalidStrategy.selector, address(wrong)));
        vault.submitCap(wrong, 1);
    }

    function test_submitCap_revertsAboveUint184() public {
        uint256 huge = uint256(type(uint184).max) + 1;
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 184, huge));
        vault.submitCap(fresh, huge);
    }

    function test_submitCap_revertsWhileRemovalPending() public {
        vm.prank(guardian);
        vault.zeroCap(liquid);
        vm.prank(curator);
        vault.submitStrategyRemoval(liquid);
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(IAllocatorVault.RemovalPending.selector, liquid));
        vault.submitCap(liquid, 1);
    }

    function test_acceptCap_revertsWithoutPending() public {
        vm.expectRevert(IAllocatorVault.NoPendingValue.selector);
        vault.acceptCap(fresh);
    }

    function test_acceptCap_revertsWhenQueueIsFull() public {
        for (uint256 i = 3; i < vault.MAX_STRATEGIES(); ++i) {
            _listStrategy(new MockLiquidStrategy(IERC20(address(asset))), 1);
        }
        assertEq(vault.withdrawQueueLength(), 20);
        vm.prank(curator);
        vault.submitCap(fresh, 1);
        vm.warp(block.timestamp + 3 days);
        vm.expectRevert(abi.encodeWithSelector(IAllocatorVault.MaxStrategiesExceeded.selector, 20));
        vault.acceptCap(fresh);
    }

    /*//////////////////////////////////////////////////////////////
                               GUARDIAN
    //////////////////////////////////////////////////////////////*/

    function test_guardian_revokesPendingStrategyAddition() public {
        vm.prank(curator);
        vault.submitCap(fresh, 100 * unit);
        vm.expectEmit(address(vault));
        emit IAllocatorVault.RevokePendingCap(guardian, fresh);
        vm.prank(guardian);
        vault.revokePendingCap(fresh);
        vm.warp(block.timestamp + 3 days);
        vm.expectRevert(IAllocatorVault.NoPendingValue.selector);
        vault.acceptCap(fresh);
    }

    function test_guardian_revokePendingCapRevertsWithoutPending() public {
        vm.prank(guardian);
        vm.expectRevert(IAllocatorVault.NoPendingValue.selector);
        vault.revokePendingCap(liquid);
    }

    function test_guardian_zeroCapIsImmediateAndDropsPending() public {
        vm.prank(curator);
        vault.submitCap(liquid, _cap() * 2);
        vm.expectEmit(address(vault));
        emit IAllocatorVault.RevokePendingCap(guardian, liquid);
        vm.expectEmit(address(vault));
        emit IAllocatorVault.SetCap(guardian, liquid, 0);
        vm.prank(guardian);
        vault.zeroCap(liquid);
        assertEq(vault.config(liquid).cap, 0);
        assertTrue(vault.config(liquid).enabled, "a zero-cap strategy stays in the queue for withdrawals");
        assertEq(vault.pendingCap(liquid).validAt, 0);
    }

    function test_guardian_zeroCapIsIdempotent() public {
        vm.startPrank(guardian);
        vault.zeroCap(liquid);
        vm.recordLogs();
        vault.zeroCap(liquid);
        vm.stopPrank();
        assertEq(vault.config(liquid).cap, 0);
        // Nothing was pending, so no revoke event: only `SetCap`.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], IAllocatorVault.SetCap.selector);
    }

    function test_guardian_zeroCapRevertsForUnknownStrategy() public {
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(IAllocatorVault.StrategyNotEnabled.selector, fresh));
        vault.zeroCap(fresh);
    }

    /*//////////////////////////////////////////////////////////////
                           ROLE ENFORCEMENT
    //////////////////////////////////////////////////////////////*/

    function test_roles_curatorFunctionsRejectOthers() public {
        _expectUnauthorized(allocator, abi.encodeCall(IAllocatorVault.submitCap, (fresh, 1)));
        _expectUnauthorized(guardian, abi.encodeCall(IAllocatorVault.submitStrategyRemoval, (liquid)));
        _expectUnauthorized(alice, abi.encodeCall(IAllocatorVault.removeStrategy, (liquid)));
        _expectUnauthorized(allocator, abi.encodeCall(IAllocatorVault.submitFees, (0, 0)));
        _expectUnauthorized(guardian, abi.encodeCall(IAllocatorVault.setFeeRecipient, (bob)));
    }

    function test_roles_guardianFunctionsRejectOthers() public {
        _expectUnauthorized(curator, abi.encodeCall(IAllocatorVault.revokePendingCap, (liquid)));
        _expectUnauthorized(curator, abi.encodeCall(IAllocatorVault.revokePendingRemoval, (liquid)));
        _expectUnauthorized(allocator, abi.encodeCall(IAllocatorVault.revokePendingFees, ()));
        _expectUnauthorized(curator, abi.encodeCall(IAllocatorVault.zeroCap, (liquid)));
    }

    function test_roles_adminHoldsNoVaultPower() public {
        _expectUnauthorized(admin, abi.encodeCall(IAllocatorVault.submitCap, (fresh, 1)));
        _expectUnauthorized(admin, abi.encodeCall(IAllocatorVault.zeroCap, (liquid)));
        IAllocatorVault.Allocation[] memory a = new IAllocatorVault.Allocation[](0);
        _expectUnauthorized(admin, abi.encodeCall(IAllocatorVault.reallocate, (a)));
    }

    function _expectUnauthorized(address caller, bytes memory data) internal {
        vm.prank(caller);
        (bool ok, bytes memory ret) = address(vault).call(data);
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, caller));
    }
}
