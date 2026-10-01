// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IAllocatorVault} from "../../src/interfaces/IAllocatorVault.sol";
import {OzVault} from "../mocks/OzVault.sol";
import {VaultFixture} from "../utils/VaultFixture.sol";

/// @notice Gas snapshot (`forge snapshot --match-contract GasBench`, checked in CI). Each test performs exactly one
///         call on a prepared state: 3 listed strategies, fees on, and a plain OpenZeppelin ERC-4626 (offset 6) as
///         the baseline for what the hardening costs.
contract GasBench is VaultFixture {
    OzVault internal oz;
    uint256 internal constant AMOUNT = 1000e18;

    function _initialPerformanceFee() internal pure override returns (uint256) {
        return 0.1e18;
    }

    function _initialManagementFee() internal pure override returns (uint256) {
        return 0.01e18;
    }

    function setUp() public override {
        super.setUp();
        oz = new OzVault(IERC20(address(asset)), 6);

        _deposit(bob, 10_000e18);
        _allocate(liquid, 3000e18);
        _allocate(lossy, 3000e18);
        _allocate(illiquid, 3000e18);
        liquid.simulateYield(30e18);
        vault.accrue();
        vm.warp(block.timestamp + 1 days); // pending unlock + fees: every entry point runs a full accrual

        asset.mint(alice, 10 * AMOUNT);
        vm.startPrank(alice);
        asset.approve(address(vault), type(uint256).max);
        asset.approve(address(oz), type(uint256).max);
        vault.deposit(AMOUNT, alice);
        oz.deposit(AMOUNT, alice);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                               BASELINE
    //////////////////////////////////////////////////////////////*/

    function test_gas_baseline_ozDeposit() public {
        vm.prank(alice);
        oz.deposit(AMOUNT, alice);
    }

    function test_gas_baseline_ozWithdraw() public {
        vm.prank(alice);
        oz.withdraw(AMOUNT / 2, alice, alice);
    }

    /*//////////////////////////////////////////////////////////////
                              USER FLOWS
    //////////////////////////////////////////////////////////////*/

    function test_gas_deposit() public {
        vm.prank(alice);
        vault.deposit(AMOUNT, alice);
    }

    function test_gas_mint() public {
        vm.prank(alice);
        vault.mint(AMOUNT * 1e6, alice);
    }

    function test_gas_withdraw_fromIdle() public {
        vm.prank(alice);
        vault.withdraw(AMOUNT / 2, alice, alice);
    }

    function test_gas_withdraw_pullsFromTwoStrategies() public {
        vm.prank(bob);
        vault.withdraw(5000e18, bob, bob); // 2000 idle + 3000 liquid + rest from lossy
    }

    function test_gas_redeem_all() public {
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(shares, alice, alice);
    }

    /*//////////////////////////////////////////////////////////////
                           KEEPER / CURATION
    //////////////////////////////////////////////////////////////*/

    function test_gas_accrue_threeStrategies() public {
        vault.accrue();
    }

    function test_gas_reallocate_twoMoves() public {
        IAllocatorVault.Allocation[] memory a = new IAllocatorVault.Allocation[](2);
        a[0] = IAllocatorVault.Allocation({strategy: liquid, assets: 1000e18});
        a[1] = IAllocatorVault.Allocation({strategy: illiquid, assets: type(uint256).max});
        vm.prank(allocator);
        vault.reallocate(a);
    }

    function test_gas_submitCap_newStrategy() public {
        IERC4626 fresh = IERC4626(address(oz));
        vm.prank(curator);
        vault.submitCap(fresh, 1e24);
    }

    function test_gas_guardian_zeroCap() public {
        vm.prank(guardian);
        vault.zeroCap(liquid);
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    function test_gas_view_totalAssets() public view {
        vault.totalAssets();
    }

    function test_gas_view_maxWithdraw() public view {
        vault.maxWithdraw(alice);
    }

    function test_gas_view_safeConvertToAssets() public view {
        vault.safeConvertToAssets(1e24);
    }
}

/// @notice The same user flows on a vault with no strategy listed: the difference to `GasBench` is the cost of valuing
///         three strategies live on every entry point.
contract GasBenchNoStrategies is VaultFixture {
    uint256 internal constant AMOUNT = 1000e18;

    function _initialPerformanceFee() internal pure override returns (uint256) {
        return 0.1e18;
    }

    function _initialManagementFee() internal pure override returns (uint256) {
        return 0.01e18;
    }

    function _listDefaultStrategies() internal pure override returns (bool) {
        return false;
    }

    function setUp() public override {
        super.setUp();
        _deposit(bob, 10_000e18);
        asset.mint(address(vault), 30e18);
        vault.accrue();
        vm.warp(block.timestamp + 1 days);
        asset.mint(alice, 10 * AMOUNT);
        vm.startPrank(alice);
        asset.approve(address(vault), type(uint256).max);
        vault.deposit(AMOUNT, alice);
        vm.stopPrank();
    }

    function test_gas_deposit() public {
        vm.prank(alice);
        vault.deposit(AMOUNT, alice);
    }

    function test_gas_withdraw_fromIdle() public {
        vm.prank(alice);
        vault.withdraw(AMOUNT / 2, alice, alice);
    }

    function test_gas_accrue() public {
        vault.accrue();
    }
}
