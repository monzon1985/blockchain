// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";

import {Id, Market, MarketParams} from "../../src/interfaces/ILendingEngine.sol";
import {AdaptiveCurveIrm} from "../../src/irm/AdaptiveCurveIrm.sol";
import {MarketParamsLib} from "../../src/libraries/MarketParamsLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

contract AdaptiveCurveIrmTest is Test {
    using MarketParamsLib for MarketParams;

    AdaptiveCurveIrm internal irm;
    address internal engine = makeAddr("engine");
    MarketParams internal params;
    Id internal id;

    function setUp() public {
        irm = new AdaptiveCurveIrm(engine);
        params = MarketParams(makeAddr("loan"), makeAddr("coll"), makeAddr("oracle"), address(irm), 0.86e18);
        id = params.id();
        vm.warp(1_000_000);
    }

    function _market(uint256 supplyAssets, uint256 borrowAssets, uint256 lastUpdate)
        internal
        pure
        returns (Market memory m)
    {
        m.totalSupplyAssets = uint128(supplyAssets);
        m.totalBorrowAssets = uint128(borrowAssets);
        m.lastUpdate = uint128(lastUpdate);
    }

    function _call(Market memory m) internal returns (uint256) {
        vm.prank(engine);
        return irm.borrowRate(params, m);
    }

    function test_constructor_revertsOnZeroEngine() public {
        vm.expectRevert(AdaptiveCurveIrm.ZeroAddress.selector);
        new AdaptiveCurveIrm(address(0));
    }

    function test_onlyEngineMutates() public {
        vm.expectRevert(abi.encodeWithSelector(AdaptiveCurveIrm.NotEngine.selector, address(this)));
        irm.borrowRate(params, _market(100, 90, block.timestamp));
    }

    function test_firstCallInitializesAtTarget() public {
        uint256 rate = _call(_market(100e18, 90e18, block.timestamp));
        assertEq(rate, irm.INITIAL_RATE_AT_TARGET());
        assertEq(irm.rateAtTarget(id), irm.INITIAL_RATE_AT_TARGET());
    }

    function test_curveShape() public view {
        (int256 errZero, uint256 atZero) = irm.curveMultiplier(0);
        (int256 errTarget, uint256 atTarget) = irm.curveMultiplier(0.9e18);
        (int256 errFull, uint256 atFull) = irm.curveMultiplier(1e18);
        assertEq(errZero, -1e18);
        assertEq(errTarget, 0);
        assertEq(errFull, 1e18);
        assertEq(atZero, 0.25e18, "1/steepness at zero utilization");
        assertEq(atTarget, 1e18);
        assertEq(atFull, 4e18, "steepness at full utilization");
    }

    function test_curveIsMonotonicInUtilization(uint256 u1, uint256 u2) public view {
        u1 = bound(u1, 0, 1e18);
        u2 = bound(u2, u1, 1e18);
        (, uint256 m1) = irm.curveMultiplier(u1);
        (, uint256 m2) = irm.curveMultiplier(u2);
        assertLe(m1, m2);
    }

    function test_rateAtTargetRisesAboveTarget() public {
        _call(_market(100e18, 100e18, block.timestamp)); // init at 4 %
        skip(7 days);
        _call(_market(100e18, 100e18, block.timestamp - 7 days));
        // exp(50 * 7 / 365) = 2.608835...
        uint256 expected = irm.INITIAL_RATE_AT_TARGET() * 2_608_835_908_020_944_200 / 1e18;
        assertApproxEqRel(irm.rateAtTarget(id), expected, 0.0001e18);
    }

    function test_rateAtTargetFallsBelowTarget() public {
        _call(_market(100e18, 0, block.timestamp));
        skip(10 days);
        _call(_market(100e18, 0, block.timestamp - 10 days));
        // exp(-50 * 10 / 365) = 0.254141...
        uint256 expected = irm.INITIAL_RATE_AT_TARGET() * 254_141_771_109_640_600 / 1e18;
        assertApproxEqRel(irm.rateAtTarget(id), expected, 0.0001e18);
    }

    function test_rateAtTargetClampsToBounds() public {
        _call(_market(100e18, 100e18, block.timestamp));
        skip(3650 days);
        _call(_market(100e18, 100e18, block.timestamp - 3650 days));
        assertEq(irm.rateAtTarget(id), irm.MAX_RATE_AT_TARGET());

        skip(3650 days);
        _call(_market(100e18, 0, block.timestamp - 3650 days));
        assertEq(irm.rateAtTarget(id), irm.MIN_RATE_AT_TARGET());
    }

    function test_noAdaptationAtTarget() public {
        _call(_market(100e18, 90e18, block.timestamp));
        skip(365 days);
        uint256 rate = _call(_market(100e18, 90e18, block.timestamp - 365 days));
        assertEq(irm.rateAtTarget(id), irm.INITIAL_RATE_AT_TARGET());
        assertEq(rate, irm.INITIAL_RATE_AT_TARGET());
    }

    function test_viewMatchesMutatingCall(uint256 borrowAssets, uint256 elapsed) public {
        borrowAssets = bound(borrowAssets, 0, 100e18);
        elapsed = bound(elapsed, 0, 1000 days);
        _call(_market(100e18, 50e18, block.timestamp));
        skip(elapsed);
        Market memory m = _market(100e18, borrowAssets, block.timestamp - elapsed);
        uint256 viewRate = irm.borrowRateView(params, m);
        assertEq(_call(m), viewRate);
    }

    /// @notice Simpson's-rule average vs. the closed-form mean of r0 * e^(k t) over one idle week at full speed.
    function test_simpsonAverageWithinTenthOfAPercent() public {
        _call(_market(100e18, 100e18, block.timestamp)); // init at 4 %, err = +1
        uint256 elapsed = 7 days;
        skip(elapsed);
        uint256 avg = irm.borrowRateView(params, _market(100e18, 100e18, block.timestamp - elapsed));

        // Closed form: mean(r) = r0 * (e^x - 1) / x with x = speed * t; the curve multiplies by 4 at err = +1.
        int256 x = int256(irm.ADJUSTMENT_SPEED() * elapsed);
        uint256 growth = uint256(FixedPointMathLib.expWad(x));
        uint256 exactMeanAtTarget = irm.INITIAL_RATE_AT_TARGET() * (growth - 1e18) / uint256(x);
        assertApproxEqRel(avg, exactMeanAtTarget * 4, 0.001e18);
    }

    function test_zeroSupplyReadsAsZeroUtilization() public {
        uint256 rateEmpty = _call(_market(0, 0, block.timestamp));
        assertEq(rateEmpty, irm.INITIAL_RATE_AT_TARGET() / 4, "zero supply reads as zero utilization");
    }
}
