// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {OracleRouter} from "../../src/OracleRouter.sol";
import {IOracleRouter} from "../../src/interfaces/IOracleRouter.sol";
import {IPriceOracle} from "../../src/interfaces/IPriceOracle.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";
import {PriceMathHarness} from "../utils/Harnesses.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Decimal normalization over the whole supported range (0-36 decimals), checked against an independent
///         reference (`answer * 1e18 / 10^decimals` with a single 512-bit `mulDiv`) and against round-trip bounds.
contract NormalizationFuzzTest is Test {
    IPriceOracle.Intent internal constant C = IPriceOracle.Intent.Collateral;
    IPriceOracle.Intent internal constant D = IPriceOracle.Intent.Debt;

    PriceMathHarness internal math;

    function setUp() public {
        math = new PriceMathHarness();
    }

    /// @notice Up to 18 decimals normalization is exact and invertible; above 18 decimals collateral rounds down,
    ///         debt rounds up, they differ by at most one wei and the round-trip error is below one output unit.
    function testFuzz_RoundTripErrorBounds(uint256 answer, uint8 decimals) public view {
        decimals = uint8(bound(decimals, 0, 36));
        answer = bound(answer, 1, type(uint192).max);
        uint256 down = math.toWad(answer, decimals, C);
        uint256 up = math.toWad(answer, decimals, D);

        assertEq(down, Math.mulDiv(answer, 1e18, 10 ** decimals, Math.Rounding.Floor), "collateral = floor reference");
        assertEq(up, Math.mulDiv(answer, 1e18, 10 ** decimals, Math.Rounding.Ceil), "debt = ceil reference");
        assertLe(up - down, 1, "at most one wei apart");

        if (decimals <= 18) {
            uint256 scale = 10 ** (18 - decimals);
            assertEq(down, up, "exact below 19 decimals");
            assertEq(down / scale, answer, "invertible");
        } else {
            uint256 unit = 10 ** (decimals - 18);
            assertLe(down * unit, answer, "collateral never overvalued");
            assertGe(up * unit, answer, "debt never undervalued");
            assertLt(answer - down * unit, unit, "round-trip error below one wei");
            assertEq(up == down, answer % unit == 0, "rounds only when inexact");
        }
    }

    /// @notice The time-weighted average is rounded exactly once, in the caller's direction.
    /// @dev Domain: every averaged answer is below 2^192, so the sum over `period` seconds is below 2^192 * period.
    function testFuzz_AverageMatchesSingleMulDiv(uint256 sum, uint256 period, uint8 decimals) public view {
        decimals = uint8(bound(decimals, 0, 36));
        period = bound(period, 1, 1 days);
        sum = bound(sum, 0, uint256(type(uint192).max) * period);
        assertEq(
            math.averageToWad(sum, period, decimals, C),
            Math.mulDiv(sum, 1e18, period * 10 ** decimals, Math.Rounding.Floor)
        );
        assertEq(
            math.averageToWad(sum, period, decimals, D),
            Math.mulDiv(sum, 1e18, period * 10 ** decimals, Math.Rounding.Ceil)
        );
    }

    /// @notice Rounding the gap up makes "deviation > threshold" exactly the real-valued comparison.
    function testFuzz_DeviationThresholdIsExact(uint256 a, uint256 b, uint256 maxBps) public view {
        a = bound(a, 1, 2 ** 200);
        b = bound(b, 1, 2 ** 200);
        maxBps = bound(maxBps, 0, 10_000);
        (uint256 lo, uint256 hi) = a < b ? (a, b) : (b, a);
        bool exceeds = (hi - lo) * 10_000 > maxBps * lo;
        assertEq(math.deviationBps(a, b) > maxBps, exceeds);
        assertEq(math.deviationBps(a, b), math.deviationBps(b, a), "symmetric");
    }

    /// @notice End to end through the router: any decimals, any in-bounds answer, both intents.
    function testFuzz_RouterNormalizesEveryDecimals(uint8 decimals, uint256 answer) public {
        decimals = uint8(bound(decimals, 0, 36));
        uint192 minAnswer = decimals > 18 ? uint192(10 ** (decimals - 18)) : 1;
        answer = bound(answer, minAnswer, type(uint192).max);

        vm.warp(1_750_000_000);
        MockAggregatorV3 feed = new MockAggregatorV3(decimals, "fuzz");
        feed.pushAnswer(int256(answer));
        IOracleRouter.InitialAsset[] memory assets = new IOracleRouter.InitialAsset[](1);
        assets[0] = IOracleRouter.InitialAsset(
            address(1),
            IOracleRouter.AssetParams({
                primary: IOracleRouter.FeedParams(address(feed), 1 hours, minAnswer, type(uint192).max),
                secondary: IOracleRouter.FeedParams(address(0), 0, 0, 0),
                maxDeviationBps: 0,
                twapWindow: 0,
                mode: IOracleRouter.Mode.Strict
            })
        );
        OracleRouter router = new OracleRouter(address(new AccessManager(address(this))), address(0), 0, assets);

        (uint256 down, IPriceOracle.Status s1) = router.tryGetPrice(address(1), C);
        (uint256 up, IPriceOracle.Status s2) = router.tryGetPrice(address(1), D);
        assertEq(uint256(s1), uint256(IPriceOracle.Status.OK));
        assertEq(uint256(s2), uint256(IPriceOracle.Status.OK));
        assertEq(down, Math.mulDiv(answer, 1e18, 10 ** decimals, Math.Rounding.Floor));
        assertEq(up, Math.mulDiv(answer, 1e18, 10 ** decimals, Math.Rounding.Ceil));
        assertGt(down, 0, "a validated price is never zero");
    }
}
