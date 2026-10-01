// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @notice One small operation the {PrecisionAmplifier} repeats.
interface IAmplifiedOperation {
    /// @notice Perform the operation once with `amount`.
    /// @param amount Operation size (operation-specific units).
    /// @return paid Value the operation delivered to the operator.
    /// @return fair Value an exact implementation of the protocol's own pricing rule would have
    ///         delivered, in the same unit as `paid`.
    function step(uint256 amount) external returns (uint256 paid, uint256 fair);
}

/// @title PrecisionAmplifier
/// @notice Reusable precision-loss amplification harness. It repeats a small operation `n`
///         times and measures the value extracted beyond the fair amount (`paid - fair`, summed
///         over the run, never negative per step). Per operation id it keeps the maximum
///         extractable error ever observed, which invariants and PoCs assert on.
/// @dev    Operation-agnostic: anything implementing {IAmplifiedOperation} can be amplified, e.g.
///         dust vault withdrawals or tiny batch swaps on a low-decimal pool.
contract PrecisionAmplifier {
    /// @notice Aggregate statistics per operation id.
    /// @param runs Number of amplification runs.
    /// @param steps Number of successful steps across runs.
    /// @param maxError Largest error extracted in a single run.
    /// @param totalError Error extracted across all runs.
    struct Stats {
        uint256 runs;
        uint256 steps;
        uint256 maxError;
        uint256 totalError;
    }

    /// @notice Statistics per operation id.
    mapping(bytes32 opId => Stats stats) public stats;

    /// @notice Emitted after each amplification run.
    /// @param opId Operation id.
    /// @param steps Successful steps in this run.
    /// @param extracted Value extracted beyond the fair amount in this run.
    event Amplified(bytes32 indexed opId, uint256 steps, uint256 extracted);

    /// @notice Repeat `op.step(amount)` up to `n` times (stopping at the first revert).
    /// @param opId Operation id under which statistics are recorded.
    /// @param op Operation to repeat.
    /// @param n Number of repetitions.
    /// @param amount Size passed to every step.
    /// @return extracted Value extracted beyond the fair amount in this run.
    function amplify(bytes32 opId, IAmplifiedOperation op, uint256 n, uint256 amount)
        external
        returns (uint256 extracted)
    {
        uint256 done;
        for (uint256 i = 0; i < n; ++i) {
            try op.step(amount) returns (uint256 paid, uint256 fair) {
                if (paid > fair) extracted += paid - fair;
                ++done;
            } catch {
                break;
            }
        }
        Stats storage s = stats[opId];
        s.runs += 1;
        s.steps += done;
        s.totalError += extracted;
        if (extracted > s.maxError) s.maxError = extracted;
        emit Amplified(opId, done, extracted);
    }

    /// @notice Largest error extracted in a single run of `opId`.
    /// @param opId Operation id.
    /// @return extracted Maximum extractable error observed.
    function maxError(bytes32 opId) external view returns (uint256 extracted) {
        extracted = stats[opId].maxError;
    }
}
