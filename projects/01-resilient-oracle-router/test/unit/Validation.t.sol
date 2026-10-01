// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {OracleRouter} from "../../src/OracleRouter.sol";
import {IOracleRouter} from "../../src/interfaces/IOracleRouter.sol";
import {IPriceOracle} from "../../src/interfaces/IPriceOracle.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";
import {RouterTestBase} from "../utils/RouterTestBase.sol";

/// @notice The feed-validation pipeline, one table row per failure mode, for the primary and for the secondary.
///         Neither router has TWAP history here, so soft mode cannot fall back and both modes must fail identically
///         on a bad primary (fallbacks are covered in TwapFallback.t.sol and the failure matrix).
contract ValidationTest is RouterTestBase {
    enum Corruption {
        Stale,
        Zero,
        Negative,
        MissingTimestamp,
        FutureTimestamp,
        CarriedOverRound,
        BelowMin,
        AboveMax,
        Reverts,
        ShortReturn
    }

    struct ValidationCase {
        string name;
        Corruption corruption;
        IPriceOracle.Status status;
        bytes4 selector;
    }

    function fixtureValidation() public pure returns (ValidationCase[] memory cases) {
        cases = new ValidationCase[](10);
        cases[0] =
            ValidationCase("stale", Corruption.Stale, IPriceOracle.Status.STALE, IOracleRouter.StalePrice.selector);
        cases[1] = ValidationCase("zero", Corruption.Zero, IPriceOracle.Status.ZERO, IOracleRouter.ZeroAnswer.selector);
        cases[2] = ValidationCase(
            "negative", Corruption.Negative, IPriceOracle.Status.NEGATIVE, IOracleRouter.NegativeAnswer.selector
        );
        cases[3] = ValidationCase(
            "missing timestamp",
            Corruption.MissingTimestamp,
            IPriceOracle.Status.STALE,
            IOracleRouter.MissingTimestamp.selector
        );
        cases[4] = ValidationCase(
            "future timestamp",
            Corruption.FutureTimestamp,
            IPriceOracle.Status.STALE,
            IOracleRouter.FutureTimestamp.selector
        );
        cases[5] = ValidationCase(
            "carried-over round",
            Corruption.CarriedOverRound,
            IPriceOracle.Status.STALE,
            IOracleRouter.StaleRound.selector
        );
        cases[6] = ValidationCase(
            "below min",
            Corruption.BelowMin,
            IPriceOracle.Status.OUT_OF_BOUNDS,
            IOracleRouter.AnswerOutOfBounds.selector
        );
        cases[7] = ValidationCase(
            "above max",
            Corruption.AboveMax,
            IPriceOracle.Status.OUT_OF_BOUNDS,
            IOracleRouter.AnswerOutOfBounds.selector
        );
        cases[8] = ValidationCase(
            "reverts", Corruption.Reverts, IPriceOracle.Status.STALE, IOracleRouter.FeedUnavailable.selector
        );
        cases[9] = ValidationCase(
            "short return", Corruption.ShortReturn, IPriceOracle.Status.STALE, IOracleRouter.FeedUnavailable.selector
        );
    }

    /// @notice A bad primary fails both modes with the documented status, a zero price and the matching error.
    function tableValidationTest(ValidationCase memory validation) public {
        _corrupt(primary, validation.corruption, PRIMARY_MIN, PRIMARY_MAX);
        _assertFailure(strictRouter, validation);
        _assertFailure(softRouter, validation);
    }

    /// @notice A bad secondary fails a strict asset with the secondary's status, and is ignored by a soft asset.
    /// @dev Foundry binds a table test's fixture by parameter name, so this table runs the same ten rows
    ///      (`fixtureValidation`) against the secondary.
    function tableSecondaryTest(ValidationCase memory validation) public {
        _corrupt(secondary, validation.corruption, SECONDARY_MIN, SECONDARY_MAX);
        _assertFailure(strictRouter, validation);
        _assertQuoteBoth(softRouter, _wad8(PRIMARY_PRICE), IPriceOracle.Status.OK);
        assertEq(softRouter.getPrice(ASSET, COLLATERAL), _wad8(PRIMARY_PRICE));
    }

    // ------------------------------------------------------------------------------------------------------------
    // Exact revert arguments
    // ------------------------------------------------------------------------------------------------------------

    function test_Healthy_ReturnsNormalizedPrimary() public view {
        _assertQuoteBoth(strictRouter, 2000e18, IPriceOracle.Status.OK);
        _assertQuoteBoth(softRouter, 2000e18, IPriceOracle.Status.OK);
        assertEq(strictRouter.getPrice(ASSET, COLLATERAL), 2000e18);
        assertEq(strictRouter.getPrice(ASSET, DEBT), 2000e18);
    }

    function test_StalePrice_CarriesUpdatedAtAgeAndHeartbeat() public {
        primary.pushAnswerWithAge(PRIMARY_PRICE, PRIMARY_HEARTBEAT + 1);
        _expectGetPriceRevert(
            strictRouter,
            abi.encodeWithSelector(
                IOracleRouter.StalePrice.selector,
                address(primary),
                T0 - PRIMARY_HEARTBEAT - 1,
                PRIMARY_HEARTBEAT + 1,
                PRIMARY_HEARTBEAT
            )
        );
    }

    function test_ZeroAnswer_CarriesRoundId() public {
        uint80 roundId = primary.pushAnswer(0);
        _expectGetPriceRevert(
            strictRouter, abi.encodeWithSelector(IOracleRouter.ZeroAnswer.selector, address(primary), roundId)
        );
    }

    function test_NegativeAnswer_CarriesAnswer() public {
        primary.pushAnswer(-5e8);
        _expectGetPriceRevert(
            strictRouter, abi.encodeWithSelector(IOracleRouter.NegativeAnswer.selector, address(primary), int256(-5e8))
        );
    }

    function test_MissingTimestamp_CarriesRoundId() public {
        uint80 roundId = primary.pushIncompleteRound(PRIMARY_PRICE);
        _expectGetPriceRevert(
            strictRouter, abi.encodeWithSelector(IOracleRouter.MissingTimestamp.selector, address(primary), roundId)
        );
    }

    function test_FutureTimestamp_CarriesBothTimes() public {
        primary.pushFutureAnswer(PRIMARY_PRICE, 30);
        _expectGetPriceRevert(
            strictRouter, abi.encodeWithSelector(IOracleRouter.FutureTimestamp.selector, address(primary), T0 + 30, T0)
        );
    }

    function test_StaleRound_CarriesRoundIds() public {
        uint80 roundId = primary.pushCarriedOverRound(PRIMARY_PRICE);
        _expectGetPriceRevert(
            strictRouter,
            abi.encodeWithSelector(IOracleRouter.StaleRound.selector, address(primary), roundId, roundId - 1)
        );
    }

    function test_AnswerOutOfBounds_CarriesAnswerAndBounds() public {
        primary.pushAnswer(99e8);
        _expectGetPriceRevert(
            strictRouter,
            abi.encodeWithSelector(
                IOracleRouter.AnswerOutOfBounds.selector, address(primary), int256(99e8), PRIMARY_MIN, PRIMARY_MAX
            )
        );
    }

    function test_FeedUnavailable_CarriesFeed() public {
        primary.setBehavior(MockAggregatorV3.Behavior.Revert);
        _expectGetPriceRevert(
            strictRouter, abi.encodeWithSelector(IOracleRouter.FeedUnavailable.selector, address(primary))
        );
    }

    // ------------------------------------------------------------------------------------------------------------
    // Boundaries
    // ------------------------------------------------------------------------------------------------------------

    function test_AgeEqualToHeartbeat_IsFresh() public {
        primary.pushAnswerWithAge(PRIMARY_PRICE, PRIMARY_HEARTBEAT);
        _assertQuoteBoth(strictRouter, 2000e18, IPriceOracle.Status.OK);
    }

    function test_AgeOneSecondOverHeartbeat_IsStale() public {
        primary.pushAnswerWithAge(PRIMARY_PRICE, PRIMARY_HEARTBEAT);
        vm.warp(block.timestamp + 1);
        _assertQuoteBoth(strictRouter, 0, IPriceOracle.Status.STALE);
    }

    function test_UpdatedAtEqualToNow_IsFresh() public {
        primary.pushAnswer(PRIMARY_PRICE);
        _assertQuoteBoth(strictRouter, 2000e18, IPriceOracle.Status.OK);
    }

    function test_AnswerAtBounds_IsAccepted() public {
        primary.pushAnswer(int256(uint256(PRIMARY_MIN)));
        secondary.pushAnswer(int256(uint256(PRIMARY_MIN)) * 1e10);
        _assertQuoteBoth(strictRouter, 100e18, IPriceOracle.Status.OK);
        primary.pushAnswer(int256(uint256(PRIMARY_MAX)));
        secondary.pushAnswer(int256(uint256(PRIMARY_MAX)) * 1e10);
        _assertQuoteBoth(strictRouter, 100_000e18, IPriceOracle.Status.OK);
    }

    function test_AnswerOneOutsideBounds_IsRejected() public {
        primary.pushAnswer(int256(uint256(PRIMARY_MIN)) - 1);
        _assertQuoteBoth(strictRouter, 0, IPriceOracle.Status.OUT_OF_BOUNDS);
        primary.pushAnswer(int256(uint256(PRIMARY_MAX)) + 1);
        _assertQuoteBoth(strictRouter, 0, IPriceOracle.Status.OUT_OF_BOUNDS);
    }

    function test_AnsweredInRoundAheadOfRoundId_IsAccepted() public {
        primary.pushRound(PRIMARY_PRICE, block.timestamp, block.timestamp, type(uint80).max);
        _assertQuoteBoth(strictRouter, 2000e18, IPriceOracle.Status.OK);
    }

    /// @notice The first failing check wins: a zero answer that is also stale reports ZERO, not STALE.
    function test_ChecksRunInDocumentedOrder() public {
        primary.pushAnswerWithAge(0, 10 days);
        _assertQuoteBoth(strictRouter, 0, IPriceOracle.Status.ZERO);
        primary.pushRound(-1, 0, 0, 0);
        _assertQuoteBoth(strictRouter, 0, IPriceOracle.Status.NEGATIVE);
        primary.pushRound(1, 0, 0, 0);
        _assertQuoteBoth(strictRouter, 0, IPriceOracle.Status.STALE);
        vm.expectRevert(abi.encodeWithSelector(IOracleRouter.MissingTimestamp.selector, address(primary), 4));
        strictRouter.getPrice(ASSET, COLLATERAL);
    }

    function test_FeedWithoutCode_IsUnavailable() public {
        IOracleRouter.AssetParams memory p = _primaryOnlyParams(IOracleRouter.Mode.Strict);
        OracleRouter router = _deployRouter(p);
        // Code can only be removed from a deployed feed through a state override.
        vm.etch(address(primary), "");
        _assertQuoteBoth(router, 0, IPriceOracle.Status.STALE);
        _expectGetPriceRevert(router, abi.encodeWithSelector(IOracleRouter.FeedUnavailable.selector, address(primary)));
    }

    function test_UnconfiguredAsset_RevertsEvenInTryGetPrice() public {
        vm.expectRevert(abi.encodeWithSelector(IOracleRouter.AssetNotConfigured.selector, address(0xBEEF)));
        strictRouter.tryGetPrice(address(0xBEEF), COLLATERAL);
        vm.expectRevert(abi.encodeWithSelector(IOracleRouter.AssetNotConfigured.selector, address(0xBEEF)));
        strictRouter.getPrice(address(0xBEEF), COLLATERAL);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------------------------------------------------

    function _corrupt(MockAggregatorV3 feed, Corruption corruption, uint192 minAnswer, uint192 maxAnswer) internal {
        int256 healthy = int256(uint256(minAnswer)) * 20;
        if (corruption == Corruption.Stale) feed.pushAnswerWithAge(healthy, 3 days);
        else if (corruption == Corruption.Zero) feed.pushAnswer(0);
        else if (corruption == Corruption.Negative) feed.pushAnswer(-healthy);
        else if (corruption == Corruption.MissingTimestamp) feed.pushIncompleteRound(healthy);
        else if (corruption == Corruption.FutureTimestamp) feed.pushFutureAnswer(healthy, 1);
        else if (corruption == Corruption.CarriedOverRound) feed.pushCarriedOverRound(healthy);
        else if (corruption == Corruption.BelowMin) feed.pushAnswer(int256(uint256(minAnswer)) - 1);
        else if (corruption == Corruption.AboveMax) feed.pushAnswer(int256(uint256(maxAnswer)) + 1);
        else if (corruption == Corruption.Reverts) feed.setBehavior(MockAggregatorV3.Behavior.Revert);
        else feed.setBehavior(MockAggregatorV3.Behavior.ShortReturn);
    }

    function _assertFailure(OracleRouter router, ValidationCase memory validation) internal {
        _assertQuoteBoth(router, 0, validation.status);
        for (uint256 i; i < 2; ++i) {
            try router.getPrice(ASSET, IPriceOracle.Intent(i)) returns (uint256) {
                fail(string.concat(validation.name, ": getPrice did not revert"));
            } catch (bytes memory reason) {
                assertEq(bytes4(reason), validation.selector, validation.name);
            }
        }
    }
}
