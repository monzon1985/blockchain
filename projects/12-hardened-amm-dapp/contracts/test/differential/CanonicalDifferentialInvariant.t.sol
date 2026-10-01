// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.37;

import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {Test, console2} from "forge-std/Test.sol";

import {AMMLibrary} from "../../src/libraries/AMMLibrary.sol";
import {DualPairHarness} from "./DualPairHarness.sol";

/// @notice Bounded fuzz entry points over the dual harness. Every call ends with the harness asserting that
///         both pairs agree on outcome and on every observable (a disagreement reverts, which fails the run).
contract DifferentialHandler is CommonBase, StdUtils {
    DualPairHarness public immutable h;

    constructor(DualPairHarness harness) {
        h = harness;
    }

    function mint(uint256 amount0, uint256 amount1, uint256 actorSeed) external {
        h.mint(bound(amount0, 0, 1e27), bound(amount1, 0, 1e27), actorSeed);
    }

    function burn(uint256 actorSeed, uint256 bps) external {
        h.burn(actorSeed, h.lpBalance(actorSeed) * bound(bps, 0, 10_000) / 10_000);
    }

    /// @dev Exact-input swap at quote - 1, quote or quote + 1: the k boundary is hit on every call.
    function swapAtQuote(uint256 amountIn, bool zeroForOne, uint256 adjust, uint256 actorSeed) external {
        (uint112 r0, uint112 r1) = h.reserves();
        if (r0 == 0 || r1 == 0) return; // no pool yet: nothing to quote (raw swaps still cover this state)
        (uint256 reserveIn, uint256 reserveOut) = zeroForOne ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        amountIn = bound(amountIn, 1, reserveIn * 3);
        uint256 out = AMMLibrary.getAmountOut(amountIn, reserveIn, reserveOut) + bound(adjust, 0, 2);
        out = out == 0 ? 0 : out - 1;
        if (zeroForOne) h.swap(amountIn, 0, 0, out, actorSeed);
        else h.swap(0, amountIn, out, 0, actorSeed);
    }

    function swapRaw(uint256 in0, uint256 in1, uint256 out0, uint256 out1, uint256 actorSeed) external {
        (uint112 r0, uint112 r1) = h.reserves();
        h.swap(
            bound(in0, 0, 1e25),
            bound(in1, 0, 1e25),
            bound(out0, 0, uint256(r0) + 1),
            bound(out1, 0, uint256(r1) + 1),
            actorSeed
        );
    }

    function donate(uint256 amount0, uint256 amount1) external {
        h.donate(bound(amount0, 0, 1e24), bound(amount1, 0, 1e24));
    }

    function skim(uint256 actorSeed) external {
        h.skim(actorSeed);
    }

    function sync() external {
        h.sync();
    }

    function transferLp(uint256 fromSeed, uint256 toSeed, uint256 bps) external {
        h.transferLp(fromSeed, toSeed, h.lpBalance(fromSeed) * bound(bps, 0, 10_000) / 10_000);
    }

    function warp(uint256 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 0, 30 days));
    }

    /// @dev Jumps to just before the next 2^32 boundary so the uint32 timestamp wrap is exercised.
    function warpToTimestampWrap(uint256 secondsBefore) external {
        uint256 nextWrap = ((block.timestamp >> 32) + 1) << 32;
        vm.warp(nextWrap - bound(secondsBefore, 1, 1 hours));
    }

    function setProtocolFee(bool on) external {
        h.setProtocolFee(on);
    }
}

/// @notice Stateful differential fuzzing: arbitrary interleavings of mint, burn, swap, donate, skim, sync,
///         LP transfers, time jumps (including the 2^32 wrap) and protocol-fee toggles, applied to the hardened
///         pair and to the canonical Uniswap v2 bytecode.
contract CanonicalDifferentialInvariantTest is Test {
    DualPairHarness internal h;
    DifferentialHandler internal handler;

    function setUp() public {
        vm.warp(1_750_000_000);
        h = new DualPairHarness();
        handler = new DifferentialHandler(h);
        targetContract(address(handler));
    }

    /// @dev Outcome agreement (both succeed or both revert, same return data) is asserted inside every handler
    ///      call; a disagreement reverts and fails the run because `fail_on_revert = true`.
    function invariant_hardenedPairMatchesCanonicalBytecode() public view {
        h.assertSameState("invariant");
    }

    /// @dev Reports how many dual operations succeeded on both pairs and how many reverted on both (-vv).
    function afterInvariant() external view {
        console2.log("dual ops succeeded on both:", h.bothSucceeded());
        console2.log("dual ops reverted on both:", h.bothReverted());
    }
}
