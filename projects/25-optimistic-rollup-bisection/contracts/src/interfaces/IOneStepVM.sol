// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Machine, StepProof} from "../lib/Types.sol";

/// @title IOneStepVM
/// @notice Executes exactly one VM instruction from a Merkle-proven pre-state.
interface IOneStepVM {
    /// @notice Executes the instruction at `pre.pc` and returns the resulting machine.
    /// @dev Reverts when the witness is inconsistent with `pre`; never reverts because of what the program does
    ///      (invalid programs move the machine to the errored status instead).
    /// @param pre The pre-state.
    /// @param proof Witness for the instruction, the stack words it reads and the state or tape it touches.
    /// @return post The post-state.
    function step(Machine calldata pre, StepProof calldata proof) external pure returns (Machine memory post);

    /// @notice Same as `step`, but returns only the post-state commitment.
    /// @param pre The pre-state.
    /// @param proof Witness, see `step`.
    /// @return The post-state hash.
    function stepHash(Machine calldata pre, StepProof calldata proof) external pure returns (bytes32);
}
