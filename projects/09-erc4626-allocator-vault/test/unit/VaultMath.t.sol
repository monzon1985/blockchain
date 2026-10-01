// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";

import {VaultMath} from "../../src/libraries/VaultMath.sol";

/// @notice Unit and differential fuzz tests of the pure accounting math. The differential reference is
///         OpenZeppelin's `Math.mulDiv` (an independent 512-bit implementation) against Solady's `fullMulDiv`.
contract VaultMathTest is Test {
    uint256 internal constant PERIOD = 7 days;
    uint256 internal constant RAY = 1e27;
    uint256 internal constant WAD = 1e18;

    /*//////////////////////////////////////////////////////////////
                             PROFIT UNLOCK
    //////////////////////////////////////////////////////////////*/

    function test_lockedProfitAt_endpoints() public pure {
        assertEq(VaultMath.lockedProfitAt(700, 100, 100 + PERIOD, 100), 700);
        assertEq(VaultMath.lockedProfitAt(700, 100, 100 + PERIOD, 100 + PERIOD), 0);
        assertEq(VaultMath.lockedProfitAt(700, 100, 100 + PERIOD, 100 + PERIOD + 1), 0);
        assertEq(VaultMath.lockedProfitAt(0, 100, 100 + PERIOD, 150), 0);
        assertEq(VaultMath.lockedProfitAt(700, 100, 100 + PERIOD, 100 + 1 days), 600);
    }

    function testFuzz_lockedProfitAt_matchesCeilReference(uint256 locked, uint256 elapsed, uint256 duration)
        public
        pure
    {
        locked = bound(locked, 1, type(uint200).max);
        duration = bound(duration, 1, PERIOD);
        elapsed = bound(elapsed, 0, duration - 1);
        uint256 got = VaultMath.lockedProfitAt(locked, 1000, 1000 + duration, 1000 + elapsed);
        // locked * remaining / duration, rounded UP (the unlocked part rounds down).
        uint256 expected = Math.mulDiv(locked, duration - elapsed, duration, Math.Rounding.Ceil);
        assertEq(got, expected);
    }

    function testFuzz_lockedProfitAt_isNonIncreasingInTime(uint256 locked, uint256 t1, uint256 t2) public pure {
        locked = bound(locked, 0, type(uint200).max);
        t1 = bound(t1, 1000, 1000 + 2 * PERIOD);
        t2 = bound(t2, t1, 1000 + 2 * PERIOD);
        assertGe(
            VaultMath.lockedProfitAt(locked, 1000, 1000 + PERIOD, t1),
            VaultMath.lockedProfitAt(locked, 1000, 1000 + PERIOD, t2)
        );
    }

    function test_lockProfit_freshProfitGetsFullPeriod() public pure {
        (uint256 locked, uint256 end) = VaultMath.lockProfit(0, 100, 5000, PERIOD);
        assertEq(locked, 100);
        assertEq(end, 5000 + PERIOD);
    }

    function test_lockProfit_restartsEverythingStillLocked() public pure {
        // 700 still locked with one day left; 100 of new profit restarts a full period for all 800.
        (uint256 locked, uint256 end) = VaultMath.lockProfit(700, 100, 5000, PERIOD);
        assertEq(locked, 800);
        assertEq(end, 5000 + PERIOD);
    }

    /// @dev Regression for the review finding: under the old profit-weighted merge (Yearn V3), 100 of new profit
    ///      arriving one day before 10,000 finished unlocking would all unlock within ~1.4 days. The schedule must never
    ///      release more than an exact per-tranche reference (each profit linear over its own full period) would.
    function testFuzz_lockProfit_neverUnlocksAnyProfitFasterThanItsOwnPeriod(
        uint256[4] memory profits,
        uint256[4] memory gaps,
        uint256 checkAfter
    ) public pure {
        uint256 t = 1_000_000;
        uint256 locked;
        uint256 last = t;
        uint256 end = t;
        uint256[4] memory times;
        for (uint256 i; i < 4; ++i) {
            profits[i] = bound(profits[i], 0, type(uint96).max);
            t += bound(gaps[i], 0, 2 * PERIOD);
            locked = VaultMath.lockedProfitAt(locked, last, end, t); // what the vault does at every accrual
            if (profits[i] != 0) (locked, end) = VaultMath.lockProfit(locked, profits[i], t, PERIOD);
            last = t;
            times[i] = t;
        }
        uint256 s = t + bound(checkAfter, 0, 2 * PERIOD);
        uint256 modelLocked = VaultMath.lockedProfitAt(locked, last, end, s);
        uint256 exactLocked;
        for (uint256 i; i < 4; ++i) {
            if (times[i] + PERIOD > s) exactLocked += profits[i] * (times[i] + PERIOD - s) / PERIOD;
        }
        assertGe(modelLocked, exactLocked, "never more unlocked than every profit on its own 7-day line");
        assertLe(end, t + PERIOD, "nothing is ever locked for more than one period ahead");
    }

    /*//////////////////////////////////////////////////////////////
                                  FEES
    //////////////////////////////////////////////////////////////*/

    function test_managementFeeAssets_values() public pure {
        assertEq(VaultMath.managementFeeAssets(1000e18, 0.02e18, 365 days), 20e18);
        assertEq(VaultMath.managementFeeAssets(1000e18, 0, 365 days), 0);
        assertEq(VaultMath.managementFeeAssets(1000e18, 0.02e18, 0), 0);
        assertEq(VaultMath.managementFeeAssets(1000e18, 0.05e18, 100 * 365 days), 1000e18, "capped");
    }

    function testFuzz_managementFeeAssets_roundsDown(uint256 ta, uint256 fee, uint256 dt) public pure {
        ta = bound(ta, 0, type(uint128).max);
        fee = bound(fee, 1, 0.05e18);
        dt = bound(dt, 1, 20 * 365 days);
        uint256 got = VaultMath.managementFeeAssets(ta, fee, dt);
        assertEq(got, Math.min(ta, Math.mulDiv(ta, fee * dt, WAD * 365 days)));
    }

    function test_performanceFeeAssets_onlyAboveMark() public pure {
        assertEq(VaultMath.performanceFeeAssets(1e21, 1e21, 1e24, 0.2e18), 0);
        assertEq(VaultMath.performanceFeeAssets(0.9e21, 1e21, 1e24, 0.2e18), 0);
        assertEq(VaultMath.performanceFeeAssets(1.1e21, 1e21, 1e24, 0), 0);
        // 1e24 shares gained 0.1e21 RAY-price each: 1e24 * 0.1e21 / 1e27 = 1e17 assets of gain, 20% = 2e16.
        assertEq(VaultMath.performanceFeeAssets(1.1e21, 1e21, 1e24, 0.2e18), 2e16);
    }

    function testFuzz_feeShares_worthAtMostTheFee(uint256 feeAssets, uint256 supply, uint256 ta) public pure {
        ta = bound(ta, 1, type(uint128).max);
        supply = bound(supply, 1e6, type(uint128).max);
        feeAssets = bound(feeAssets, 0, ta);
        uint256 shares = VaultMath.feeShares(feeAssets, supply, ta);
        uint256 value = Math.mulDiv(shares, ta + 1, supply + shares);
        assertLe(value, feeAssets, "rounded against the fee recipient");
        if (shares != 0) {
            // One more share would be worth at least the fee: the result is the floor, not an under-estimate.
            assertGe(Math.mulDiv(shares + 1, ta + 1, supply + shares + 1, Math.Rounding.Ceil), feeAssets);
        }
    }

    /*//////////////////////////////////////////////////////////////
                             PRICE AND LIMIT
    //////////////////////////////////////////////////////////////*/

    function test_sharePrice_emptyVault() public pure {
        assertEq(VaultMath.sharePrice(0, 0, 1e6), RAY / 1e6);
    }

    function testFuzz_sharePrice_matchesReference(uint256 ta, uint256 supply) public pure {
        ta = bound(ta, 0, type(uint160).max);
        supply = bound(supply, 0, type(uint200).max);
        assertEq(VaultMath.sharePrice(ta, supply, 1e6), Math.mulDiv(ta + 1, RAY, supply + 1e6));
    }

    function testFuzz_priceCeiling_growsLinearlyFromCheckpoint(uint256 checkpoint, uint256 growth, uint256 dt)
        public
        pure
    {
        checkpoint = bound(checkpoint, 1, type(uint128).max);
        growth = bound(growth, 1, 1e18);
        dt = bound(dt, 0, 10 * 365 days);
        uint256 ceiling = VaultMath.priceCeiling(checkpoint, growth, dt);
        assertEq(ceiling, checkpoint + Math.mulDiv(checkpoint, growth * dt, WAD * 365 days));
        assertGe(ceiling, checkpoint);
    }
}
