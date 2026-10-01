// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {OracleRouter} from "../../src/OracleRouter.sol";
import {IOracleRouter} from "../../src/interfaces/IOracleRouter.sol";
import {IPriceOracle} from "../../src/interfaces/IPriceOracle.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";
import {RouterTestBase} from "../utils/RouterTestBase.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title FailureMatrixTest
/// @notice The README's failure-mode tables are executable. Two layers:
///         1. One hand-written test per cell (`test_Matrix_*`, `test_Death_*`) with fully typed expectations: exact
///            custom-error arguments, statuses and prices derived by hand from the scenario.
///         2. `test_Readme*IsExecutable` reads README.md, parses every row between the table markers, replays the
///            row's scenario in the cell's mode, and checks the documented outcome against the router with an
///            independent reference model (spot, TWAP and conservative prices recomputed from the mocks and a ghost
///            log of observations). It then calls the test named in the cell, by selector, and requires it to exist
///            and pass. It also requires the failure-mode table to list exactly the seven failure statuses.
///         Changing the behavior breaks layer 1; editing a README cell without changing the behavior breaks layer 2.
/// @dev Scenario world (see `setUp`): the primary answers 2000 + 10k USD at T0 + 10k min (k = 0..9) with the
///      secondary following, keepers record at every update and at T0 + 100/110/120 min, and "now" is T0 + 121 min.
///      The TWAP over [T0 + 60, T0 + 120] is (2060*10 + 2070*10 + 2080*10 + 2090*30) / 60 = 2080 USD; spot is 2090 USD.
contract FailureMatrixTest is RouterTestBase {
    uint256 internal constant LAST_UPDATE = T0 + 90 minutes;
    uint256 internal constant NOW = T0 + 121 minutes;
    uint80 internal constant LAST_ROUND = 11;

    string internal constant FAILURE_BEGIN = "<!-- failure-matrix:begin -->";
    string internal constant FAILURE_END = "<!-- failure-matrix:end -->";
    string internal constant DEATH_BEGIN = "<!-- feed-death-matrix:begin -->";
    string internal constant DEATH_END = "<!-- feed-death-matrix:end -->";

    /// @dev Ghost log of the observations accepted by the soft router (the TWAP reference is computed from it), with
    ///      the sequencer's `startedAt` at the time of each observation.
    uint256[] internal ghostTimes;
    uint256[] internal ghostAnswers;
    uint256[] internal ghostUpSince;

    function setUp() public override {
        super.setUp();
        for (uint256 k = 0; k <= 9; ++k) {
            vm.warp(T0 + k * 10 minutes);
            int256 answer = 2000e8 + int256(k) * 10e8;
            primary.pushAnswer(answer);
            secondary.pushAnswer(answer * 1e10);
            _observe();
        }
        for (uint256 m = 100; m <= 120; m += 10) {
            vm.warp(T0 + m * 1 minutes);
            _observe();
        }
        vm.warp(NOW);
    }

    // ============================================================================================================
    // Layer 2: the README is the specification
    // ============================================================================================================

    function test_ReadmeFailureMatrixIsExecutable() public {
        string[] memory keys = _checkTable(FAILURE_BEGIN, FAILURE_END);
        // The failure-mode table lists exactly the seven failure statuses, in enum order.
        assertEq(keys.length, 7, "seven failure modes");
        for (uint256 i; i < keys.length; ++i) {
            assertEq(keys[i], _statusName(IPriceOracle.Status(i + 1)), "row order follows the Status enum");
        }
    }

    function test_ReadmeFeedDeathMatrixIsExecutable() public {
        string[] memory keys = _checkTable(DEATH_BEGIN, DEATH_END);
        assertEq(keys.length, 13, "thirteen feed-death scenarios");
    }

    /// @dev Parses one table and checks every cell. Returns the row keys in order.
    function _checkTable(string memory beginMarker, string memory endMarker) internal returns (string[] memory keys) {
        string memory readme = vm.readFile("README.md");
        string[] memory afterBegin = vm.split(readme, beginMarker);
        assertEq(afterBegin.length, 2, "begin marker appears once");
        string[] memory block_ = vm.split(afterBegin[1], endMarker);
        assertGe(block_.length, 2, "end marker present");
        string[] memory lines = vm.split(block_[0], "\n");

        keys = new string[](lines.length);
        uint256 rows;
        for (uint256 i; i < lines.length; ++i) {
            string memory line = vm.trim(lines[i]);
            if (!_isDataRow(line)) continue;
            string[] memory cells = vm.split(line, "|");
            assertEq(cells.length, 7, string.concat("five columns: ", line));
            string memory key = vm.replace(vm.trim(cells[2]), "`", "");
            for (uint256 j; j < rows; ++j) {
                assertTrue(keccak256(bytes(keys[j])) != keccak256(bytes(key)), string.concat("duplicate ", key));
            }
            keys[rows++] = key;
            _checkCell(key, IOracleRouter.Mode.Strict, cells[4]);
            _checkCell(key, IOracleRouter.Mode.Soft, cells[5]);
        }
        // Shrink the array to the rows found.
        assembly ("memory-safe") {
            mstore(keys, rows)
        }
    }

    /// @dev Checks one documented cell: `reverts|returns <Token> -> (<Price>, <Status>) · <test name>`.
    function _checkCell(string memory key, IOracleRouter.Mode mode, string memory cell) internal {
        string[] memory parts = vm.split(cell, "`");
        assertGe(parts.length, 6, string.concat("cell grammar: ", cell));
        string memory verb = vm.trim(parts[0]);
        string memory getToken = parts[1];
        string[] memory tuple = vm.split(vm.replace(vm.replace(parts[3], "(", ""), ")", ""), ", ");
        assertEq(tuple.length, 2, string.concat("tuple grammar: ", parts[3]));
        string memory testName = parts[5];
        string memory where = string.concat(key, mode == IOracleRouter.Mode.Strict ? " / strict: " : " / soft: ");

        uint256 snapshot = vm.snapshotState();
        _scenario(key);
        OracleRouter router = _router(mode);
        for (uint256 k; k < 2; ++k) {
            IPriceOracle.Intent intent = IPriceOracle.Intent(k);
            (uint256 price, IPriceOracle.Status status) = router.tryGetPrice(ASSET, intent);
            assertEq(_statusName(status), tuple[1], string.concat(where, "status"));
            assertEq(price, _reference(tuple[0], intent), string.concat(where, "tryGetPrice price"));

            if (_eq(verb, "reverts")) {
                assertEq(tuple[0], "0", string.concat(where, "a revert pairs with a zero price"));
                try router.getPrice(ASSET, intent) returns (uint256) {
                    fail(string.concat(where, "getPrice should revert"));
                } catch (bytes memory reason) {
                    assertEq(bytes4(reason), _errorSelector(getToken), string.concat(where, "revert error"));
                }
            } else {
                assertEq(verb, "returns", string.concat(where, "verb"));
                assertEq(getToken, tuple[0], string.concat(where, "getPrice and tryGetPrice agree"));
                assertEq(router.getPrice(ASSET, intent), _reference(getToken, intent), string.concat(where, "getPrice"));
            }
        }
        vm.revertToState(snapshot);

        // The named test must exist and pass from the same starting state.
        (bool ok,) = address(this).call(abi.encodeWithSignature(string.concat(testName, "()")));
        assertTrue(ok, string.concat(where, "named test missing or failing: ", testName));
        vm.revertToState(snapshot);
    }

    function _isDataRow(string memory line) internal pure returns (bool) {
        bytes memory b = bytes(line);
        return b.length > 3 && b[0] == "|" && b[1] == " " && b[2] >= "0" && b[2] <= "9";
    }

    // ============================================================================================================
    // Scenarios (shared by both layers)
    // ============================================================================================================

    function _scenario(string memory key) internal {
        if (_eq(key, "STALE")) {
            vm.warp(T0 + 151 minutes);
        } else if (_eq(key, "ZERO")) {
            primary.pushAnswer(0);
        } else if (_eq(key, "NEGATIVE")) {
            primary.pushAnswer(-2090e8);
        } else if (_eq(key, "OUT_OF_BOUNDS")) {
            primary.pushAnswer(99e8);
        } else if (_eq(key, "SEQUENCER_DOWN")) {
            sequencer.setDown();
        } else if (_eq(key, "GRACE_PERIOD")) {
            sequencer.setDown();
            vm.warp(NOW + 10 minutes);
            sequencer.setUp();
            vm.warp(NOW + 20 minutes);
        } else if (_eq(key, "DEVIATION")) {
            secondary.pushAnswer(1881e18);
        } else if (_eq(key, "SECONDARY_DEAD")) {
            secondary.setBehavior(MockAggregatorV3.Behavior.Revert);
        } else if (_eq(key, "SECONDARY_STALE")) {
            secondary.pushAnswerWithAge(2090e18, SECONDARY_HEARTBEAT + 1);
        } else if (_eq(key, "PRIMARY_REVERTS")) {
            primary.setBehavior(MockAggregatorV3.Behavior.Revert);
        } else if (_eq(key, "PRIMARY_MALFORMED")) {
            primary.setBehavior(MockAggregatorV3.Behavior.ShortReturn);
        } else if (_eq(key, "MISSING_TIMESTAMP")) {
            primary.pushIncompleteRound(2090e8);
        } else if (_eq(key, "FUTURE_TIMESTAMP")) {
            primary.pushFutureAnswer(2090e8, 60);
        } else if (_eq(key, "CARRIED_OVER_ROUND")) {
            primary.pushCarriedOverRound(2090e8);
        } else if (_eq(key, "TWAP_TOO_SHORT")) {
            // Fresh routers: keepers only started 30 minutes before the primary went silent for good.
            strictRouter = _deployRouter(_params(IOracleRouter.Mode.Strict));
            softRouter = _deployRouter(_params(IOracleRouter.Mode.Soft));
            delete ghostTimes;
            delete ghostAnswers;
            delete ghostUpSince;
            for (uint256 m = 121; m <= 141; m += 10) {
                vm.warp(T0 + m * 1 minutes);
                _observe();
            }
            vm.warp(T0 + 151 minutes);
        } else if (_eq(key, "TWAP_EXPIRED")) {
            vm.warp(T0 + 181 minutes);
        } else if (_eq(key, "TWAP_GAP")) {
            // Keepers go idle for two hours while the market falls to 1,900 USD (the witness follows), record once at
            // T0 + 240 min, and the primary (last update T0 + 210 min) goes silent before a new window is covered.
            for (uint256 m = 150; m <= 210; m += 30) {
                vm.warp(T0 + m * 1 minutes);
                primary.pushAnswer(1900e8);
                secondary.pushAnswer(1900e18);
            }
            vm.warp(T0 + 240 minutes);
            _observe();
            vm.warp(T0 + 270 minutes + 1);
        } else if (_eq(key, "TWAP_DEVIATES")) {
            vm.warp(T0 + 151 minutes);
            secondary.pushAnswer(1872e18);
        } else if (_eq(key, "SEQUENCER_UNREADABLE")) {
            sequencer.setReverts(true);
        } else if (_eq(key, "SEQUENCER_UNINITIALIZED")) {
            sequencer.setRaw(0, 0);
        } else {
            revert(string.concat("unknown scenario key: ", key));
        }
    }

    // ============================================================================================================
    // Layer 1: one typed test per cell
    // ============================================================================================================

    function test_Matrix_Stale_Strict() public {
        _scenario("STALE");
        _assertQuoteBoth(strictRouter, 0, IPriceOracle.Status.STALE);
        _expectGetPriceRevert(strictRouter, _stalePrimary(61 minutes));
    }

    function test_Matrix_Stale_Soft() public {
        _scenario("STALE");
        _assertQuoteBoth(softRouter, 2080e18, IPriceOracle.Status.FALLBACK_USED);
        assertEq(softRouter.getPrice(ASSET, COLLATERAL), 2080e18);
        assertEq(softRouter.getPrice(ASSET, DEBT), 2080e18);
    }

    function test_Matrix_Zero_Strict() public {
        _zero(strictRouter);
    }

    function test_Matrix_Zero_Soft() public {
        _zero(softRouter);
    }

    function test_Matrix_Negative_Strict() public {
        _negative(strictRouter);
    }

    function test_Matrix_Negative_Soft() public {
        _negative(softRouter);
    }

    function test_Matrix_OutOfBounds_Strict() public {
        _outOfBounds(strictRouter);
    }

    function test_Matrix_OutOfBounds_Soft() public {
        _outOfBounds(softRouter);
    }

    function test_Matrix_SequencerDown_Strict() public {
        _sequencerDown(strictRouter);
    }

    function test_Matrix_SequencerDown_Soft() public {
        _sequencerDown(softRouter);
    }

    function test_Matrix_GracePeriod_Strict() public {
        _gracePeriod(strictRouter);
    }

    function test_Matrix_GracePeriod_Soft() public {
        _gracePeriod(softRouter);
    }

    function test_Matrix_Deviation_Strict() public {
        _scenario("DEVIATION");
        _assertQuoteBoth(strictRouter, 0, IPriceOracle.Status.DEVIATION);
        // (2090 - 1881) / 1881 = 11.11 % -> 1112 bps rounded up.
        _expectGetPriceRevert(
            strictRouter,
            abi.encodeWithSelector(IOracleRouter.DeviationTooHigh.selector, ASSET, 2090e18, 1881e18, 1112, 300)
        );
    }

    function test_Matrix_Deviation_Soft() public {
        _scenario("DEVIATION");
        _assertQuote(softRouter, COLLATERAL, 1881e18, IPriceOracle.Status.DEVIATION);
        _assertQuote(softRouter, DEBT, 2090e18, IPriceOracle.Status.DEVIATION);
        assertEq(softRouter.getPrice(ASSET, COLLATERAL), 1881e18);
        assertEq(softRouter.getPrice(ASSET, DEBT), 2090e18);
    }

    function test_Death_SecondaryDead_Strict() public {
        _scenario("SECONDARY_DEAD");
        _assertQuoteBoth(strictRouter, 0, IPriceOracle.Status.STALE);
        _expectGetPriceRevert(
            strictRouter, abi.encodeWithSelector(IOracleRouter.FeedUnavailable.selector, address(secondary))
        );
    }

    function test_Death_SecondaryDead_Soft() public {
        _scenario("SECONDARY_DEAD");
        _assertQuoteBoth(softRouter, 2090e18, IPriceOracle.Status.OK);
        assertEq(softRouter.getPrice(ASSET, DEBT), 2090e18);
    }

    function test_Death_SecondaryStale_Strict() public {
        _scenario("SECONDARY_STALE");
        _assertQuoteBoth(strictRouter, 0, IPriceOracle.Status.STALE);
        _expectGetPriceRevert(
            strictRouter,
            abi.encodeWithSelector(
                IOracleRouter.StalePrice.selector,
                address(secondary),
                NOW - SECONDARY_HEARTBEAT - 1,
                SECONDARY_HEARTBEAT + 1,
                SECONDARY_HEARTBEAT
            )
        );
    }

    function test_Death_SecondaryStale_Soft() public {
        _scenario("SECONDARY_STALE");
        _assertQuoteBoth(softRouter, 2090e18, IPriceOracle.Status.OK);
    }

    function test_Death_PrimaryReverts_Strict() public {
        _scenario("PRIMARY_REVERTS");
        _assertQuoteBoth(strictRouter, 0, IPriceOracle.Status.STALE);
        _expectGetPriceRevert(strictRouter, abi.encodeWithSelector(IOracleRouter.FeedUnavailable.selector, primary));
    }

    function test_Death_PrimaryReverts_Soft() public {
        _scenario("PRIMARY_REVERTS");
        _assertFallback();
    }

    function test_Death_PrimaryMalformed_Strict() public {
        _scenario("PRIMARY_MALFORMED");
        _assertQuoteBoth(strictRouter, 0, IPriceOracle.Status.STALE);
        _expectGetPriceRevert(strictRouter, abi.encodeWithSelector(IOracleRouter.FeedUnavailable.selector, primary));
    }

    function test_Death_PrimaryMalformed_Soft() public {
        _scenario("PRIMARY_MALFORMED");
        _assertFallback();
    }

    function test_Death_MissingTimestamp_Strict() public {
        _scenario("MISSING_TIMESTAMP");
        _assertQuoteBoth(strictRouter, 0, IPriceOracle.Status.STALE);
        _expectGetPriceRevert(
            strictRouter, abi.encodeWithSelector(IOracleRouter.MissingTimestamp.selector, primary, LAST_ROUND + 1)
        );
    }

    function test_Death_MissingTimestamp_Soft() public {
        _scenario("MISSING_TIMESTAMP");
        _assertFallback();
    }

    function test_Death_FutureTimestamp_Strict() public {
        _scenario("FUTURE_TIMESTAMP");
        _assertQuoteBoth(strictRouter, 0, IPriceOracle.Status.STALE);
        _expectGetPriceRevert(
            strictRouter, abi.encodeWithSelector(IOracleRouter.FutureTimestamp.selector, primary, NOW + 60, NOW)
        );
    }

    function test_Death_FutureTimestamp_Soft() public {
        _scenario("FUTURE_TIMESTAMP");
        _assertFallback();
    }

    function test_Death_CarriedOverRound_Strict() public {
        _scenario("CARRIED_OVER_ROUND");
        _assertQuoteBoth(strictRouter, 0, IPriceOracle.Status.STALE);
        _expectGetPriceRevert(
            strictRouter, abi.encodeWithSelector(IOracleRouter.StaleRound.selector, primary, LAST_ROUND + 1, LAST_ROUND)
        );
    }

    function test_Death_CarriedOverRound_Soft() public {
        _scenario("CARRIED_OVER_ROUND");
        _assertFallback();
    }

    function test_Death_TwapTooShort_Strict() public {
        _scenario("TWAP_TOO_SHORT");
        _assertQuoteBoth(strictRouter, 0, IPriceOracle.Status.STALE);
        _expectGetPriceRevert(strictRouter, _stalePrimary(61 minutes));
    }

    function test_Death_TwapTooShort_Soft() public {
        _scenario("TWAP_TOO_SHORT");
        (, uint256 cardinality,) = softRouter.getRingState(ASSET);
        assertEq(cardinality, 3, "20 minutes of history");
        _assertQuoteBoth(softRouter, 0, IPriceOracle.Status.STALE);
        _expectGetPriceRevert(softRouter, _stalePrimary(61 minutes));
    }

    function test_Death_TwapExpired_Strict() public {
        _scenario("TWAP_EXPIRED");
        _assertQuoteBoth(strictRouter, 0, IPriceOracle.Status.STALE);
        _expectGetPriceRevert(strictRouter, _stalePrimary(91 minutes));
    }

    function test_Death_TwapExpired_Soft() public {
        _scenario("TWAP_EXPIRED");
        _assertQuoteBoth(softRouter, 0, IPriceOracle.Status.STALE);
        _expectGetPriceRevert(softRouter, _stalePrimary(91 minutes));
    }

    function test_Death_TwapGap_Strict() public {
        _scenario("TWAP_GAP");
        _assertQuoteBoth(strictRouter, 0, IPriceOracle.Status.STALE);
        _expectGetPriceRevert(strictRouter, _stalePrimarySince(T0 + 210 minutes, 60 minutes + 1));
    }

    /// @dev Before the gap rule, the window [T0 + 180, T0 + 240] was filled with the 2,090 USD answer carried across
    ///      the two idle hours, and the soft router quoted that stale average against the 1,900 USD witness.
    function test_Death_TwapGap_Soft() public {
        _scenario("TWAP_GAP");
        (, uint256 cardinality,) = softRouter.getRingState(ASSET);
        assertEq(cardinality, 1, "the observation after the gap restarted the history");
        _assertQuoteBoth(softRouter, 0, IPriceOracle.Status.STALE);
        _expectGetPriceRevert(softRouter, _stalePrimarySince(T0 + 210 minutes, 60 minutes + 1));
    }

    function test_Death_TwapDeviates_Strict() public {
        _scenario("TWAP_DEVIATES");
        _assertQuoteBoth(strictRouter, 0, IPriceOracle.Status.STALE);
        _expectGetPriceRevert(strictRouter, _stalePrimary(61 minutes));
    }

    function test_Death_TwapDeviates_Soft() public {
        _scenario("TWAP_DEVIATES");
        _assertQuote(softRouter, COLLATERAL, 1872e18, IPriceOracle.Status.DEVIATION);
        _assertQuote(softRouter, DEBT, 2080e18, IPriceOracle.Status.DEVIATION);
    }

    function test_Death_SequencerUnreadable_Strict() public {
        _sequencerUnreadable(strictRouter);
    }

    function test_Death_SequencerUnreadable_Soft() public {
        _sequencerUnreadable(softRouter);
    }

    function test_Death_SequencerUninitialized_Strict() public {
        _sequencerUninitialized(strictRouter);
    }

    function test_Death_SequencerUninitialized_Soft() public {
        _sequencerUninitialized(softRouter);
    }

    // Shared bodies of cells whose strict and soft outcomes are identical.

    function _zero(OracleRouter router) internal {
        _scenario("ZERO");
        _assertQuoteBoth(router, 0, IPriceOracle.Status.ZERO);
        _expectGetPriceRevert(router, abi.encodeWithSelector(IOracleRouter.ZeroAnswer.selector, primary, 12));
    }

    function _negative(OracleRouter router) internal {
        _scenario("NEGATIVE");
        _assertQuoteBoth(router, 0, IPriceOracle.Status.NEGATIVE);
        _expectGetPriceRevert(
            router, abi.encodeWithSelector(IOracleRouter.NegativeAnswer.selector, primary, int256(-2090e8))
        );
    }

    function _outOfBounds(OracleRouter router) internal {
        _scenario("OUT_OF_BOUNDS");
        _assertQuoteBoth(router, 0, IPriceOracle.Status.OUT_OF_BOUNDS);
        _expectGetPriceRevert(
            router,
            abi.encodeWithSelector(
                IOracleRouter.AnswerOutOfBounds.selector, primary, int256(99e8), PRIMARY_MIN, PRIMARY_MAX
            )
        );
    }

    function _sequencerDown(OracleRouter router) internal {
        _scenario("SEQUENCER_DOWN");
        _assertQuoteBoth(router, 0, IPriceOracle.Status.SEQUENCER_DOWN);
        _expectGetPriceRevert(
            router, abi.encodeWithSelector(IOracleRouter.SequencerDown.selector, sequencer, int256(1), NOW)
        );
    }

    function _gracePeriod(OracleRouter router) internal {
        _scenario("GRACE_PERIOD");
        _assertQuoteBoth(router, 0, IPriceOracle.Status.GRACE_PERIOD);
        _expectGetPriceRevert(
            router,
            abi.encodeWithSelector(IOracleRouter.GracePeriodNotOver.selector, NOW + 10 minutes, 10 minutes, 1 hours)
        );
    }

    function _sequencerUnreadable(OracleRouter router) internal {
        _scenario("SEQUENCER_UNREADABLE");
        _assertQuoteBoth(router, 0, IPriceOracle.Status.SEQUENCER_DOWN);
        _expectGetPriceRevert(router, abi.encodeWithSelector(IOracleRouter.FeedUnavailable.selector, sequencer));
    }

    function _sequencerUninitialized(OracleRouter router) internal {
        _scenario("SEQUENCER_UNINITIALIZED");
        _assertQuoteBoth(router, 0, IPriceOracle.Status.SEQUENCER_DOWN);
        _expectGetPriceRevert(
            router, abi.encodeWithSelector(IOracleRouter.SequencerDown.selector, sequencer, int256(0), 0)
        );
    }

    function _assertFallback() internal view {
        _assertQuoteBoth(softRouter, 2080e18, IPriceOracle.Status.FALLBACK_USED);
        assertEq(softRouter.getPrice(ASSET, COLLATERAL), 2080e18);
    }

    function _stalePrimary(uint256 age) internal view returns (bytes memory) {
        return _stalePrimarySince(LAST_UPDATE, age);
    }

    function _stalePrimarySince(uint256 updatedAt, uint256 age) internal view returns (bytes memory) {
        return
            abi.encodeWithSelector(
                IOracleRouter.StalePrice.selector, address(primary), updatedAt, age, PRIMARY_HEARTBEAT
            );
    }

    // ============================================================================================================
    // Reference model for layer 2 (independent of the router's code)
    // ============================================================================================================

    /// @dev Value of a documented price token in the current state: `0`, `SPOT`, `TWAP` or `CONSERVATIVE`.
    function _reference(string memory token, IPriceOracle.Intent intent) internal view returns (uint256) {
        if (_eq(token, "0")) return 0;
        if (_eq(token, "SPOT")) return _spot(intent);
        if (_eq(token, "TWAP")) return _twap(intent);
        assertEq(token, "CONSERVATIVE", "unknown price token");
        uint256 primarySide = _primaryHealthy() ? _spot(intent) : _twap(intent);
        (, MockAggregatorV3.RoundData memory s) = secondary.latestRoundRaw();
        uint256 secondaryPrice = _wad(uint256(s.answer), 18, intent);
        return intent == COLLATERAL ? Math.min(primarySide, secondaryPrice) : Math.max(primarySide, secondaryPrice);
    }

    function _spot(IPriceOracle.Intent intent) internal view returns (uint256) {
        (, MockAggregatorV3.RoundData memory p) = primary.latestRoundRaw();
        return _wad(uint256(p.answer), 8, intent);
    }

    /// @dev Time-weighted mean of the ghost log over the window ending at the newest observation. The log is never
    ///      trimmed; the usable history starts after the last break (a silence longer than one heartbeat or one
    ///      window, or a sequencer recovery between two observations) and must cover a full window that ended at most
    ///      one window ago, after the sequencer's last recovery; otherwise the reference model has no TWAP to offer
    ///      and a cell claiming one is wrong.
    function _twap(IPriceOracle.Intent intent) internal view returns (uint256) {
        uint256 n = ghostTimes.length;
        uint256 first = _historyStart();
        uint256 to = ghostTimes[n - 1];
        assertTrue(
            n - first >= 2 && to - ghostTimes[first] >= TWAP_WINDOW && block.timestamp - to <= TWAP_WINDOW
                && to >= sequencer.startedAt(),
            "the reference model has a TWAP to offer"
        );
        uint256 from = to - TWAP_WINDOW;
        uint256 sum;
        for (uint256 j = first; j + 1 < n; ++j) {
            uint256 lo = ghostTimes[j] > from ? ghostTimes[j] : from;
            uint256 hi = ghostTimes[j + 1];
            if (hi > lo) sum += ghostAnswers[j] * (hi - lo);
        }
        Math.Rounding rounding = intent == DEBT ? Math.Rounding.Ceil : Math.Rounding.Floor;
        return Math.mulDiv(sum, 1e18, uint256(TWAP_WINDOW) * 1e8, rounding);
    }

    /// @dev Index of the first ghost observation after the last break in the log.
    function _historyStart() internal view returns (uint256 first) {
        uint256 maxGap = PRIMARY_HEARTBEAT < TWAP_WINDOW ? PRIMARY_HEARTBEAT : TWAP_WINDOW;
        for (uint256 j = 1; j < ghostTimes.length; ++j) {
            if (ghostTimes[j] - ghostTimes[j - 1] > maxGap || ghostUpSince[j] > ghostTimes[j - 1]) first = j;
        }
    }

    function _primaryHealthy() internal view returns (bool) {
        if (primary.behavior() != MockAggregatorV3.Behavior.Normal) return false;
        (uint80 id, MockAggregatorV3.RoundData memory p) = primary.latestRoundRaw();
        return p.answer >= int256(uint256(PRIMARY_MIN)) && p.answer <= int256(uint256(PRIMARY_MAX)) && p.updatedAt != 0
            && p.updatedAt <= block.timestamp && block.timestamp - p.updatedAt <= PRIMARY_HEARTBEAT
            && p.answeredInRound >= id;
    }

    function _wad(uint256 answer, uint8 decimals, IPriceOracle.Intent intent) internal pure returns (uint256) {
        Math.Rounding rounding = intent == DEBT ? Math.Rounding.Ceil : Math.Rounding.Floor;
        return Math.mulDiv(answer, 1e18, 10 ** decimals, rounding);
    }

    function _statusName(IPriceOracle.Status status) internal pure returns (string memory) {
        string[9] memory names = [
            "OK",
            "STALE",
            "ZERO",
            "NEGATIVE",
            "OUT_OF_BOUNDS",
            "SEQUENCER_DOWN",
            "GRACE_PERIOD",
            "DEVIATION",
            "FALLBACK_USED"
        ];
        return names[uint256(status)];
    }

    function _errorSelector(string memory name) internal pure returns (bytes4) {
        if (_eq(name, "FeedUnavailable")) return IOracleRouter.FeedUnavailable.selector;
        if (_eq(name, "ZeroAnswer")) return IOracleRouter.ZeroAnswer.selector;
        if (_eq(name, "NegativeAnswer")) return IOracleRouter.NegativeAnswer.selector;
        if (_eq(name, "MissingTimestamp")) return IOracleRouter.MissingTimestamp.selector;
        if (_eq(name, "FutureTimestamp")) return IOracleRouter.FutureTimestamp.selector;
        if (_eq(name, "StalePrice")) return IOracleRouter.StalePrice.selector;
        if (_eq(name, "StaleRound")) return IOracleRouter.StaleRound.selector;
        if (_eq(name, "AnswerOutOfBounds")) return IOracleRouter.AnswerOutOfBounds.selector;
        if (_eq(name, "SequencerDown")) return IOracleRouter.SequencerDown.selector;
        if (_eq(name, "GracePeriodNotOver")) return IOracleRouter.GracePeriodNotOver.selector;
        if (_eq(name, "DeviationTooHigh")) return IOracleRouter.DeviationTooHigh.selector;
        revert(string.concat("unknown error name: ", name));
    }

    function _observe() internal {
        strictRouter.recordObservation(ASSET);
        softRouter.recordObservation(ASSET);
        (, MockAggregatorV3.RoundData memory p) = primary.latestRoundRaw();
        ghostTimes.push(block.timestamp);
        ghostAnswers.push(uint256(p.answer));
        ghostUpSince.push(sequencer.startedAt());
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
