// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { BaseTest } from "../BaseTest.sol";
import { KestrelPool } from "kestrel/KestrelPool.sol";
import { FixedPointMath } from "kestrel/lib/FixedPointMath.sol";
import { ExactSharesAttacker } from "../attacks/ExactSharesAttacker.sol";

/// @notice SC09 regression (fixed profile): {FixedPointMath.checkedShl} flags every shift that
///         loses a set bit, so the wrapped exact-share join reverts with
///         {KestrelPool.SharesTooLarge}, and every successful shift is exactly reversible.
contract SC09ExactSharesOverflowRegression is BaseTest {
    function test_regression_wrappedShareCountReverts() public {
        ExactSharesAttacker atk = new ExactSharesAttacker(pool);
        collateral.mint(address(atk), 10);
        debt.mint(address(atk), 10);
        uint256 shares = (uint256(1) << 128) + 1;

        vm.expectRevert(abi.encodeWithSelector(KestrelPool.SharesTooLarge.selector, shares));
        atk.attack(shares, 10, attacker);
    }

    function test_regression_overflowIsFlagged() public pure {
        (uint256 result, bool overflow) = FixedPointMath.checkedShl((uint256(1) << 128) + 1, 128);
        assertTrue(overflow, "lost bit flagged");
        assertEq(result, 0, "no truncated value returned");
    }

    /// @dev The defining property: a shift reported as safe is exactly reversible.
    function testFuzz_regression_successfulShiftIsReversible(uint256 n, uint16 rawShift) public pure {
        uint256 shift = bound(rawShift, 0, 320);
        (uint256 result, bool overflow) = FixedPointMath.checkedShl(n, shift);
        if (overflow) {
            assertEq(result, 0, "overflow returns 0");
            assertTrue(shift >= 256 ? n != 0 : (n >> (256 - shift)) != 0, "overflow only when bits are lost");
        } else {
            assertEq(shift >= 256 ? 0 : result >> shift, shift >= 256 ? 0 : n, "safe shift is reversible");
            if (shift >= 256) assertEq(n, 0, "only zero survives a full-word shift");
        }
    }
}
