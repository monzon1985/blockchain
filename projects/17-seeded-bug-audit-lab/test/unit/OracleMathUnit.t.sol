// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { BaseTest } from "../BaseTest.sol";
import { PoolTwapOracle, IObservablePool } from "shared/PoolTwapOracle.sol";
import { FixedPointMath } from "kestrel/lib/FixedPointMath.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";

/// @notice Exposes the library's internal functions so reverts can be asserted.
contract MathHarness {
    function powWad(uint256 base, uint256 exp) external pure returns (uint256) {
        return FixedPointMath.powWad(base, exp);
    }

    function divWadUp(uint256 x, uint256 y) external pure returns (uint256) {
        return FixedPointMath.divWadUp(x, y);
    }

    function mulDivDown(uint256 x, uint256 y, uint256 d) external pure returns (uint256) {
        return FixedPointMath.mulDivDown(x, y, d);
    }

    function mulDivUp(uint256 x, uint256 y, uint256 d) external pure returns (uint256) {
        return FixedPointMath.mulDivUp(x, y, d);
    }

    function refDown(uint256 x, uint256 y, uint256 d) external pure returns (uint256) {
        return FixedPointMathLib.fullMulDiv(x, y, d);
    }

    function refUp(uint256 x, uint256 y, uint256 d) external pure returns (uint256) {
        return FixedPointMathLib.fullMulDivUp(x, y, d);
    }
}

/// @notice Unit tests for {PoolTwapOracle} and {FixedPointMath}.
contract OracleMathUnit is BaseTest {
    // --- oracle ---

    function test_oracle_constructorValidates() public {
        IObservablePool p = IObservablePool(address(pool));
        vm.expectRevert(abi.encodeWithSelector(PoolTwapOracle.InvalidConfig.selector, 0, 10, 10));
        new PoolTwapOracle(p, 0, 10, 10);
        vm.expectRevert(abi.encodeWithSelector(PoolTwapOracle.InvalidConfig.selector, 10, 9, 10));
        new PoolTwapOracle(p, 10, 9, 10);
        vm.expectRevert(abi.encodeWithSelector(PoolTwapOracle.InvalidConfig.selector, 10, 10, 9));
        new PoolTwapOracle(p, 10, 10, 9);
    }

    function test_oracle_noPriceBeforeFirstPublication() public {
        PoolTwapOracle o = new PoolTwapOracle(IObservablePool(address(pool)), 60, 120, 120);
        vm.expectRevert(PoolTwapOracle.NoPrice.selector);
        o.priceToken0In1();
    }

    function test_oracle_publishesTimeWeightedAverage() public {
        // Half of the window at price 1.0, half at the post-swap price.
        vm.warp(block.timestamp + TWAP_PERIOD / 2);
        _mintApprove(debt, bob, 1_000_000e18, address(pool));
        vm.prank(bob);
        pool.swap(address(debt), 1_000_000e18, 0, bob);
        uint256 spotAfter = pool.spotPrice0In1();
        vm.warp(block.timestamp + TWAP_PERIOD / 2);
        assertTrue(oracle.update());
        uint256 expected = (1e18 + spotAfter) / 2;
        assertApproxEqRel(oracle.priceToken0In1(), expected, 1e12, "mean of the two halves");
        assertEq(oracle.priceTimestamp(), block.timestamp);
    }

    function test_oracle_staleAndPeriodReverts() public {
        vm.warp(block.timestamp + TWAP_PERIOD - 1);
        vm.expectRevert(
            abi.encodeWithSelector(PoolTwapOracle.PeriodNotElapsed.selector, TWAP_PERIOD - 1, TWAP_PERIOD)
        );
        oracle.update();
        vm.warp(block.timestamp + TWAP_MAX_AGE);
        vm.expectRevert(
            abi.encodeWithSelector(
                PoolTwapOracle.StalePrice.selector, TWAP_MAX_AGE + TWAP_PERIOD - 1, TWAP_MAX_AGE
            )
        );
        oracle.priceToken0In1();
    }

    function test_oracle_discardsOverlongWindow() public {
        vm.warp(block.timestamp + TWAP_MAX_WINDOW + 1);
        uint256 publishedBefore = oracle.priceTimestamp();
        assertFalse(oracle.update(), "discarded");
        assertEq(oracle.priceTimestamp(), publishedBefore, "nothing published");
        assertEq(oracle.timestampLast(), block.timestamp, "re-anchored");
    }

    // --- math ---

    function test_math_wadHelpers() public {
        MathHarness h = new MathHarness();
        assertEq(FixedPointMath.mulWadDown(3e18, 0.5e18), 1.5e18);
        assertEq(FixedPointMath.mulWadUp(1, 1), 1);
        assertEq(FixedPointMath.divWadDown(1e18, 3e18), 333_333_333_333_333_333);
        assertEq(h.divWadUp(1e18, 3e18), 333_333_333_333_333_334);
        assertEq(FixedPointMath.mulDivUp(7, 1, 2), 4);
        assertApproxEqAbs(h.powWad(0.25e18, 0.5e18), 0.5e18, 1e3, "sqrt(0.25) == 0.5");
    }

    /// @dev Differential: the 128-bit fast path and the 512-bit fallback agree with Solady's
    ///      fullMulDiv for every input, including where Solady reverts (result overflow, d == 0).
    function testFuzz_math_mulDivMatchesSolady(uint256 x, uint256 y, uint256 d, bool small) public {
        MathHarness h = new MathHarness();
        if (small) {
            x = bound(x, 0, type(uint128).max);
            y = bound(y, 0, type(uint128).max);
            d = bound(d, 1, type(uint128).max);
        }
        // Where Solady reverts, the wrapper reverts too: with Solady's own error on the 512-bit
        // path, and with the compiler's division-by-zero / underflow panic on the fast path
        // (the only way the fast path can fail is d == 0).
        try h.refDown(x, y, d) returns (uint256 expected) {
            assertEq(h.mulDivDown(x, y, d), expected, "mulDivDown == fullMulDiv");
        } catch (bytes memory reason) {
            bool fast = (x | y) >> 128 == 0;
            vm.expectRevert(fast ? abi.encodeWithSignature("Panic(uint256)", 0x12) : reason);
            h.mulDivDown(x, y, d);
        }
        try h.refUp(x, y, d) returns (uint256 expected) {
            assertEq(h.mulDivUp(x, y, d), expected, "mulDivUp == fullMulDivUp");
        } catch (bytes memory reason) {
            bool fast = (x | y | d) >> 128 == 0;
            uint256 code = x == 0 || y == 0 ? 0x11 : 0x12; // 0 + d - 1 underflows when d == 0
            vm.expectRevert(fast ? abi.encodeWithSignature("Panic(uint256)", code) : reason);
            h.mulDivUp(x, y, d);
        }
    }

    function test_math_mulDivSlowPath() public {
        MathHarness h = new MathHarness();
        uint256 big = uint256(1) << 200;
        assertEq(h.mulDivDown(big, 3, 2), (big / 2) * 3, "512-bit path, round down");
        assertEq(h.mulDivUp(big + 1, 3, 2), ((big + 1) * 3 + 1) / 2, "512-bit path, round up");
    }

    function test_math_powWadRejectsHugeInputs() public {
        MathHarness h = new MathHarness();
        vm.expectRevert(FixedPointMath.PowInputTooLarge.selector);
        h.powWad(1 << 255, 1e18);
    }

    function test_math_checkedShlEdges() public pure {
        (uint256 r, bool o) = FixedPointMath.checkedShl(5, 0);
        assertEq(r, 5);
        assertFalse(o);
        (r, o) = FixedPointMath.checkedShl(1, 255);
        assertEq(r, 1 << 255);
        assertFalse(o);
        (r, o) = FixedPointMath.checkedShl(type(uint256).max, 1);
        assertTrue(o, "top bit lost");
    }
}
