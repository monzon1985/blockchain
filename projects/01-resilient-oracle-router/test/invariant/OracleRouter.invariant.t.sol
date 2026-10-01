// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IPriceOracle} from "../../src/interfaces/IPriceOracle.sol";
import {OracleSystem} from "./OracleSystem.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Stateful invariants: Foundry drives `OracleSystem`'s seven actions and checks all ten properties after every
///         call. The Medusa campaign (medusa.json) checks the very same `property_*` functions.
contract OracleRouterInvariantTest is Test {
    /// @dev Opt-in campaign statistics: `ORACLE_CAMPAIGN_STATS=true` appends one line per run to this file.
    string internal constant STATS_FILE = "demo-out/invariant-campaign-stats.txt";

    /// @dev The invariant depth of both profiles in foundry.toml. Shorter runs are shrink attempts or replays of a
    ///      counterexample Foundry persisted after a failure: too short for the floor, and not campaign runs.
    uint256 internal constant FULL_DEPTH = 100;

    OracleSystem internal system;

    function setUp() public {
        vm.warp(1_750_000_000);
        system = new OracleSystem();
        targetContract(address(system));
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = OracleSystem.warp.selector;
        selectors[1] = OracleSystem.updatePrimary.selector;
        selectors[2] = OracleSystem.updateSecondary.selector;
        selectors[3] = OracleSystem.corruptFeed.selector;
        selectors[4] = OracleSystem.silencePrimary.selector;
        selectors[5] = OracleSystem.toggleSequencer.selector;
        selectors[6] = OracleSystem.recordObservation.selector;
        targetSelector(FuzzSelector({addr: address(system), selectors: selectors}));
    }

    /// @notice Every full-depth run must have exercised the TWAP fallback: properties are checked after every call,
    ///         so each counted state is one evaluation in which P7 and P8 had something to check. A run that never got
    ///         there would make P7 and P8 vacuous. (History restarts are rarer per run; the walk asserts them.)
    function afterInvariant() public {
        if (system.actionCount() < FULL_DEPTH) return;
        if (vm.envOr("ORACLE_CAMPAIGN_STATS", false)) {
            vm.writeLine(
                STATS_FILE,
                string.concat(
                    "fallback=",
                    vm.toString(system.fallbackStates()),
                    " twapDeviation=",
                    vm.toString(system.twapDeviationStates()),
                    " bridgeable=",
                    vm.toString(system.bridgeableStates()),
                    " refused=",
                    vm.toString(system.refusedFallbackStates()),
                    " restarts=",
                    vm.toString(system.historyRestarts()),
                    " softObservations=",
                    vm.toString(system.observationsRecorded(1))
                )
            );
        }
        assertGt(system.fallbackStates(), 0, "P7 never evaluated a FALLBACK_USED quote in this run");
        assertGt(system.bridgeableStates(), 0, "P8 never evaluated a bridgeable state in this run");
    }

    function invariant_okMeansHealthyInputs() public view {
        assertTrue(system.property_okMeansHealthyInputs());
    }

    function invariant_neverOkWithStaleZeroOrOutOfBounds() public view {
        assertTrue(system.property_neverOkWithStaleZeroOrOutOfBounds());
    }

    function invariant_zeroPriceIffUnusable() public view {
        assertTrue(system.property_zeroPriceIffUnusable());
    }

    function invariant_revertingAndNonRevertingApisAgree() public view {
        assertTrue(system.property_revertingAndNonRevertingApisAgree());
    }

    function invariant_sequencerOutageBlocksEverything() public view {
        assertTrue(system.property_sequencerOutageBlocksEverything());
    }

    function invariant_strictNeverLooserThanSoft() public view {
        assertTrue(system.property_strictNeverLooserThanSoft());
    }

    function invariant_fallbackIsExactTwapOfValidatedAnswers() public view {
        assertTrue(system.property_fallbackIsExactTwapOfValidatedAnswers());
    }

    function invariant_softBridgesWheneverItCan() public view {
        assertTrue(system.property_softBridgesWheneverItCan());
    }

    function invariant_debtNeverBelowCollateral() public view {
        assertTrue(system.property_debtNeverBelowCollateral());
    }

    function invariant_usablePricesWithinBounds() public view {
        assertTrue(system.property_usablePricesWithinBounds());
    }
}

/// @notice The handler is not vacuous: a fixed pseudo-random walk through the same actions checks all ten properties
///         after every step, reaches all nine statuses, and puts the fallback properties to work a minimum number of
///         times (the floors sit well below the walk's measured counts, which the README reports).
contract OracleSystemReachabilityTest is Test {
    uint256 internal constant STEPS = 600;

    function test_WalkReachesEveryStatus() public {
        vm.warp(1_750_000_000);
        OracleSystem system = new OracleSystem();
        uint256 seed = 0x01;
        for (uint256 step; step < STEPS; ++step) {
            seed = uint256(keccak256(abi.encode(seed)));
            uint256 action = seed % 16;
            uint256 a = seed >> 8;
            uint256 b = seed >> 72;
            if (action < 4) system.warp(b);
            else if (action < 5) system.recordObservation();
            else if (action < 7) system.updatePrimary(a, b);
            else if (action < 9) system.updateSecondary(a, b);
            else if (action < 12) system.corruptFeed(a, b % 3 == 0, b >> 8, b >> 16);
            else if (action < 15) system.silencePrimary(a, b);
            else system.toggleSequencer(b);
            _assertAllProperties(system, step);
        }

        uint256 seen = system.statusesSeen();
        for (uint256 s; s <= uint256(IPriceOracle.Status.FALLBACK_USED); ++s) {
            assertTrue(seen & (1 << s) != 0, string.concat("status never reached: ", vm.toString(s)));
        }
        assertGt(system.observationsRecorded(0), 0);
        assertGt(system.observationsRecorded(1), 0);
        // Every step above checked P7 and P8, so these are counts of non-vacuous evaluations (`-vv` prints them).
        emit log_named_uint("states with a FALLBACK_USED quote", system.fallbackStates());
        emit log_named_uint("states with a TWAP-vs-witness DEVIATION", system.twapDeviationStates());
        emit log_named_uint("states where P8's premise held", system.bridgeableStates());
        emit log_named_uint("states with a refused fallback (soft STALE)", system.refusedFallbackStates());
        emit log_named_uint("history restarts", system.historyRestarts());
        emit log_named_uint("observations accepted by the soft router", system.observationsRecorded(1));
        assertGe(system.fallbackStates(), 90, "P7: FALLBACK_USED states evaluated");
        assertGe(system.twapDeviationStates(), 30, "P7/P8: TWAP-vs-witness DEVIATION states evaluated");
        assertGe(system.bridgeableStates(), 120, "P8: bridgeable states evaluated");
        assertGe(system.historyRestarts(), 50, "gap rule: history restarts");
    }

    function _assertAllProperties(OracleSystem system, uint256 step) internal view {
        string memory where = string.concat(" at step ", vm.toString(step));
        assertTrue(system.property_okMeansHealthyInputs(), string.concat("P1", where));
        assertTrue(system.property_neverOkWithStaleZeroOrOutOfBounds(), string.concat("P2", where));
        assertTrue(system.property_zeroPriceIffUnusable(), string.concat("P3", where));
        assertTrue(system.property_revertingAndNonRevertingApisAgree(), string.concat("P4", where));
        assertTrue(system.property_sequencerOutageBlocksEverything(), string.concat("P5", where));
        assertTrue(system.property_strictNeverLooserThanSoft(), string.concat("P6", where));
        assertTrue(system.property_fallbackIsExactTwapOfValidatedAnswers(), string.concat("P7", where));
        assertTrue(system.property_softBridgesWheneverItCan(), string.concat("P8", where));
        assertTrue(system.property_debtNeverBelowCollateral(), string.concat("P9", where));
        assertTrue(system.property_usablePricesWithinBounds(), string.concat("P10", where));
    }
}
