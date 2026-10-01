// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Milestone} from "../types/StreamTypes.sol";

/// @title MilestoneCodec
/// @notice Packs milestones into 21 bytes each (16-byte amount, 5-byte timestamp) for SSTORE2 storage.
/// @dev Milestones never change after creation, so they are written once into the bytecode of a data contract
/// (Solady SSTORE2) instead of one storage slot each. A 16-segment schedule costs 336 bytes of code
/// (~67k gas of code deposit) instead of 16 fresh slots (~355k gas), and reading it back is one cold
/// EXTCODECOPY instead of up to 16 cold SLOADs.
library MilestoneCodec {
    /// @notice Size in bytes of one packed milestone.
    uint256 internal constant PACKED_SIZE = 21;

    /// @notice Packs `milestones` as `amount (16 bytes) || timestamp (5 bytes)` per entry.
    /// @param milestones Calldata milestones, already validated by the caller.
    /// @return data Packed bytes of length `21 * milestones.length`.
    function encode(Milestone[] calldata milestones) internal pure returns (bytes memory data) {
        uint256 count = milestones.length;
        uint256 size = count * PACKED_SIZE;
        // Allocate 11 spare bytes so that the 32-byte store of the last entry stays inside the allocation.
        data = new bytes(size + 11);
        for (uint256 i; i < count; ++i) {
            uint256 word = (uint256(milestones[i].amount) << 128) | (uint256(milestones[i].timestamp) << 88);
            // Safe: the store covers bytes [21 i, 21 i + 32) of the payload, which is inside the `size + 11`
            // allocation. Its 11 trailing bytes are zero and get overwritten by entry `i + 1`.
            assembly ("memory-safe") {
                mstore(add(add(data, 0x20), mul(i, 21)), word)
            }
        }
        // Safe: shrinking the length of a freshly allocated array only hides the 11 spare zero bytes.
        assembly ("memory-safe") {
            mstore(data, size)
        }
    }

    /// @notice Unpacks bytes produced by {encode}.
    /// @param data Packed milestones (length must be a multiple of 21; guaranteed by {encode}).
    /// @return milestones The decoded milestones.
    function decode(bytes memory data) internal pure returns (Milestone[] memory milestones) {
        uint256 count = data.length / PACKED_SIZE;
        milestones = new Milestone[](count);
        for (uint256 i; i < count; ++i) {
            uint256 word;
            // Safe: read-only. For the last entry the 32-byte load extends 11 bytes past `data`, but those bytes
            // are discarded by the shifts and casts below.
            assembly ("memory-safe") {
                word := mload(add(add(data, 0x20), mul(i, 21)))
            }
            milestones[i] = Milestone({amount: uint128(word >> 128), timestamp: uint40(word >> 88)});
        }
    }
}
