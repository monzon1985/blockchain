// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { BaseTest } from "../BaseTest.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { KestrelPool } from "kestrel/KestrelPool.sol";
import { KestrelRelayer } from "kestrel/KestrelRelayer.sol";

/// @notice Gas benchmark: one honest call per entry point a fix touches, measured with
///         `vm.snapshotGasLastCall`. Run under both profiles; the committed `gas/vulnerable` and
///         `gas/fixed` snapshots give the v1 -> v2 cost of every fix and are checked in CI with
///         `FORGE_SNAPSHOT_CHECK=true`.
contract GasBench is BaseTest {
    function setUp() public override {
        super.setUp();
        _seedLending(500_000e18);
        _mintApprove(collateral, alice, 1_000_000e18, address(pool));
        _mintApprove(debt, alice, 1_000_000e18, address(pool));
        vm.deal(alice, 100 ether);
    }

    function test_gas_swap() public {
        vm.prank(alice);
        pool.swap(address(collateral), 1000e18, 0, alice);
        vm.snapshotGasLastCall("KestrelPool.swap");
    }

    function test_gas_batchSwap() public {
        address[] memory assets = new address[](2);
        assets[0] = address(collateral);
        assets[1] = address(debt);
        KestrelPool.BatchStep[] memory steps = new KestrelPool.BatchStep[](1);
        steps[0] = KestrelPool.BatchStep({ assetInIndex: 0, assetOutIndex: 1, amountIn: 1000e18 });
        vm.prank(alice);
        pool.batchSwap(assets, steps, alice);
        vm.snapshotGasLastCall("KestrelPool.batchSwap (2 assets, 1 step) [SC02 SC05 SC07a]");
    }

    function test_gas_swapWithNativeSponsor() public {
        vm.prank(alice);
        pool.swapWithNativeSponsor{ value: 1 ether }(address(debt), 1000e18, 0, alice);
        vm.snapshotGasLastCall("KestrelPool.swapWithNativeSponsor (with refund) [SC06]");
    }

    function test_gas_addLiquidityExactShares() public {
        vm.prank(alice);
        pool.addLiquidityExactShares(1000e18, 2000e18, 2000e18, alice);
        vm.snapshotGasLastCall("KestrelPool.addLiquidityExactShares [SC09]");
    }

    function test_gas_setRewardRate() public {
        pool.setRewardRate(1e18);
        vm.snapshotGasLastCall("KestrelPool.setRewardRate (owner) [SC01]");
    }

    function test_gas_vaultDeposit() public {
        _vaultDeposit(bob, 10 ether);
        vm.prank(alice);
        vault.deposit{ value: 10 ether }(alice, 0);
        vm.snapshotGasLastCall("KestrelVault.deposit");
    }

    function test_gas_vaultWithdraw() public {
        _vaultDeposit(alice, 10 ether);
        vault.accrue{ value: 1 ether }();
        vm.prank(alice);
        vault.withdraw(1 ether, alice);
        vm.snapshotGasLastCall("KestrelVault.withdraw [SC07b]");
    }

    function test_gas_vaultRedeem() public {
        uint256 shares = _vaultDeposit(alice, 10 ether);
        vm.prank(alice);
        vault.redeem(shares / 2, alice);
        vm.snapshotGasLastCall("KestrelVault.redeem [SC08]");
    }

    function test_gas_vaultConvertToAssets() public {
        _vaultDeposit(alice, 10 ether);
        vault.convertToAssets(1e18);
        vm.snapshotGasLastCall("KestrelVault.convertToAssets [SC08]");
    }

    function test_gas_lendingBorrow() public {
        _mintApprove(collateral, bob, 10_000e18, address(lending));
        vm.startPrank(bob);
        lending.depositCollateral(10_000e18);
        lending.borrow(5000e18);
        vm.stopPrank();
        vm.snapshotGasLastCall("KestrelLending.borrow [SC03]");
    }

    function test_gas_emergencyExecute() public {
        gov.transfer(address(governor), 1000e18);
        vm.roll(block.number + 1);
        governor.emergencyExecute(address(gov), 0, abi.encodeCall(IERC20.transfer, (bob, 1000e18)));
        vm.snapshotGasLastCall("KestrelGovernor.emergencyExecute [SC04]");
    }

    function test_gas_relaySwap() public {
        collateral.mint(user, 1000e18);
        vm.prank(user);
        collateral.approve(address(relayer), type(uint256).max);
        KestrelRelayer.SwapRequest memory req = KestrelRelayer.SwapRequest({
            user: user,
            tokenIn: address(collateral),
            amountIn: 1000e18,
            minOut: 0,
            to: user,
            nonce: 0,
            deadline: block.timestamp + 1 hours
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPk, relayer.hashRequest(req));
        relayer.relaySwap(req, abi.encodePacked(r, s, v));
        vm.snapshotGasLastCall("KestrelRelayer.relaySwap [REPLAY]");
    }

    function test_gas_configReadThroughProxy() public {
        vm.prank(alice);
        config.ethPrice();
        vm.snapshotGasLastCall("KestrelProxy -> KestrelConfig.ethPrice [SC10]");
    }
}
