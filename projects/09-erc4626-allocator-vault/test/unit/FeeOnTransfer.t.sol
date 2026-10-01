// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

import {AllocatorVault} from "../../src/AllocatorVault.sol";
import {VaultRoles} from "../../src/access/VaultRoles.sol";
import {IAllocatorVault} from "../../src/interfaces/IAllocatorVault.sol";
import {MockFeeOnTransferERC20} from "../mocks/MockERC20.sol";
import {MockLiquidStrategy} from "../mocks/MockStrategies.sol";
import {NaiveAllocatorVault} from "../naive/NaiveAllocatorVault.sol";

/// @notice Fee-on-transfer asset variant. The vault refuses to mint shares for assets it did not receive and refuses
///         to pay a withdrawer out of other depositors' idle when a strategy under-delivers.
contract FeeOnTransferTest is Test {
    MockFeeOnTransferERC20 internal token;
    AccessManager internal manager;
    AllocatorVault internal vault;
    MockLiquidStrategy internal strategy;

    address internal curator = makeAddr("curator");
    address internal allocator = makeAddr("allocator");
    address internal guardian = makeAddr("guardian");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        token = new MockFeeOnTransferERC20("Fee Token", "FEE", 18, 0);
        manager = new AccessManager(address(this));
        vault = new AllocatorVault(
            AllocatorVault.InitParams({
                asset: IERC20(address(token)),
                name: "v",
                symbol: "v",
                authority: address(manager),
                feeRecipient: address(0),
                performanceFee: 0,
                managementFee: 0,
                maxSharePriceGrowthPerYear: 0.25e18
            })
        );
        VaultRoles.configure(manager, address(vault));
        manager.grantRole(VaultRoles.CURATOR, curator, 0);
        manager.grantRole(VaultRoles.ALLOCATOR, allocator, 0);
        manager.grantRole(VaultRoles.GUARDIAN, guardian, 0);
        strategy = new MockLiquidStrategy(IERC20(address(token)));
        vm.prank(curator);
        vault.submitCap(strategy, type(uint128).max);
        vm.warp(block.timestamp + 3 days);
        vault.acceptCap(strategy);
    }

    function _approveAndDeposit(IERC4626 target, address user, uint256 assets) internal returns (uint256) {
        token.mint(user, assets);
        vm.startPrank(user);
        token.approve(address(target), assets);
        uint256 shares = target.deposit(assets, user);
        vm.stopPrank();
        return shares;
    }

    function test_feeOnTransfer_depositReverts() public {
        token.setFeeBps(100); // 1 %
        token.mint(alice, 100e18);
        vm.startPrank(alice);
        token.approve(address(vault), 100e18);
        vm.expectRevert(abi.encodeWithSelector(IAllocatorVault.AssetTransferMismatch.selector, 100e18, 99e18));
        vault.deposit(100e18, alice);
        vm.stopPrank();
    }

    function test_feeOnTransfer_naiveVaultChargesEarlierDepositorsForLaterFees() public {
        NaiveAllocatorVault naive = new NaiveAllocatorVault(IERC20(address(token)), false);
        _approveAndDeposit(naive, alice, 100e18); // before the fee switch: exact
        token.setFeeBps(100);
        uint256 aliceBefore = naive.convertToAssets(naive.balanceOf(alice));
        _approveAndDeposit(naive, bob, 100e18); // naive credits 100, receives 99
        uint256 aliceAfter = naive.convertToAssets(naive.balanceOf(alice));
        emit log_named_uint("naive: alice's value lost to bob's transfer fee (wei)", aliceBefore - aliceAfter);
        assertLt(aliceAfter, aliceBefore, "alice pays part of bob's fee");

        // Same sequence against the hardened vault: bob's deposit reverts, alice is untouched.
        token.setFeeBps(0);
        _approveAndDeposit(vault, alice, 100e18);
        token.setFeeBps(100);
        uint256 hardenedBefore = vault.convertToAssets(vault.balanceOf(alice));
        token.mint(bob, 100e18);
        vm.startPrank(bob);
        token.approve(address(vault), 100e18);
        vm.expectRevert(abi.encodeWithSelector(IAllocatorVault.AssetTransferMismatch.selector, 100e18, 99e18));
        vault.deposit(100e18, bob);
        vm.stopPrank();
        assertEq(vault.convertToAssets(vault.balanceOf(alice)), hardenedBefore);
    }

    /// @dev USDT-style: the fee switch flips after assets were allocated. A withdrawal that needs strategy liquidity
    ///      must not be topped up from other depositors' idle assets; the curator's removal realizes the fee as a loss
    ///      for everyone, after which withdrawals proceed at the same price for all.
    function test_feeOnTransfer_switchedOnLaterIsContained() public {
        _approveAndDeposit(vault, alice, 1000e18);
        _approveAndDeposit(vault, bob, 1000e18);
        IAllocatorVault.Allocation[] memory a = new IAllocatorVault.Allocation[](1);
        a[0] = IAllocatorVault.Allocation({strategy: strategy, assets: 1500e18});
        vm.prank(allocator);
        vault.reallocate(a);

        token.setFeeBps(100);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAllocatorVault.StrategyUnderDelivered.selector, strategy, 500e18, 495e18)
        );
        vault.withdraw(1000e18, alice, alice);

        vm.prank(guardian);
        vault.zeroCap(strategy);
        vm.expectEmit(address(vault));
        emit IAllocatorVault.StrategyRemoved(curator, strategy, 1485e18, 0);
        vm.prank(curator);
        vault.removeStrategy(strategy);
        assertEq(vault.totalAssets(), 1985e18, "the 15 transfer fee is realized as a loss");

        uint256 aliceShares = vault.balanceOf(alice);
        uint256 bobShares = vault.balanceOf(bob);
        vm.prank(alice);
        uint256 aliceAssets = vault.redeem(aliceShares, alice, alice);
        vm.prank(bob);
        uint256 bobAssets = vault.redeem(bobShares, bob, bob);
        assertApproxEqAbs(aliceAssets, bobAssets, 1, "same price for the first and the last to leave");
    }

    /// @dev The allocator's full redemption is held to the strategy's own `redeem` return value.
    function test_feeOnTransfer_allocatorFullRedeemRevertsOnShortDelivery() public {
        _approveAndDeposit(vault, alice, 1000e18);
        IAllocatorVault.Allocation[] memory a = new IAllocatorVault.Allocation[](1);
        a[0] = IAllocatorVault.Allocation({strategy: strategy, assets: 600e18});
        vm.prank(allocator);
        vault.reallocate(a);

        token.setFeeBps(100);
        a[0] = IAllocatorVault.Allocation({strategy: strategy, assets: 0});
        vm.prank(allocator);
        vm.expectRevert(
            abi.encodeWithSelector(IAllocatorVault.StrategyUnderDelivered.selector, strategy, 600e18, 594e18)
        );
        vault.reallocate(a);
    }
}
