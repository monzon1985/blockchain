// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IAllocatorVault} from "../../src/interfaces/IAllocatorVault.sol";
import {OzVault} from "../mocks/OzVault.sol";
import {NaiveAllocatorVault} from "../naive/NaiveAllocatorVault.sol";
import {VaultFixture} from "../utils/VaultFixture.sol";

/// @title First-depositor donation (inflation) attack
/// @notice The attacker is the first depositor (1 wei), donates to inflate the share price so the victim's deposit
///         rounds down to (almost) nothing, then redeems. Run against four vaults:
///         - naive, no virtual shares (the pre-OZ-4.9 formula): the attacker steals the whole victim deposit;
///         - OpenZeppelin ERC4626 at offset 0 (1 virtual share): the victim still loses everything, but the attacker
///           loses more than he gains: griefing only;
///         - OpenZeppelin ERC4626 at offset 6: the victim loses dust, the attacker loses ~half of the donation;
///         - AllocatorVault (offset 6 + 7-day unlock of donations): same bound even when the attacker waits out the
///           unlock; in the same block the donation does not move the price at all.
contract DonationAttackTest is VaultFixture {
    uint256 internal constant VICTIM_DEPOSIT = 1000e18;

    struct Outcome {
        int256 attackerPnl;
        uint256 victimLoss;
        uint256 victimShares;
    }

    function _run(IERC4626 target, uint256 donation, bool accrueAndWaitForUnlock) internal returns (Outcome memory o) {
        asset.mint(attacker, 1 + donation);
        vm.startPrank(attacker);
        asset.approve(address(target), 1);
        target.deposit(1, attacker);
        asset.transfer(address(target), donation);
        vm.stopPrank();

        if (accrueAndWaitForUnlock) {
            IAllocatorVault(address(target)).accrue();
            vm.warp(block.timestamp + 7 days);
        }

        asset.mint(alice, VICTIM_DEPOSIT);
        vm.startPrank(alice);
        asset.approve(address(target), VICTIM_DEPOSIT);
        o.victimShares = target.deposit(VICTIM_DEPOSIT, alice);
        vm.stopPrank();

        vm.startPrank(attacker);
        uint256 attackerOut = target.redeem(target.balanceOf(attacker), attacker, attacker);
        vm.stopPrank();

        o.attackerPnl = int256(attackerOut) - int256(1 + donation);
        o.victimLoss = VICTIM_DEPOSIT - target.convertToAssets(o.victimShares);
    }

    function _log(string memory label, uint256 donation, Outcome memory o) internal {
        emit log(label);
        emit log_named_decimal_uint("  attacker donation (tokens)", donation, 18);
        emit log_named_decimal_int("  attacker P&L      (tokens)", o.attackerPnl, 18);
        emit log_named_decimal_uint("  victim loss      (tokens)", o.victimLoss, 18);
    }

    function test_donation_naiveNoVirtualShares_attackerStealsVictimDeposit() public {
        NaiveAllocatorVault naive = new NaiveAllocatorVault(IERC20(address(asset)), false);
        uint256 donation = VICTIM_DEPOSIT; // victim shares = floor(1000e18 * 1 / (1 + 1000e18)) = 0
        Outcome memory o = _run(naive, donation, false);
        _log("naive (no virtual shares, offset 0)", donation, o);

        assertEq(o.victimShares, 0);
        assertEq(o.victimLoss, VICTIM_DEPOSIT, "victim loses the whole deposit");
        assertEq(o.attackerPnl, int256(VICTIM_DEPOSIT), "attacker profits exactly the victim's deposit");
    }

    function test_donation_ozOffset0_isGriefingOnly() public {
        OzVault oz = new OzVault(IERC20(address(asset)), 0);
        uint256 donation = 2 * VICTIM_DEPOSIT; // minimum that zeroes the victim with 1 virtual share
        Outcome memory o = _run(oz, donation, false);
        _log("OpenZeppelin ERC4626, offset 0 (1 virtual share)", donation, o);

        assertEq(o.victimShares, 0);
        assertEq(o.victimLoss, VICTIM_DEPOSIT, "victim is still wiped out");
        assertLt(o.attackerPnl, 0, "but the attacker loses money doing it");
        assertLe(o.attackerPnl, -int256(VICTIM_DEPOSIT / 2) + 1, "half the donation goes to the virtual share");
    }

    function test_donation_ozOffset6_victimLossBoundedByDonationOverOneMillion() public {
        OzVault oz = new OzVault(IERC20(address(asset)), 6);
        uint256 donation = 10 * VICTIM_DEPOSIT;
        Outcome memory o = _run(oz, donation, false);
        _log("OpenZeppelin ERC4626, offset 6", donation, o);

        assertGt(o.victimShares, 0);
        assertLe(o.victimLoss, donation / 1e6, "victim loses at most donation / 10**6");
        assertLt(o.attackerPnl, -int256(donation * 49 / 100), "attacker burns ~half of the donation");
    }

    function test_donation_hardened_attackerLosesEvenAfterWaitingOutTheUnlock() public {
        uint256 donation = 10 * VICTIM_DEPOSIT;
        Outcome memory o = _run(vault, donation, true);
        _log("AllocatorVault (offset 6 + 7-day unlock), attacker waits 7 days", donation, o);

        assertGt(o.victimShares, 0);
        assertLe(o.victimLoss, donation / 1e6, "victim loses at most donation / 10**6");
        assertLt(o.attackerPnl, -int256(donation * 49 / 100), "attacker burns ~half of the donation");
    }

    function test_donation_hardened_sameBlockDonationDoesNotMoveThePrice() public {
        uint256 donation = VICTIM_DEPOSIT;
        uint256 priceBefore = vault.sharePrice();
        Outcome memory o = _run(vault, donation, false);
        _log("AllocatorVault, same-block donation (still locked)", donation, o);

        assertEq(o.victimLoss, 0, "the victim is priced exactly as without the donation");
        assertEq(o.victimShares, VICTIM_DEPOSIT * 1e6);
        assertLe(o.attackerPnl, -int256(donation) + 1, "the whole donation is left to the victim and the vault");
        assertGe(vault.sharePrice(), priceBefore);
    }

    function test_donation_hardened_depositRevertsInsteadOfMintingZeroShares() public {
        // Donate the >= 2e6x the victim deposit needed to zero it, wait out the unlock: the deposit reverts.
        uint256 victim = 1e12;
        uint256 donation = 2e6 * victim;
        asset.mint(attacker, 1 + donation);
        vm.startPrank(attacker);
        asset.approve(address(vault), 1);
        vault.deposit(1, attacker);
        asset.transfer(address(vault), donation);
        vm.stopPrank();
        vault.accrue();
        vm.warp(block.timestamp + 7 days);

        asset.mint(alice, victim);
        vm.startPrank(alice);
        asset.approve(address(vault), victim);
        vm.expectRevert(abi.encodeWithSelector(IAllocatorVault.ZeroShares.selector, victim));
        vault.deposit(victim, alice);
        vm.stopPrank();
    }
}
