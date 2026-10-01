// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import {ForwarderFactory} from "../src/ForwarderFactory.sol";
import {TestToken} from "./mocks/TestToken.sol";

/// @title Sweep gas benchmarks
/// @notice Deterministic gas measurements for `.gas-snapshot` (checked in CI with
///         `forge snapshot --check`). Each test sweeps N forwarders that hold a deposit; the
///         "Cold" variants include deploying the clones, the "Warm" variants flush clones that
///         already exist (a user's second and later deposits).
/// @dev    In Foundry 1.8.3 `vm.snapshotGasLastFrame` reports what a receipt would for the call:
///         the 21,000 intrinsic cost and the calldata are included (a no-op call measures
///         21,183). The hot wallet already holds tokens, like the engine's on anvil, so the first
///         credit of a sweep is not a zero-to-nonzero SSTORE and the figures are comparable with
///         the anvil receipts in the README.
contract ForwarderFactoryGasTest is Test {
    ForwarderFactory internal factory;
    TestToken internal token;
    address internal sweeper = makeAddr("sweeper");
    address internal hot = makeAddr("hot");

    function setUp() public {
        factory = new ForwarderFactory(payable(hot), sweeper);
        token = new TestToken();
        token.mint(hot, 1); // operating liquidity
    }

    function _fund(uint256 n) internal returns (bytes32[] memory salts) {
        salts = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            salts[i] = keccak256(abi.encode("gas-user", i));
            token.mint(factory.forwarderAddress(salts[i]), 1_000e6);
        }
    }

    function _warm(bytes32[] memory salts) internal {
        vm.prank(sweeper);
        factory.flushMany(salts, IERC20(address(token)));
        for (uint256 i; i < salts.length; ++i) {
            token.mint(factory.forwarderAddress(salts[i]), 1_000e6);
        }
    }

    /// @dev Sweeps and records the gas of the flushMany frame alone (no funding or setup) under
    ///      `snapshots/sweep.json`.
    function _sweep(bytes32[] memory salts, string memory name) internal {
        vm.prank(sweeper);
        factory.flushMany(salts, IERC20(address(token)));
        vm.snapshotGasLastFrame("sweep", name);
    }

    function test_gas_sweepCold_1() public {
        _sweep(_fund(1), "flushMany_cold_1");
    }

    function test_gas_sweepCold_10() public {
        _sweep(_fund(10), "flushMany_cold_10");
    }

    function test_gas_sweepCold_50() public {
        _sweep(_fund(50), "flushMany_cold_50");
    }

    function test_gas_sweepWarm_1() public {
        bytes32[] memory salts = _fund(1);
        _warm(salts);
        _sweep(salts, "flushMany_warm_1");
    }

    function test_gas_sweepWarm_10() public {
        bytes32[] memory salts = _fund(10);
        _warm(salts);
        _sweep(salts, "flushMany_warm_10");
    }

    function test_gas_sweepWarm_50() public {
        bytes32[] memory salts = _fund(50);
        _warm(salts);
        _sweep(salts, "flushMany_warm_50");
    }
}
