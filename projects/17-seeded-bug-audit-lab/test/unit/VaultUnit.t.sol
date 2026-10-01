// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { BaseTest } from "../BaseTest.sol";
import { KestrelVault } from "kestrel/KestrelVault.sol";
import { FixedTreeErrors } from "../helpers/FixedTreeErrors.sol";

/// @notice Receiver that reads every vault price view while it receives ETH and records whether
///         each read reverted.
contract PriceReader {
    KestrelVault internal immutable vault;
    bytes public sharesError;
    bytes public assetsError;
    bytes public priceError;

    constructor(KestrelVault _vault) {
        vault = _vault;
    }

    function depositAndRedeem() external payable {
        uint256 shares = vault.deposit{ value: msg.value }(address(this), 0);
        vault.redeem(shares, address(this));
    }

    receive() external payable {
        try vault.convertToShares(1e18) { }
        catch (bytes memory e) {
            sharesError = e;
        }
        try vault.convertToAssets(1e18) { }
        catch (bytes memory e) {
            assetsError = e;
        }
        try vault.pricePerShare() { }
        catch (bytes memory e) {
            priceError = e;
        }
    }
}

/// @notice Contract with no way to receive ETH.
contract NoEth { }

/// @notice Unit tests for {KestrelVault}: happy paths and every revert path.
contract VaultUnit is BaseTest {
    function test_deposit_firstAndSubsequent() public {
        uint256 s1 = _vaultDeposit(alice, 50 ether);
        assertEq(s1, 50 ether - vault.DEAD_SHARES(), "first deposit pays the dead shares");
        vm.deal(address(this), 50 ether);
        vault.accrue{ value: 50 ether }(); // price 2
        uint256 s2 = _vaultDeposit(bob, 10 ether);
        assertApproxEqAbs(s2, 5 ether, 1, "deposit at price 2 mints half");
        assertEq(vault.totalManaged(), 110 ether);
    }

    function test_deposit_reverts() public {
        vm.expectRevert(KestrelVault.ZeroAmount.selector);
        vault.deposit{ value: 0 }(alice, 0);
        uint256 dead = vault.DEAD_SHARES();
        vm.expectRevert(KestrelVault.ZeroAmount.selector);
        vault.deposit{ value: dead }(alice, 0);

        _vaultDeposit(alice, 10 ether);
        vm.expectRevert(abi.encodeWithSelector(KestrelVault.SlippageExceeded.selector, 1 ether, 1 ether + 1));
        vault.deposit{ value: 1 ether }(alice, 1 ether + 1);

        // At a share price above 1, one wei mints zero shares.
        vault.accrue{ value: 10 ether }();
        vm.expectRevert(abi.encodeWithSelector(KestrelVault.SlippageExceeded.selector, 0, 0));
        vault.deposit{ value: 1 }(alice, 0);
    }

    function test_accrue_reverts() public {
        vm.expectRevert(KestrelVault.ZeroAmount.selector);
        vault.accrue{ value: 0 }();
        vm.expectRevert(KestrelVault.NoShares.selector);
        vault.accrue{ value: 1 }();
    }

    function test_withdraw_burnsSharesAndPays() public {
        _vaultDeposit(alice, 100 ether);
        vm.deal(address(this), 100 ether);
        vault.accrue{ value: 100 ether }();
        uint256 before = vault.balanceOf(alice);
        vm.prank(alice);
        uint256 burned = vault.withdraw(10 ether, alice);
        assertEq(before - vault.balanceOf(alice), burned);
        assertApproxEqAbs(burned, 5 ether, 1, "10 ETH at price ~2 burns ~5 shares");
        assertEq(alice.balance, 10 ether);
    }

    function test_withdraw_reverts() public {
        vm.expectRevert(KestrelVault.ZeroAmount.selector);
        vault.withdraw(0, alice);
        vm.expectRevert(abi.encodeWithSelector(KestrelVault.InsufficientAssets.selector, 1, 0));
        vault.withdraw(1, alice);

        _vaultDeposit(alice, 10 ether);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(KestrelVault.InsufficientShares.selector, 1 ether, 0));
        vault.withdraw(1 ether, bob);

        NoEth sink = new NoEth();
        vm.prank(alice);
        vm.expectRevert(KestrelVault.EthTransferFailed.selector);
        vault.withdraw(1 ether, address(sink));
    }

    function test_redeem_paysAssets() public {
        uint256 shares = _vaultDeposit(alice, 50 ether);
        vm.prank(alice);
        uint256 assets = vault.redeem(shares, alice);
        assertEq(assets, shares, "price 1");
        assertEq(vault.totalManaged(), vault.DEAD_SHARES(), "dead shares keep their wei");
    }

    function test_redeem_reverts() public {
        vm.expectRevert(KestrelVault.ZeroAmount.selector);
        vault.redeem(0, alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(KestrelVault.InsufficientShares.selector, 1, 0));
        vault.redeem(1, alice);
    }

    function test_views() public {
        _vaultDeposit(alice, 10 ether);
        assertEq(vault.convertToShares(1 ether), 1 ether);
        assertEq(vault.convertToAssets(1 ether), 1 ether);
        assertEq(vault.pricePerShare(), 1e18);
        KestrelVault empty = new KestrelVault();
        assertEq(empty.convertToShares(7), 7, "empty vault converts 1:1");
        assertEq(empty.convertToAssets(7), 7, "empty vault converts 1:1");
    }

    /// @dev Fixed tree only: price views revert while an operation is in flight.
    function test_views_revertMidOperation() public {
        _vaultDeposit(alice, 10 ether);
        PriceReader reader = new PriceReader(vault);
        reader.depositAndRedeem{ value: 1 ether }();
        bytes memory expected = abi.encodeWithSelector(FixedTreeErrors.ReentrantRead.selector);
        assertEq(reader.sharesError(), expected, "convertToShares guarded");
        assertEq(reader.assetsError(), expected, "convertToAssets guarded");
        assertEq(reader.priceError(), expected, "pricePerShare guarded");
    }
}
