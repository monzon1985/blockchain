// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {VolatilityFeeMedusa} from "./VolatilityFeeMedusa.sol";

/// @notice Runs the Medusa harness under Foundry too: it must deploy within one transaction's gas and keep its
/// properties through a short scripted sequence (every action, every module kind, claim-settled swaps, deliveries).
contract MedusaHarnessSmokeTest is Test {
    VolatilityFeeMedusa internal harness;

    function setUp() public {
        uint256 g = gasleft();
        harness = new VolatilityFeeMedusa();
        assertLt(g - gasleft(), 30_000_000, "deployment fits the Medusa transaction gas limit");
    }

    function test_harness_scriptedSequenceKeepsProperties() public {
        for (uint256 i; i < 48; ++i) {
            uint256 r = uint256(keccak256(abi.encode(i)));
            harness.swap(r, r % 2 == 0, r % 3 != 0);
            if (i % 4 == 0) harness.advanceBlocks(r);
            if (i % 5 == 0) harness.roundTrip(r >> 8, r % 2 == 1);
            if (i % 3 == 0) harness.swapWithClaims(r >> 24, r % 2 == 1);
            if (i % 6 == 0) harness.addLiquidity(int256(r % 400) - 200, r >> 16, r >> 32);
            if (i % 7 == 0) harness.setModule(i / 7);
            if (i % 9 == 0) harness.removeLiquidity(r >> 4, r >> 12);
            if (i % 8 == 0) harness.donate(r >> 20, r >> 40);
            if (i % 5 == 1) harness.deliverNotification(r >> 28);
            if (i % 11 == 0) harness.redeemClaims(r % 2 == 0, r >> 36);
            assertTrue(harness.property_hookHoldsNoValue(), "hook holds no value");
            assertTrue(harness.property_feeWithinBounds(), "applied fee = quote, within bounds");
            assertTrue(harness.property_feeConstantWithinBlock(), "applied fee constant within block");
            assertTrue(harness.property_oracleConsistent(), "EWMA bounded, price inside the block range");
            assertTrue(harness.property_poolManagerSolvent(), "PoolManager solvent");
        }
    }
}
