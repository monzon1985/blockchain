// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title SlotWriter
/// @notice Test fixture for the Trie Inspector integration tests. It writes pseudo-random
///         values to pseudo-random storage slots, so an off-chain tool that knows only the
///         seeds can rebuild the contract's entire storage trie and compare its root with the
///         storageHash returned by eth_getProof.
/// @dev Slot `i` of batch `seed` is keccak256(abi.encode(seed, i)). Its value is
///      keccak256(abi.encode(slot)) shifted right by 8 * (i % 32) bits, so successive values
///      shrink from 32 bytes to 1 byte and cover every length of an RLP storage leaf; a value
///      that would be zero becomes 1. The contract declares no state variables: every slot it
///      touches is one of these hashed locations.
contract SlotWriter {
    /// @notice Largest batch that `write` and `clear` accept, to keep one call within a block.
    uint256 public constant MAX_BATCH = 256;

    /// @notice A batch is larger than MAX_BATCH.
    /// @param count The requested number of slots.
    error BatchTooLarge(uint256 count);

    /// @notice `clear` was called with an empty or inverted range.
    /// @param from First index of the range.
    /// @param to One past the last index of the range.
    error EmptyRange(uint256 from, uint256 to);

    /// @notice A slot was written.
    /// @param slot The storage slot.
    /// @param value The value stored in it.
    event SlotWritten(bytes32 indexed slot, bytes32 value);

    /// @notice Entries `from` to `to - 1` of batch `seed` were zeroed.
    /// @param seed The batch seed.
    /// @param from First index cleared.
    /// @param to One past the last index cleared.
    event SlotsCleared(uint256 indexed seed, uint256 from, uint256 to);

    /// @notice Storage slot of entry `i` of batch `seed`.
    /// @param seed The batch seed.
    /// @param i The entry index.
    /// @return slot keccak256(abi.encode(seed, i)).
    function slotOf(uint256 seed, uint256 i) external pure returns (bytes32 slot) {
        return _slotOf(seed, i);
    }

    /// @notice Value written to `slot` as entry `i` of its batch.
    /// @param slot The storage slot.
    /// @param i The entry index, which sets how many low-order bytes the value keeps.
    /// @return value keccak256(abi.encode(slot)) >> (8 * (i % 32)), or 1 if that is zero.
    function valueOf(bytes32 slot, uint256 i) external pure returns (bytes32 value) {
        return _valueOf(slot, i);
    }

    /// @notice Writes entries 0 to `count - 1` of batch `seed`.
    /// @param seed The batch seed.
    /// @param count The number of entries, at most MAX_BATCH.
    function write(uint256 seed, uint256 count) external {
        require(count <= MAX_BATCH, BatchTooLarge(count));
        // Events first, stores second: no event follows a raw storage write.
        for (uint256 i; i < count; ++i) {
            bytes32 slot = _slotOf(seed, i);
            emit SlotWritten(slot, _valueOf(slot, i));
        }
        for (uint256 i; i < count; ++i) {
            bytes32 slot = _slotOf(seed, i);
            bytes32 value = _valueOf(slot, i);
            // Safe: writing arbitrary hashed slots is this fixture's purpose, and no Solidity
            // state variable lives at these locations.
            assembly ("memory-safe") {
                sstore(slot, value)
            }
        }
    }

    /// @notice Zeroes entries `from` to `to - 1` of batch `seed`, which removes them from the
    ///         storage trie.
    /// @param seed The batch seed.
    /// @param from First index to clear.
    /// @param to One past the last index to clear.
    function clear(uint256 seed, uint256 from, uint256 to) external {
        require(from < to, EmptyRange(from, to));
        require(to - from <= MAX_BATCH, BatchTooLarge(to - from));
        emit SlotsCleared(seed, from, to);
        for (uint256 i = from; i < to; ++i) {
            bytes32 slot = _slotOf(seed, i);
            // Safe: see `write`; storing zero deletes the slot from the trie.
            assembly ("memory-safe") {
                sstore(slot, 0)
            }
        }
    }

    function _slotOf(uint256 seed, uint256 i) private pure returns (bytes32) {
        return keccak256(abi.encode(seed, i));
    }

    function _valueOf(bytes32 slot, uint256 i) private pure returns (bytes32 value) {
        value = bytes32(uint256(keccak256(abi.encode(slot))) >> (8 * (i % 32)));
        if (value == bytes32(0)) value = bytes32(uint256(1));
    }
}
