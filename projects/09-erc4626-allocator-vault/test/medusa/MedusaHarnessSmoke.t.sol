// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";

import {AllocatorVaultMedusa} from "./AllocatorVaultMedusa.sol";

/// @notice Runs the Medusa harness under Foundry too: it must deploy within one transaction's gas and keep all of its
///         properties (and never hit one of its assertions) through a scripted sequence that touches every action,
///         with time moving between calls.
contract MedusaHarnessSmokeTest is Test {
    AllocatorVaultMedusa internal harness;

    function setUp() public {
        uint256 g = gasleft();
        harness = new AllocatorVaultMedusa();
        assertLt(g - gasleft(), 30_000_000, "deployment fits the Medusa transaction gas limit");
    }

    function _assertProperties() internal view {
        assertTrue(harness.property_solvency(), "solvency");
        assertTrue(harness.property_totalAssetsBacked(), "backing");
        assertTrue(harness.property_sharePriceMonotoneApartFromLosses(), "price");
        assertTrue(harness.property_feeSharesBoundedByHighWaterMarkGain(), "fees");
        assertTrue(harness.property_highWaterMarkNeverDecreases(), "hwm");
        assertTrue(harness.property_accrualMatchesPreview(), "accrual");
        assertTrue(harness.property_safePriceNeverAboveSharePrice(), "safe price");
    }

    function test_harness_scriptedSequenceKeepsProperties() public {
        for (uint256 i; i < 80; ++i) {
            uint256 r = uint256(keccak256(abi.encode(i)));
            harness.deposit(r >> 16, r % 2 == 0);
            if (i % 2 == 0) harness.reallocate(r, r >> 8);
            if (i % 3 == 0) harness.strategyYield(r >> 4, r >> 32);
            if (i % 4 == 0) harness.withdraw(r >> 12, r % 3 == 0);
            if (i % 5 == 0) harness.strategyLoss(r >> 40);
            if (i % 6 == 0) harness.donate(r >> 24);
            if (i % 7 == 0) harness.lend(r >> 20);
            if (i % 8 == 0) harness.repay(r >> 28);
            if (i % 9 == 0) harness.mint(r >> 36, r % 2 == 1);
            if (i % 10 == 0) harness.redeem(r >> 44, r % 2 == 0);
            if (i % 11 == 0) harness.setPaused(r % 3 != 0);
            if (i % 12 == 0) harness.startRemoval(r >> 52);
            if (i % 13 == 0) harness.revokeRemoval(r >> 56);
            if (i % 5 == 1) harness.removeStrategy(r >> 60);
            if (i % 7 == 2) harness.relist(r >> 64);
            vm.warp(block.timestamp + r % 2 days);
            harness.accrue();
            _assertProperties();
        }
    }
}
