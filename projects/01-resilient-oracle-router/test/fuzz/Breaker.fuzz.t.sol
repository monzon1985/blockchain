// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {OracleRouter} from "../../src/OracleRouter.sol";
import {IOracleRouter} from "../../src/interfaces/IOracleRouter.sol";
import {IPriceOracle} from "../../src/interfaces/IPriceOracle.sol";
import {RouterTestBase} from "../utils/RouterTestBase.sol";

/// @notice The deviation breaker through the router, for arbitrary in-bounds prices and thresholds, in both modes.
contract BreakerFuzzTest is RouterTestBase {
    function testFuzz_BreakerMatchesReference(uint256 primaryAnswer, uint256 secondaryAnswer, uint16 maxBps) public {
        primaryAnswer = bound(primaryAnswer, PRIMARY_MIN, PRIMARY_MAX);
        secondaryAnswer = bound(secondaryAnswer, SECONDARY_MIN, SECONDARY_MAX);
        maxBps = uint16(bound(maxBps, 1, 10_000));

        IOracleRouter.AssetParams memory p = _params(IOracleRouter.Mode.Strict);
        p.maxDeviationBps = maxBps;
        OracleRouter strict = _deployRouter(p);
        p.mode = IOracleRouter.Mode.Soft;
        OracleRouter soft = _deployRouter(p);
        primary.pushAnswer(int256(primaryAnswer));
        secondary.pushAnswer(int256(secondaryAnswer));

        uint256 pw = primaryAnswer * 1e10; // 8 decimals -> 18, exact
        uint256 sw = secondaryAnswer; // 18 decimals, exact
        (uint256 lo, uint256 hi) = pw < sw ? (pw, sw) : (sw, pw);
        bool trips = (hi - lo) * 10_000 > uint256(maxBps) * lo;

        for (uint256 i; i < 2; ++i) {
            IPriceOracle.Intent intent = IPriceOracle.Intent(i);
            (uint256 sp, IPriceOracle.Status ss) = strict.tryGetPrice(ASSET, intent);
            (uint256 fp, IPriceOracle.Status fs) = soft.tryGetPrice(ASSET, intent);
            if (!trips) {
                assertEq(uint256(ss), uint256(IPriceOracle.Status.OK));
                assertEq(uint256(fs), uint256(IPriceOracle.Status.OK));
                assertEq(sp, pw);
                assertEq(fp, pw);
            } else {
                assertEq(uint256(ss), uint256(IPriceOracle.Status.DEVIATION));
                assertEq(uint256(fs), uint256(IPriceOracle.Status.DEVIATION));
                assertEq(sp, 0, "strict refuses");
                assertEq(fp, intent == COLLATERAL ? lo : hi, "soft quotes the conservative side");
            }
        }
    }

    /// @notice Debt is never priced below collateral, whatever the feeds say and whatever the mode.
    function testFuzz_DebtNeverBelowCollateral(uint256 primaryAnswer, uint256 secondaryAnswer, bool soft) public {
        primaryAnswer = bound(primaryAnswer, PRIMARY_MIN, PRIMARY_MAX);
        secondaryAnswer = bound(secondaryAnswer, SECONDARY_MIN, SECONDARY_MAX);
        primary.pushAnswer(int256(primaryAnswer));
        secondary.pushAnswer(int256(secondaryAnswer));
        OracleRouter router = soft ? softRouter : strictRouter;
        (uint256 c,) = router.tryGetPrice(ASSET, COLLATERAL);
        (uint256 d,) = router.tryGetPrice(ASSET, DEBT);
        assertGe(d, c);
    }
}
