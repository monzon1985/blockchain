// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { BaseTest } from "../BaseTest.sol";
import { DustWithdrawAttacker } from "../attacks/DustWithdrawAttacker.sol";

/// @notice SC07b regression (fixed profile): {withdraw} rounds the shares to burn UP, so a dust
///         withdrawal always burns at least one share and the amplifier extracts nothing.
contract SC07bVaultRoundingRegression is BaseTest {
    function test_regression_dustWithdrawalsAreNotFree() public {
        _vaultDeposit(alice, 100 ether);
        vm.deal(address(this), 100 ether);
        vault.accrue{ value: 100 ether }();

        DustWithdrawAttacker atk = new DustWithdrawAttacker(vault);
        vm.deal(address(this), 100 ether);
        atk.fund{ value: 100 ether }();
        uint256 sharesBefore = vault.balanceOf(address(atk.op()));

        uint256 extracted = atk.run(500, 1);

        assertEq(extracted, 0, "no ETH beyond the value of the burned shares");
        assertEq(
            sharesBefore - vault.balanceOf(address(atk.op())), 500, "one share burned per dust withdrawal"
        );
    }

    /// @dev For any price and withdrawal size, burned shares are worth at least the ETH paid.
    function testFuzz_regression_withdrawRoundsForTheVault(uint96 yield_, uint96 assets) public {
        _vaultDeposit(alice, 10 ether);
        vm.deal(address(this), uint256(yield_) + 1);
        vault.accrue{ value: uint256(yield_) + 1 }();

        uint256 supply = vault.totalSupply();
        uint256 managed = vault.totalManaged();
        uint256 amount = bound(assets, 1, 10 ether);
        uint256 before = vault.balanceOf(alice);
        vm.prank(alice);
        try vault.withdraw(amount, alice) returns (uint256 burned) {
            assertEq(before - vault.balanceOf(alice), burned, "reported == burned");
            assertGe(burned * managed, amount * supply, "burned shares cover the ETH paid");
        } catch { }
    }
}
