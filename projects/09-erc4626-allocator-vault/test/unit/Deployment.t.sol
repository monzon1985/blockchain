// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AllocatorVault} from "../../src/AllocatorVault.sol";
import {IAllocatorVault} from "../../src/interfaces/IAllocatorVault.sol";
import {VaultFixture} from "../utils/VaultFixture.sol";

contract DeploymentTest is VaultFixture {
    function _params() internal view returns (AllocatorVault.InitParams memory) {
        return AllocatorVault.InitParams({
            asset: IERC20(address(asset)),
            name: "V",
            symbol: "V",
            authority: address(manager),
            feeRecipient: feeRecipient,
            performanceFee: 0.1e18,
            managementFee: 0.02e18,
            maxSharePriceGrowthPerYear: GROWTH_LIMIT
        });
    }

    function test_constructor_setsState() public {
        AllocatorVault v = new AllocatorVault(_params());
        assertEq(v.asset(), address(asset));
        assertEq(v.name(), "V");
        assertEq(v.symbol(), "V");
        assertEq(v.decimals(), 18 + 6);
        assertEq(v.authority(), address(manager));
        assertEq(v.feeRecipient(), feeRecipient);
        assertEq(v.performanceFee(), 0.1e18);
        assertEq(v.managementFee(), 0.02e18);
        assertEq(v.maxSharePriceGrowthPerYear(), GROWTH_LIMIT);
        assertEq(v.highWaterMark(), RAY / 1e6, "initial HWM is the empty-vault price");
        assertEq(v.sharePrice(), RAY / 1e6);
        assertEq(v.safeSharePrice(), RAY / 1e6);
        assertEq(v.totalAssets(), 0);
        assertEq(v.lastAccrual(), block.timestamp);
        assertEq(v.withdrawQueueLength(), 0);
        assertEq(v.maxDeposit(alice), type(uint256).max);
        assertEq(v.maxMint(alice), type(uint256).max);
    }

    function test_constructor_emitsConfigurationEvents() public {
        vm.expectEmit(true, true, true, true);
        emit IAllocatorVault.SetFeeRecipient(address(this), feeRecipient);
        vm.expectEmit(true, true, true, true);
        emit IAllocatorVault.SetFees(address(this), 0.1e18, 0.02e18);
        new AllocatorVault(_params());
    }

    function test_constructor_revertsOnZeroAsset() public {
        AllocatorVault.InitParams memory p = _params();
        p.asset = IERC20(address(0));
        vm.expectRevert(IAllocatorVault.ZeroAddress.selector);
        new AllocatorVault(p);
    }

    function test_constructor_revertsOnZeroAuthority() public {
        AllocatorVault.InitParams memory p = _params();
        p.authority = address(0);
        vm.expectRevert(IAllocatorVault.ZeroAddress.selector);
        new AllocatorVault(p);
    }

    function test_constructor_revertsOnZeroGrowthLimit() public {
        AllocatorVault.InitParams memory p = _params();
        p.maxSharePriceGrowthPerYear = 0;
        vm.expectRevert(abi.encodeWithSelector(IAllocatorVault.InvalidPriceGrowthLimit.selector, 0, 1e18));
        new AllocatorVault(p);
    }

    function test_constructor_revertsOnExcessiveGrowthLimit() public {
        AllocatorVault.InitParams memory p = _params();
        p.maxSharePriceGrowthPerYear = 1e18 + 1;
        vm.expectRevert(abi.encodeWithSelector(IAllocatorVault.InvalidPriceGrowthLimit.selector, 1e18 + 1, 1e18));
        new AllocatorVault(p);
    }

    function test_constructor_revertsOnExcessivePerformanceFee() public {
        AllocatorVault.InitParams memory p = _params();
        p.performanceFee = 0.5e18 + 1;
        vm.expectRevert(abi.encodeWithSelector(IAllocatorVault.FeeTooHigh.selector, 0.5e18 + 1, 0.5e18));
        new AllocatorVault(p);
    }

    function test_constructor_revertsOnExcessiveManagementFee() public {
        AllocatorVault.InitParams memory p = _params();
        p.managementFee = 0.05e18 + 1;
        vm.expectRevert(abi.encodeWithSelector(IAllocatorVault.FeeTooHigh.selector, 0.05e18 + 1, 0.05e18));
        new AllocatorVault(p);
    }

    function test_constructor_revertsOnFeesWithoutRecipient() public {
        AllocatorVault.InitParams memory p = _params();
        p.feeRecipient = address(0);
        vm.expectRevert(IAllocatorVault.ZeroFeeRecipient.selector);
        new AllocatorVault(p);
    }

    function test_constructor_allowsNoRecipientWithZeroFees() public {
        AllocatorVault.InitParams memory p = _params();
        p.feeRecipient = address(0);
        p.performanceFee = 0;
        p.managementFee = 0;
        AllocatorVault v = new AllocatorVault(p);
        assertEq(v.feeRecipient(), address(0));
    }

    function test_fixture_listsThreeStrategiesInOrder() public view {
        assertEq(vault.withdrawQueueLength(), 3);
        assertEq(address(vault.withdrawQueue(0)), address(liquid));
        assertEq(address(vault.withdrawQueue(1)), address(lossy));
        assertEq(address(vault.withdrawQueue(2)), address(illiquid));
        IAllocatorVault.StrategyConfig memory cfg = vault.config(liquid);
        assertTrue(cfg.enabled);
        assertEq(cfg.cap, _cap());
        assertEq(cfg.removableAt, 0);
    }
}
