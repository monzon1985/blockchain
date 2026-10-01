// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { BaseTest } from "../BaseTest.sol";
import { KestrelVault } from "kestrel/KestrelVault.sol";

/// @notice Review regressions for the ERC-4626 first-depositor inflation attack: the attacker
///         front-runs the first real deposit with a minimal deposit plus a large `accrue`
///         donation. The dead shares minted on the first deposit make the donation a loss for the
///         attacker, and `minShares` lets the victim refuse a manipulated price outright.
contract ReviewVaultInflationRegression is BaseTest {
    uint256 internal constant DONATION = 10 ether;
    uint256 internal constant VICTIM_DEPOSIT = 15 ether;

    function _frontRun() internal {
        vm.deal(attacker, DONATION + 1 ether);
        vm.startPrank(attacker);
        vault.deposit{ value: vault.DEAD_SHARES() + 1 }(attacker, 0); // 1 share for the attacker
        vault.accrue{ value: DONATION }();
        vm.stopPrank();
    }

    function test_review_inflationFrontRunLosesTheDonation() public {
        _frontRun();
        uint256 victimShares = _vaultDeposit(alice, VICTIM_DEPOSIT);
        assertGt(victimShares, 0, "victim minted shares");

        vm.prank(attacker);
        uint256 attackerOut = vault.redeem(1, attacker);
        assertLt(attackerOut, 0.1 ether, "attacker recovers < 1% of the 10 ETH donation");

        vm.prank(alice);
        uint256 victimOut = vault.redeem(victimShares, alice);
        assertGe(victimOut, VICTIM_DEPOSIT * 999 / 1000, "victim loses < 0.1%");
    }

    function test_review_minSharesRefusesAManipulatedPrice() public {
        _frontRun();
        uint256 wouldMint = VICTIM_DEPOSIT * vault.totalSupply() / vault.totalManaged();
        vm.deal(alice, VICTIM_DEPOSIT);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(KestrelVault.SlippageExceeded.selector, wouldMint, VICTIM_DEPOSIT)
        );
        vault.deposit{ value: VICTIM_DEPOSIT }(alice, VICTIM_DEPOSIT); // expects ~1:1
    }

    function test_review_firstDepositMintsDeadShares() public {
        uint256 shares = _vaultDeposit(alice, 1 ether);
        assertEq(shares, 1 ether - vault.DEAD_SHARES(), "first depositor pays the dead shares");
        assertEq(vault.balanceOf(vault.DEAD()), vault.DEAD_SHARES(), "dead shares locked");
        assertEq(vault.totalSupply(), vault.totalManaged(), "price starts at exactly 1");
    }
}
