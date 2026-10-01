// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {OracleRouter} from "../../src/OracleRouter.sol";
import {AggregatorV3Interface} from "../../src/interfaces/AggregatorV3Interface.sol";
import {IOracleRouter} from "../../src/interfaces/IOracleRouter.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";
import {RouterTestBase} from "../utils/RouterTestBase.sol";

/// @notice The two baselines a protocol would otherwise ship: an unchecked `latestRoundData()` read and the usual
///         hand-rolled "positive and not older than the heartbeat" check.
contract NaiveConsumer {
    error BadPrice();

    function unchecked_(AggregatorV3Interface feed) external view returns (uint256) {
        (, int256 answer,,,) = feed.latestRoundData();
        return uint256(answer) * 1e10;
    }

    function handRolled(AggregatorV3Interface feed, uint256 heartbeat) external view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        if (answer <= 0 || block.timestamp - updatedAt > heartbeat) revert BadPrice();
        return uint256(answer) * 1e10;
    }
}

/// @notice Gas of each pricing path (one measured call per test; `forge snapshot --match-contract GasBench`).
///         Every call starts cold, as in a consumer's first read of a transaction.
contract GasBench is RouterTestBase {
    NaiveConsumer internal naive;
    OracleRouter internal primaryOnlyL1;
    OracleRouter internal primaryOnlyL2;

    function setUp() public override {
        super.setUp();
        naive = new NaiveConsumer();
        primaryOnlyL1 = _deployRouter(address(0), _primaryOnlyParams(IOracleRouter.Mode.Strict));
        primaryOnlyL2 = _deployRouter(_primaryOnlyParams(IOracleRouter.Mode.Strict));
        _buildHistory(90);
        vm.warp(block.timestamp + 1);
    }

    function test_gas_baseline_uncheckedRead() public view {
        naive.unchecked_(AggregatorV3Interface(address(primary)));
    }

    function test_gas_baseline_handRolledCheck() public view {
        naive.handRolled(AggregatorV3Interface(address(primary)), PRIMARY_HEARTBEAT);
    }

    function test_gas_getPrice_primaryOnly_L1() public view {
        primaryOnlyL1.getPrice(ASSET, COLLATERAL);
    }

    function test_gas_getPrice_primaryOnly_L2() public view {
        primaryOnlyL2.getPrice(ASSET, COLLATERAL);
    }

    function test_gas_getPrice_primaryAndSecondary_L2() public view {
        strictRouter.getPrice(ASSET, COLLATERAL);
    }

    function test_gas_tryGetPrice_primaryAndSecondary_L2() public view {
        strictRouter.tryGetPrice(ASSET, DEBT);
    }

    function test_gas_recordObservation() public {
        vm.warp(block.timestamp + 5 minutes);
        softRouter.recordObservation(ASSET);
    }
}

/// @notice Degraded paths, set up in `setUp` so the measured call still starts cold.
contract GasBenchFallback is RouterTestBase {
    function setUp() public override {
        super.setUp();
        // 67 observations 5 minutes apart: the ring is full (64 slots), so the binary search runs over all of them.
        _buildHistory(330);
        (, uint256 cardinality,) = softRouter.getRingState(ASSET);
        assertEq(cardinality, 64, "full ring");
        vm.warp(block.timestamp + 1);
        primary.setBehavior(MockAggregatorV3.Behavior.Revert);
    }

    /// @dev Primary dead, TWAP served after a binary search over the full ring, then cross-checked with the secondary.
    function test_gas_tryGetPrice_twapFallback_L2() public view {
        softRouter.tryGetPrice(ASSET, COLLATERAL);
    }
}

contract GasBenchSequencerDown is RouterTestBase {
    function setUp() public override {
        super.setUp();
        sequencer.setDown();
    }

    /// @dev The cheapest failure: one feed read, no asset feed touched.
    function test_gas_tryGetPrice_sequencerDown() public view {
        strictRouter.tryGetPrice(ASSET, COLLATERAL);
    }
}
