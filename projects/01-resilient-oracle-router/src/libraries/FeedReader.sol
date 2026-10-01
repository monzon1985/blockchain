// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title FeedReader
/// @notice Reads `latestRoundData()` from a Chainlink-style feed without ever reverting.
/// @dev A high-level call (`feed.latestRoundData()`, even inside `try`/`catch`) still reverts the caller when the
///      feed returns too little data, because ABI decoding happens outside the `try`. It also copies unbounded return
///      data into memory. This reader instead makes a raw `staticcall`, copies at most the five words it needs and
///      reports `ok = false` for every abnormal outcome, which is what keeps `tryGetPrice` non-reverting.
library FeedReader {
    /// @notice `bytes4(keccak256("latestRoundData()"))`.
    bytes4 internal constant LATEST_ROUND_DATA = 0xfeaf968c;

    /// @notice The five words of a `latestRoundData()` answer, widened to 256 bits.
    /// @dev Kept as full words on purpose: the router only compares `roundId` with `answeredInRound` and never
    ///      narrows them, so there is no need to validate that they fit in `uint80`.
    struct Round {
        uint256 roundId;
        int256 answer;
        uint256 startedAt;
        uint256 updatedAt;
        uint256 answeredInRound;
    }

    /// @notice Reads the latest round of `feed`.
    /// @param feed The feed to read.
    /// @return ok False if the call reverted, returned fewer than 160 bytes, or `feed` has no code.
    /// @return round The decoded round (all zero when `ok` is false).
    // slither-disable-next-line assembly
    function latestRound(address feed) internal view returns (bool ok, Round memory round) {
        bytes4 selector = LATEST_ROUND_DATA;
        // Safety: the call uses memory past the free-memory pointer as scratch space (allowed for memory-safe
        // assembly) and writes the five decoded words into `round`, which Solidity already allocated. Only 0xa0
        // bytes of return data are ever copied (return-bomb safe). A staticcall cannot modify state, so the feed
        // cannot re-enter the router. `returndatasize() >= 0xa0` guarantees the words were written by the callee;
        // a call to an address without code succeeds with empty return data and is rejected by that check.
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, selector)
            let success := staticcall(gas(), feed, ptr, 0x04, ptr, 0xa0)
            ok := and(success, iszero(lt(returndatasize(), 0xa0)))
            if ok {
                mstore(round, mload(ptr))
                mstore(add(round, 0x20), mload(add(ptr, 0x20)))
                mstore(add(round, 0x40), mload(add(ptr, 0x40)))
                mstore(add(round, 0x60), mload(add(ptr, 0x60)))
                mstore(add(round, 0x80), mload(add(ptr, 0x80)))
            }
        }
    }
}
