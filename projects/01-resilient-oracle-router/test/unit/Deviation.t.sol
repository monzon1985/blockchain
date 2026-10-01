// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {OracleRouter} from "../../src/OracleRouter.sol";
import {IOracleRouter} from "../../src/interfaces/IOracleRouter.sol";
import {IPriceOracle} from "../../src/interfaces/IPriceOracle.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";
import {RouterTestBase} from "../utils/RouterTestBase.sol";

/// @notice The primary/secondary deviation breaker: exact threshold, strict revert, soft conservative side.
contract DeviationTest is RouterTestBase {
    /// @notice 3 % of $2,000 is $60: a secondary at exactly $2,060 is still within the threshold.
    function test_GapExactlyAtThreshold_IsOk() public {
        secondary.pushAnswer(2060e18);
        _assertQuoteBoth(strictRouter, 2000e18, IPriceOracle.Status.OK);
        _assertQuoteBoth(softRouter, 2000e18, IPriceOracle.Status.OK);
    }

    /// @notice One wei above the threshold trips the breaker (the deviation is rounded up, never down).
    function test_GapOneWeiOverThreshold_Trips() public {
        secondary.pushAnswer(2060e18 + 1);
        _assertQuoteBoth(strictRouter, 0, IPriceOracle.Status.DEVIATION);
        _expectGetPriceRevert(
            strictRouter,
            abi.encodeWithSelector(
                IOracleRouter.DeviationTooHigh.selector, ASSET, 2000e18, 2060e18 + 1, 301, MAX_DEVIATION_BPS
            )
        );
    }

    /// @notice The gap is measured against the lower price: $2,000 vs $1,941.75 is a 2.9999 % gap, $2,000 vs
    ///         $1,941.74 a 3.0004 % gap.
    function test_GapMeasuredAgainstLowerPrice() public {
        // 2000 / 1.03 = 1941.747..., so a secondary of 1941.75 is within 3 %...
        secondary.pushAnswer(1941.75e18);
        _assertQuoteBoth(strictRouter, 2000e18, IPriceOracle.Status.OK);
        // ...and one of 1941.74 is not.
        secondary.pushAnswer(1941.74e18);
        _assertQuoteBoth(strictRouter, 0, IPriceOracle.Status.DEVIATION);
    }

    function test_Soft_CollateralTakesTheLowerSide() public {
        secondary.pushAnswer(1800e18);
        _assertQuote(softRouter, COLLATERAL, 1800e18, IPriceOracle.Status.DEVIATION);
        _assertQuote(softRouter, DEBT, 2000e18, IPriceOracle.Status.DEVIATION);
        assertEq(softRouter.getPrice(ASSET, COLLATERAL), 1800e18);
        assertEq(softRouter.getPrice(ASSET, DEBT), 2000e18);
    }

    function test_Soft_DebtTakesTheHigherSide() public {
        secondary.pushAnswer(2400e18);
        _assertQuote(softRouter, COLLATERAL, 2000e18, IPriceOracle.Status.DEVIATION);
        _assertQuote(softRouter, DEBT, 2400e18, IPriceOracle.Status.DEVIATION);
    }

    function test_Strict_RevertCarriesBothPrices() public {
        secondary.pushAnswer(2400e18);
        _expectGetPriceRevert(
            strictRouter,
            abi.encodeWithSelector(
                IOracleRouter.DeviationTooHigh.selector, ASSET, 2000e18, 2400e18, 2000, MAX_DEVIATION_BPS
            )
        );
    }

    /// @notice Both intents see the same breaker decision, even when rounding the primary up would close the gap.
    /// @dev Primary 1e18 + 0.5 wei (floors to 1e18, ceils to 1e18 + 1); secondary exactly 1e18 + 1e14 + 1. Measured on
    ///      floored prices the gap is just over 1 bp; measured on ceiled prices it would be exactly 1 bp. A breaker
    ///      that compared intent-rounded prices would trip for `Collateral` and pass `Debt`.
    function test_DecisionIsIntentIndependent_ForHighDecimalFeeds() public {
        MockAggregatorV3 p27 = new MockAggregatorV3(27, "27-dec primary");
        MockAggregatorV3 s27 = new MockAggregatorV3(27, "27-dec secondary");
        IOracleRouter.AssetParams memory p = _params(IOracleRouter.Mode.Soft);
        p.primary = IOracleRouter.FeedParams(address(p27), 1 hours, 1e9, type(uint192).max);
        p.secondary = IOracleRouter.FeedParams(address(s27), 1 hours, 1e9, type(uint192).max);
        p.maxDeviationBps = 1;
        OracleRouter router = _deployRouter(p);
        p27.pushAnswer(1e27 + 5e8);
        s27.pushAnswer((1e18 + 1e14 + 1) * 1e9);
        // Soft mode: both intents trip and quote their conservative side.
        _assertQuote(router, COLLATERAL, 1e18, IPriceOracle.Status.DEVIATION);
        _assertQuote(router, DEBT, 1e18 + 1e14 + 1, IPriceOracle.Status.DEVIATION);
        // One wei less on the secondary and both intents pass.
        s27.pushAnswer((1e18 + 1e14) * 1e9);
        _assertQuote(router, COLLATERAL, 1e18, IPriceOracle.Status.OK);
        _assertQuote(router, DEBT, 1e18 + 1, IPriceOracle.Status.OK);
    }

    /// @notice A soft asset keeps pricing from the primary when the secondary cannot vote.
    function test_Soft_IgnoresADeadSecondary() public {
        secondary.setBehavior(MockAggregatorV3.Behavior.Revert);
        _assertQuoteBoth(softRouter, 2000e18, IPriceOracle.Status.OK);
        _assertQuoteBoth(strictRouter, 0, IPriceOracle.Status.STALE);
        _expectGetPriceRevert(
            strictRouter, abi.encodeWithSelector(IOracleRouter.FeedUnavailable.selector, address(secondary))
        );
    }

    /// @notice Without a secondary there is no breaker at all.
    function test_NoSecondary_NoBreaker() public {
        OracleRouter router = _deployRouter(_primaryOnlyParams(IOracleRouter.Mode.Strict));
        secondary.pushAnswer(1e18 * 50_000); // would trip a breaker; not consulted
        _assertQuoteBoth(router, 2000e18, IPriceOracle.Status.OK);
    }

    /// @notice An unhealthy primary is reported before the secondary is even read.
    function test_PrimaryFailureWinsOverSecondaryFailure() public {
        primary.pushAnswer(0);
        secondary.pushAnswer(-1);
        _assertQuoteBoth(strictRouter, 0, IPriceOracle.Status.ZERO);
        _assertQuoteBoth(softRouter, 0, IPriceOracle.Status.ZERO);
    }
}
