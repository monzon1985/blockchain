// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";

import {StreamMath} from "../../../contracts/libraries/StreamMath.sol";
import {Milestone} from "../../../contracts/types/StreamTypes.sol";

/// @notice Unit and fuzz tests of the three vesting curves: exact values, bounds, monotonicity and the
/// round-down-against-the-recipient rule.
contract StreamMathTest is Test {
    /*//////////////////////////////////////////////////////////////
                                 LINEAR
    //////////////////////////////////////////////////////////////*/

    function test_linear_zeroBeforeStartAndBeforeCliff() public pure {
        assertEq(StreamMath.linear(1000, 100, 0, 200, 99), 0);
        assertEq(StreamMath.linear(1000, 100, 150, 200, 149), 0);
    }

    function test_linear_jumpsToTheLinearValueAtTheCliff() public pure {
        assertEq(StreamMath.linear(1000, 100, 150, 200, 150), 500);
    }

    function test_linear_fullDepositAtAndAfterEnd() public pure {
        assertEq(StreamMath.linear(1000, 100, 150, 200, 200), 1000);
        assertEq(StreamMath.linear(1000, 100, 150, 200, type(uint40).max), 1000);
    }

    function test_linear_roundsDown() public pure {
        // 10 * 1 / 3 = 3.33.. -> 3 ; 10 * 2 / 3 = 6.66.. -> 6
        assertEq(StreamMath.linear(10, 0, 0, 3, 1), 3);
        assertEq(StreamMath.linear(10, 0, 0, 3, 2), 6);
    }

    function test_linear_maxValuesDoNotOverflow() public pure {
        uint128 deposit = type(uint128).max;
        uint40 end = type(uint40).max;
        assertEq(StreamMath.linear(deposit, 1, 0, end, end - 1), uint128((uint256(deposit) * (end - 2)) / (end - 1)));
    }

    /// Bounded by the deposit, non-decreasing, and exactly the floor of the ideal value between cliff and end.
    function testFuzz_linear_boundedMonotonicFloor(
        uint128 deposit,
        uint40 start,
        uint40 duration,
        uint40 cliffOffset,
        uint40 t1,
        uint40 t2
    ) public pure {
        start = uint40(bound(start, 1, type(uint40).max / 2));
        duration = uint40(bound(duration, 1, type(uint40).max / 4));
        uint40 end = start + duration;
        uint40 cliff = cliffOffset % 2 == 0 || duration < 2 ? 0 : uint40(bound(cliffOffset, start + 1, end - 1));
        t1 = uint40(bound(t1, 0, end + 10));
        t2 = uint40(bound(t2, t1, end + 10));

        uint128 v1 = StreamMath.linear(deposit, start, cliff, end, t1);
        uint128 v2 = StreamMath.linear(deposit, start, cliff, end, t2);
        assertLe(v2, deposit, "exceeds deposit");
        assertLe(v1, v2, "not monotonic");

        if (t1 >= start && t1 >= cliff && t1 < end) {
            uint256 ideal = uint256(deposit) * (t1 - start);
            uint256 span = end - start;
            assertLe(uint256(v1) * span, ideal, "rounded up");
            assertGt((uint256(v1) + 1) * span, ideal, "rounded down by more than one unit");
        }
    }

    /*//////////////////////////////////////////////////////////////
                                TRANCHED
    //////////////////////////////////////////////////////////////*/

    function test_tranched_stepFunction() public pure {
        Milestone[] memory m = new Milestone[](3);
        m[0] = Milestone(100, 10);
        m[1] = Milestone(0, 20);
        m[2] = Milestone(300, 30);
        assertEq(StreamMath.tranched(m, 9), 0);
        assertEq(StreamMath.tranched(m, 10), 100);
        assertEq(StreamMath.tranched(m, 29), 100);
        assertEq(StreamMath.tranched(m, 30), 400);
        assertEq(StreamMath.tranched(m, 1000), 400);
    }

    /// The tranched amount is exactly the sum of tranches whose timestamp has passed.
    function testFuzz_tranched_exactSumOfPastTranches(bytes32 seed, uint8 count, uint40 t) public pure {
        Milestone[] memory m = _randomMilestones(seed, bound(count, 1, 32), 1000);
        uint256 expected;
        for (uint256 i; i < m.length; ++i) {
            if (m[i].timestamp <= t) expected += m[i].amount;
        }
        assertEq(StreamMath.tranched(m, t), expected);
    }

    /*//////////////////////////////////////////////////////////////
                                SEGMENTED
    //////////////////////////////////////////////////////////////*/

    function test_segmented_interpolatesAndPlateaus() public pure {
        Milestone[] memory m = new Milestone[](3);
        m[0] = Milestone(1000, 200); // ramp from start=100 to 200
        m[1] = Milestone(0, 300); // plateau
        m[2] = Milestone(3000, 600); // ramp
        assertEq(StreamMath.segmented(m, 100, 100), 0);
        assertEq(StreamMath.segmented(m, 100, 150), 500);
        assertEq(StreamMath.segmented(m, 100, 200), 1000);
        assertEq(StreamMath.segmented(m, 100, 250), 1000);
        assertEq(StreamMath.segmented(m, 100, 300), 1000);
        assertEq(StreamMath.segmented(m, 100, 301), 1010);
        assertEq(StreamMath.segmented(m, 100, 599), 3990);
        assertEq(StreamMath.segmented(m, 100, 600), 4000);
    }

    function test_segmented_roundsDownInsideASegment() public pure {
        Milestone[] memory m = new Milestone[](1);
        m[0] = Milestone(10, 3);
        assertEq(StreamMath.segmented(m, 0, 1), 3);
        assertEq(StreamMath.segmented(m, 0, 2), 6);
    }

    /// Bounded by the sum, non-decreasing, equal to the cumulative sum at every milestone, and the floor of the
    /// ideal interpolation inside the active segment.
    function testFuzz_segmented_properties(bytes32 seed, uint8 count, uint40 t1, uint40 t2) public pure {
        uint40 start = 1000;
        Milestone[] memory m = _randomMilestones(seed, bound(count, 1, 16), start);
        uint40 end = m[m.length - 1].timestamp;
        t1 = uint40(bound(t1, 0, end + 10));
        t2 = uint40(bound(t2, t1, end + 10));

        uint256 total;
        uint256 cumulative;
        uint40 previous = start;
        for (uint256 i; i < m.length; ++i) {
            total += m[i].amount;
        }
        uint128 v1 = StreamMath.segmented(m, start, t1);
        assertLe(v1, StreamMath.segmented(m, start, t2), "not monotonic");
        assertLe(StreamMath.segmented(m, start, t2), total, "exceeds total");

        for (uint256 i; i < m.length; ++i) {
            if (t1 > previous && t1 < m[i].timestamp) {
                uint256 span = m[i].timestamp - previous;
                uint256 ideal = cumulative * span + uint256(m[i].amount) * (t1 - previous);
                assertLe(uint256(v1) * span, ideal, "rounded up");
                assertGt((uint256(v1) + 1) * span, ideal, "rounded down by more than one unit");
            }
            cumulative += m[i].amount;
            assertEq(StreamMath.segmented(m, start, m[i].timestamp), cumulative, "discontinuity at milestone");
            previous = m[i].timestamp;
        }
    }

    /// The milestone generator behind the two fuzz tests above reaches amounts near `type(uint128).max` as well as
    /// small ones, and never produces a total that would not fit in a deposit.
    function test_randomMilestones_spanTheUint128Range() public pure {
        uint256 largest;
        uint256 smallestNonZero = type(uint256).max;
        for (uint256 s; s < 64; ++s) {
            Milestone[] memory m = _randomMilestones(bytes32(s), 1 + (s % 32), 1000);
            uint256 total;
            for (uint256 i; i < m.length; ++i) {
                total += m[i].amount;
                if (m[i].amount > largest) largest = m[i].amount;
                if (m[i].amount != 0 && m[i].amount < smallestNonZero) smallestNonZero = m[i].amount;
            }
            assertLe(total, type(uint128).max, "total exceeds a uint128 deposit");
        }
        assertGt(largest, type(uint128).max / 2, "no amount in the top half of uint128");
        assertLt(smallestNonZero, 2 ** 64, "no small amount");
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Strictly increasing timestamps after `start`. Amounts span the whole uint128 range: each has a random
    /// bit length from 1 to 128 (one in seven is zero), and is capped by what is left of a `type(uint128).max` budget,
    /// so the total stays a valid deposit, as `_validateMilestones` requires.
    function _randomMilestones(bytes32 seed, uint256 count, uint40 start) internal pure returns (Milestone[] memory m) {
        m = new Milestone[](count);
        uint40 t = start;
        uint256 budget = type(uint128).max;
        for (uint256 i; i < count; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            t += uint40(1 + (r % 400 days));
            uint256 amount = 0;
            if ((r >> 64) % 7 != 0) {
                uint256 bits = 1 + ((r >> 72) % 128);
                amount = uint256(keccak256(abi.encode(seed, i, "amount"))) & ((1 << bits) - 1);
                if (amount > budget) amount = budget;
            }
            budget -= amount;
            m[i] = Milestone(uint128(amount), t);
        }
    }
}
