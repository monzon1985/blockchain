// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";

import {DutchDecay} from "../../src/libraries/DutchDecay.sol";

/// @dev External wrapper so reverts can be asserted.
contract DutchDecayHarness {
    function amountAt(uint256 s, uint256 e, uint256 ds, uint256 de, uint256 t) external pure returns (uint256) {
        return DutchDecay.amountAt(s, e, ds, de, t);
    }
}

contract DutchDecayTest is Test {
    DutchDecayHarness internal h = new DutchDecayHarness();

    function test_endpointsAndMidpoint() public view {
        assertEq(h.amountAt(1000, 900, 100, 200, 0), 1000);
        assertEq(h.amountAt(1000, 900, 100, 200, 100), 1000);
        assertEq(h.amountAt(1000, 900, 100, 200, 150), 950);
        assertEq(h.amountAt(1000, 900, 100, 200, 200), 900);
        assertEq(h.amountAt(1000, 900, 100, 200, 10_000), 900);
    }

    function test_roundsInFavourOfTheUser() public view {
        // decrease = 1 * 1 / 3 = 0.33 -> rounded down to 0, so the user still gets the full start amount
        assertEq(h.amountAt(10, 9, 0, 3, 1), 10);
        // decrease = 1 * 2 / 3 = 0.66 -> 0
        assertEq(h.amountAt(10, 9, 0, 3, 2), 10);
    }

    function test_flatCurveWhenNoDecayWindow() public view {
        assertEq(h.amountAt(1000, 1, 500, 500, 499), 1000);
        assertEq(h.amountAt(1000, 1, 500, 500, 10_000), 1000);
        assertEq(h.amountAt(1000, 1, 500, 400, 450), 1000);
    }

    function test_revertsOnIncreasingCurve() public {
        vm.expectRevert(abi.encodeWithSelector(DutchDecay.DecayIncreasing.selector, 1, 2));
        h.amountAt(1, 2, 0, 10, 5);
    }

    function test_noOverflowAtExtremes() public view {
        uint256 max = type(uint256).max;
        // Exactly halfway: the decrease is floor(max / 2), so the owed amount is the rounded-up half.
        assertEq(h.amountAt(max, 0, 0, 1 << 32, 1 << 31), max - max / 2);
    }

    function testFuzz_boundedByEndAndStart(uint256 s, uint256 e, uint256 ds, uint256 de, uint256 t) public view {
        e = bound(e, 0, s);
        uint256 amount = h.amountAt(s, e, ds, de, t);
        assertGe(amount, e);
        assertLe(amount, s);
    }

    function testFuzz_monotonicallyNonIncreasing(uint256 s, uint256 e, uint64 ds, uint64 de, uint64 t1, uint64 t2)
        public
        view
    {
        e = bound(e, 0, s);
        (uint64 early, uint64 late) = t1 <= t2 ? (t1, t2) : (t2, t1);
        assertGe(h.amountAt(s, e, ds, de, early), h.amountAt(s, e, ds, de, late));
    }

    /// @dev Differential against a straightforward full-precision reference (no mulDiv, bounded inputs).
    function testFuzz_matchesReference(uint128 s, uint128 e, uint32 ds, uint32 len, uint32 t) public view {
        e = uint128(bound(e, 0, s));
        uint256 de = uint256(ds) + len;
        uint256 expected;
        if (t <= ds || len == 0) expected = s;
        else if (t >= de) expected = e;
        else expected = s - (uint256(s - e) * (t - ds)) / len;
        assertEq(h.amountAt(s, e, ds, de, t), expected);
    }
}
