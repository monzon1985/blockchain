// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title RollupSpec
/// @notice Protocol constants shared by the L1 contracts and mirrored in `crates/stf`.
library RollupSpec {
    /// @notice Tape record kind: L1 deposit, credits `to`.
    uint256 internal constant KIND_DEPOSIT = 1;
    /// @notice Tape record kind: L1-forced transfer from `from` (the L1 sender) to `to`.
    uint256 internal constant KIND_FORCED_TRANSFER = 2;
    /// @notice Tape record kind: L1-forced withdrawal from `from` (the L1 sender) to L1 address `to`.
    uint256 internal constant KIND_FORCED_WITHDRAWAL = 3;
    /// @notice Tape record kind: signed L2 transfer posted by the sequencer.
    uint256 internal constant KIND_TRANSFER = 4;
    /// @notice Tape record kind: signed L2 withdrawal posted by the sequencer.
    uint256 internal constant KIND_WITHDRAWAL = 5;

    /// @notice Size of one tape record (8 words).
    uint256 internal constant RECORD_BYTES = 256;

    /// @notice State-tree tag for withdrawal records: key = keccak256(abi.encode(WITHDRAWAL_TAG, id)).
    uint256 internal constant WITHDRAWAL_TAG = 3;

    /// @notice Version byte mixed into every output root.
    uint256 internal constant OUTPUT_VERSION = 0;

    /// @notice Output root committed for an epoch.
    /// @param epoch The epoch (batch index, 1-based).
    /// @param stateRoot The L2 state root after executing the epoch.
    /// @return keccak256(abi.encode(OUTPUT_VERSION, epoch, stateRoot)).
    function outputRoot(uint256 epoch, bytes32 stateRoot) internal pure returns (bytes32) {
        return keccak256(abi.encode(OUTPUT_VERSION, epoch, stateRoot));
    }

    /// @notice State-tree key of withdrawal `id`.
    /// @param id Sequential withdrawal id assigned by the L2.
    /// @return The key.
    function withdrawalKey(uint256 id) internal pure returns (bytes32) {
        return keccak256(abi.encode(WITHDRAWAL_TAG, id));
    }

    /// @notice State-tree value committed for a withdrawal.
    /// @param recipient L1 recipient.
    /// @param amount Wei.
    /// @return keccak256(abi.encode(recipient, amount)).
    function withdrawalValue(address recipient, uint256 amount) internal pure returns (bytes32) {
        return keccak256(abi.encode(recipient, amount));
    }
}
