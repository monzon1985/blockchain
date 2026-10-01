// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Vm} from "forge-std/Vm.sol";

import {IAllocatorVault} from "../../src/interfaces/IAllocatorVault.sol";
import {MockLiquidStrategy} from "../mocks/MockStrategies.sol";
import {VaultFixture} from "../utils/VaultFixture.sol";

contract AllocationTest is VaultFixture {
    function setUp() public override {
        super.setUp();
        _deposit(alice, 1000 * unit);
    }

    function _one(IERC4626 strategy, uint256 target) internal pure returns (IAllocatorVault.Allocation[] memory a) {
        a = new IAllocatorVault.Allocation[](1);
        a[0] = IAllocatorVault.Allocation({strategy: strategy, assets: target});
    }

    function test_reallocate_suppliesIdleToStrategy() public {
        uint256 amount = 400 * unit;
        vm.expectEmit(address(vault));
        emit IAllocatorVault.Allocate(allocator, liquid, amount, amount);
        _allocate(liquid, amount);
        assertEq(_strategyValue(liquid), amount);
        assertEq(asset.balanceOf(address(vault)), 600 * unit);
        assertEq(vault.totalAssets(), 1000 * unit, "moving assets does not change totalAssets");
    }

    function test_reallocate_maxSuppliesAllIdle() public {
        _allocate(liquid, type(uint256).max);
        assertEq(_strategyValue(liquid), 1000 * unit);
        assertEq(asset.balanceOf(address(vault)), 0);
    }

    function test_reallocate_maxWithNoIdleIsNoop() public {
        _allocate(liquid, type(uint256).max);
        _allocate(lossy, type(uint256).max);
        assertEq(_strategyValue(lossy), 0);
    }

    function test_reallocate_partialWithdrawToIdle() public {
        _allocate(liquid, 800 * unit);
        vm.expectEmit(address(vault));
        emit IAllocatorVault.Deallocate(allocator, liquid, 300 * unit, 300 * unit);
        _allocate(liquid, 500 * unit);
        assertEq(_strategyValue(liquid), 500 * unit);
        assertEq(asset.balanceOf(address(vault)), 500 * unit);
    }

    function test_reallocate_zeroTargetRedeemsAllShares() public {
        _allocate(liquid, 800 * unit);
        liquid.simulateYield(7); // leaves a non-round position that a `withdraw` could leave dust behind for
        uint256 shares = liquid.balanceOf(address(vault));
        uint256 value = _strategyValue(liquid);
        vm.expectEmit(address(vault));
        emit IAllocatorVault.Deallocate(allocator, liquid, value, shares);
        _allocate(liquid, 0);
        assertEq(liquid.balanceOf(address(vault)), 0);
    }

    function test_reallocate_equalTargetIsNoop() public {
        _allocate(liquid, 500 * unit);
        vm.recordLogs();
        _allocate(liquid, 500 * unit);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != IAllocatorVault.Allocate.selector, "no Allocate");
            assertTrue(logs[i].topics[0] != IAllocatorVault.Deallocate.selector, "no Deallocate");
        }
        assertEq(_strategyValue(liquid), 500 * unit);
    }

    function test_reallocate_movesBetweenStrategiesInOneCall() public {
        _allocate(liquid, 1000 * unit);
        IAllocatorVault.Allocation[] memory a = new IAllocatorVault.Allocation[](2);
        a[0] = IAllocatorVault.Allocation({strategy: liquid, assets: 250 * unit});
        a[1] = IAllocatorVault.Allocation({strategy: illiquid, assets: type(uint256).max});
        vm.prank(allocator);
        vault.reallocate(a);
        assertEq(_strategyValue(liquid), 250 * unit);
        assertEq(_strategyValue(illiquid), 750 * unit);
        assertEq(asset.balanceOf(address(vault)), 0);
    }

    function test_reallocate_revertsAboveCap() public {
        vm.prank(curator);
        vault.submitCap(liquid, 100 * unit);
        IAllocatorVault.Allocation[] memory a = _one(liquid, 101 * unit);
        vm.prank(allocator);
        vm.expectRevert(abi.encodeWithSelector(IAllocatorVault.CapExceeded.selector, liquid, 101 * unit, 100 * unit));
        vault.reallocate(a);
    }

    function test_reallocate_capCountsExistingPosition() public {
        vm.prank(curator);
        vault.submitCap(liquid, 500 * unit);
        _allocate(liquid, 400 * unit);
        IAllocatorVault.Allocation[] memory a = _one(liquid, type(uint256).max);
        vm.prank(allocator);
        vm.expectRevert(abi.encodeWithSelector(IAllocatorVault.CapExceeded.selector, liquid, 1000 * unit, 500 * unit));
        vault.reallocate(a);
    }

    function test_reallocate_revertsWhenIdleIsShort() public {
        IAllocatorVault.Allocation[] memory a = _one(liquid, 1001 * unit);
        vm.prank(allocator);
        vm.expectRevert(abi.encodeWithSelector(IAllocatorVault.InsufficientIdle.selector, 1001 * unit, 1000 * unit));
        vault.reallocate(a);
    }

    function test_reallocate_revertsForUnknownStrategy() public {
        MockLiquidStrategy stranger = new MockLiquidStrategy(IERC20(address(asset)));
        IAllocatorVault.Allocation[] memory a = _one(stranger, 1);
        vm.prank(allocator);
        vm.expectRevert(abi.encodeWithSelector(IAllocatorVault.StrategyNotEnabled.selector, stranger));
        vault.reallocate(a);
    }

    function test_reallocate_revertsForNonAllocator() public {
        IAllocatorVault.Allocation[] memory a = _one(liquid, 1);
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, curator));
        vault.reallocate(a);
    }

    function test_reallocate_zeroCapStrategyCanOnlyBeDrained() public {
        _allocate(liquid, 500 * unit);
        vm.prank(guardian);
        vault.zeroCap(liquid);
        _allocate(liquid, 200 * unit); // withdrawing is still allowed
        IAllocatorVault.Allocation[] memory a = _one(liquid, 201 * unit);
        vm.prank(allocator);
        vm.expectRevert(abi.encodeWithSelector(IAllocatorVault.CapExceeded.selector, liquid, 201 * unit, 0));
        vault.reallocate(a);
    }

    function test_setWithdrawQueue_reorders() public {
        IERC4626[] memory q = new IERC4626[](3);
        q[0] = illiquid;
        q[1] = liquid;
        q[2] = lossy;
        vm.expectEmit(address(vault));
        emit IAllocatorVault.SetWithdrawQueue(allocator, q);
        vm.prank(allocator);
        vault.setWithdrawQueue(q);
        assertEq(address(vault.withdrawQueue(0)), address(illiquid));
        assertEq(address(vault.withdrawQueue(1)), address(liquid));
        assertEq(address(vault.withdrawQueue(2)), address(lossy));

        // Withdrawals now drain `illiquid` first.
        _allocate(liquid, 500 * unit);
        _allocate(illiquid, 500 * unit);
        vm.prank(alice);
        vault.withdraw(300 * unit, alice, alice);
        assertEq(_strategyValue(illiquid), 200 * unit);
        assertEq(_strategyValue(liquid), 500 * unit);
    }

    function test_setWithdrawQueue_revertsOnLengthMismatch() public {
        IERC4626[] memory q = new IERC4626[](2);
        q[0] = liquid;
        q[1] = lossy;
        vm.prank(allocator);
        vm.expectRevert(abi.encodeWithSelector(IAllocatorVault.WithdrawQueueLengthMismatch.selector, 3, 2));
        vault.setWithdrawQueue(q);
    }

    function test_setWithdrawQueue_revertsOnDuplicate() public {
        IERC4626[] memory q = new IERC4626[](3);
        q[0] = liquid;
        q[1] = lossy;
        q[2] = liquid;
        vm.prank(allocator);
        vm.expectRevert(abi.encodeWithSelector(IAllocatorVault.DuplicateStrategy.selector, liquid));
        vault.setWithdrawQueue(q);
    }

    function test_setWithdrawQueue_revertsOnUnknownStrategy() public {
        MockLiquidStrategy stranger = new MockLiquidStrategy(IERC20(address(asset)));
        IERC4626[] memory q = new IERC4626[](3);
        q[0] = liquid;
        q[1] = lossy;
        q[2] = stranger;
        vm.prank(allocator);
        vm.expectRevert(abi.encodeWithSelector(IAllocatorVault.StrategyNotEnabled.selector, stranger));
        vault.setWithdrawQueue(q);
    }

    function test_setWithdrawQueue_revertsForNonAllocator() public {
        IERC4626[] memory q = new IERC4626[](3);
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, guardian));
        vault.setWithdrawQueue(q);
    }

    function test_views_strategyAssetsAndLiquidity() public {
        _allocate(liquid, 300 * unit);
        _allocate(illiquid, 300 * unit);
        illiquid.lend(100 * unit);
        assertEq(vault.strategyAssets(liquid), 300 * unit);
        assertEq(vault.strategyAssets(illiquid), 300 * unit);
        assertEq(vault.strategyAssets(lossy), 0);
        assertEq(vault.availableLiquidity(), 400 * unit + 300 * unit + 200 * unit);
    }
}
