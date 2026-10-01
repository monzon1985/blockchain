// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";

import {LiquidationMath} from "../../src/libraries/LiquidationMath.sol";
import {WAD} from "../../src/libraries/MathLib.sol";

/// @notice Halmos proofs about the reverse-Dutch bonus schedule, `LiquidationMath.liquidationBonus`, on the real
///         bit-vector semantics (no arithmetic assumptions). Health factors range over every `uint64` (the engine
///         prices a bonus only below 1e18) and caps and slopes over every `uint96` (`enableLltv` accepts at most
///         0.25e18 and 20e18).
/// @dev Scope, stated plainly: property 4 holds for every input. Property 5 (monotonic in the deficit) is proved here
///      for the 1x slope only: with a slope of 2x, 4x or 20x (or a symbolic one) the solver has to bit-blast a 256-bit
///      division of a non-trivial product, and each query times out after 5 minutes (10 with a symbolic slope).
///      Monotonicity for arbitrary slopes is fuzzed (`testFuzz_bonusMonotonicInDeficit`, Rust proptest
///      `bonus_monotonic`), not proved. Run with `halmos --match-contract LiquidationBonusSymbolic`.
contract LiquidationBonusSymbolic is Test {
    /// Property 4: the bonus never exceeds its cap, and a healthy position (health >= 1) gets none.
    function check_bonusCappedAndZeroWhenHealthy(uint64 health, uint96 maxBonus, uint96 slope) public pure {
        uint256 bonus = LiquidationMath.liquidationBonus(health, maxBonus, slope);
        assert(bonus <= maxBonus);
        if (health >= WAD) assert(bonus == 0);
    }

    /// Property 5 (1x slope): a less healthy position never gets a smaller bonus, for every cap.
    function check_bonusMonotonicInDeficit_slope1x(uint64 healthier, uint64 sicker, uint96 maxBonus) public pure {
        vm.assume(sicker <= healthier);
        assert(
            LiquidationMath.liquidationBonus(sicker, maxBonus, 1e18)
                >= LiquidationMath.liquidationBonus(healthier, maxBonus, 1e18)
        );
    }
}
