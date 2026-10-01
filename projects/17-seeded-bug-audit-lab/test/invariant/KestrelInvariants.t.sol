// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { Test } from "forge-std/Test.sol";
import { KestrelSystem } from "./KestrelSystem.sol";
import { KestrelHandler } from "./KestrelHandler.sol";

/// @title KestrelInvariants
/// @notice Black-box, handler-based invariants for the Kestrel protocol, written from the
///         specification (README "Invariants"), not from the bug list. They hold on the fixed
///         build. The blind run executes the same file on the vulnerable build and stores which
///         ones fail in `scoreboard/evidence/`.
contract KestrelInvariants is Test {
    KestrelSystem internal sys;
    KestrelHandler internal handler;

    function setUp() public {
        sys = new KestrelSystem();
        handler = new KestrelHandler(sys);
        targetContract(address(handler));
    }

    /// @notice INV-01 Pool solvency: each pool's recorded reserves never exceed its balances.
    function invariant_poolSolvency() public view {
        assertLe(sys.pool().reserve0(), sys.collateral().balanceOf(address(sys.pool())), "pool reserve0");
        assertLe(sys.pool().reserve1(), sys.debt().balanceOf(address(sys.pool())), "pool reserve1");
        assertLe(sys.pool6().reserve0(), sys.stable().balanceOf(address(sys.pool6())), "pool6 reserve0");
        assertLe(sys.pool6().reserve1(), sys.usdc().balanceOf(address(sys.pool6())), "pool6 reserve1");
    }

    /// @notice INV-02 Fee parity: a batch step never pays more than a single swap of the same input.
    function invariant_batchMatchesSingleSwap() public view {
        assertEq(handler.batchExcessOverQuote(), 0, "batch paid above the single-swap quote");
    }

    /// @notice INV-03 Pool rounding favors the pool: amplified tiny batch swaps extract nothing
    ///         beyond the single-swap quote.
    function invariant_poolRoundingFavorsPool() public view {
        assertEq(handler.amplifier().maxError(handler.OP_POOL6_BATCH()), 0, "amplified pool rounding error");
    }

    /// @notice INV-04 Joins pay pro-rata: no join mints shares for less than their share of the
    ///         reserves.
    function invariant_joinsPayProRata() public view {
        assertEq(handler.underpricedJoins(), 0, "underpriced join");
    }

    /// @notice INV-05 Native-fee accounting: the pool's ETH equals the uncollected native fees.
    function invariant_nativeFeeAccounting() public view {
        assertEq(address(sys.pool()).balance, sys.pool().nativeFeesCollected(), "pool ETH != fees");
    }

    /// @notice INV-06 Privileged pool actions are owner-only (emissions, fee withdrawal).
    function invariant_privilegedActionsOwnerOnly() public view {
        assertEq(handler.unauthorizedPrivilegedCalls(), 0, "owner-only action by non-owner");
    }

    /// @notice INV-07 Reward backing: the reward reserve is always held by the pool.
    function invariant_rewardReserveBacked() public view {
        assertLe(sys.pool().rewardReserve(), sys.reward().balanceOf(address(sys.pool())), "unbacked rewards");
    }

    /// @notice INV-08 Vault solvency: accounted assets never exceed the vault's ETH.
    function invariant_vaultSolvency() public view {
        assertLe(sys.vault().totalManaged(), address(sys.vault()).balance, "managed > ETH");
    }

    /// @notice INV-09 Share-price monotonicity: the vault share price never decreases.
    function invariant_sharePriceMonotonic() public view {
        assertEq(handler.maxSharePriceDrop(), 0, "share price decreased");
    }

    /// @notice INV-10 Vault rounding favors the vault: amplified dust withdrawals extract nothing
    ///         beyond the value of the shares they burn.
    function invariant_vaultRoundingFavorsVault() public view {
        assertEq(handler.amplifier().maxError(handler.OP_VAULT_DUST()), 0, "amplified vault rounding error");
    }

    /// @notice INV-11 Price consistency: an integrator reading the share price during an ETH
    ///         callback sees either the price before or after the operation, never a third one.
    function invariant_integratorsSeeConsistentPrice() public view {
        assertEq(handler.inconsistentPriceReads(), 0, "transient share price observed");
    }

    /// @notice INV-12 Manipulation resistance: a swap cannot change a position's collateral
    ///         valuation within the same block.
    function invariant_valuationIgnoresSameBlockSwaps() public view {
        assertEq(handler.valuationMovedBySwap(), 0, "valuation moved by a same-block swap");
    }

    /// @notice INV-13 Governance quorum integrity: stake that exists only inside a flash loan
    ///         never moves the treasury.
    function invariant_treasuryNeedsDurableStake() public view {
        assertEq(handler.treasuryMovedByFlashStake(), 0, "treasury moved by flash-loaned stake");
    }

    /// @notice INV-14 Signatures are single-use: a relayed request never executes twice, on any
    ///         chain.
    function invariant_signaturesSingleUse() public view {
        assertEq(handler.signatureReuses(), 0, "relay request executed twice");
    }

    /// @notice INV-15 Config authority: only the owner changes risk parameters or starts a
    ///         transfer, only the pending owner accepts, and the config initializes once.
    function invariant_configChangesAuthorized() public view {
        assertEq(handler.unauthorizedConfigChanges(), 0, "unauthorized risk-config change");
    }

    /// @notice INV-16 Upgrade authority: only the proxy admin upgrades the proxy.
    function invariant_onlyAdminUpgrades() public view {
        assertEq(handler.unauthorizedUpgrades(), 0, "upgrade by a non-admin");
    }
}
