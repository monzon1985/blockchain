// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IVestingStreams} from "./IVestingStreams.sol";

/// @title IStreamRenderer
/// @notice Produces the fully on-chain metadata of a stream NFT.
interface IStreamRenderer {
    /// @notice ERC-721 metadata URI: `data:application/json;base64,` followed by the Base64 JSON document, whose
    /// `image` field is itself a Base64 SVG data URI.
    /// @param streams The vesting contract to read the stream from.
    /// @param streamId The stream (= NFT id) to render.
    /// @return The metadata URI.
    function tokenURI(IVestingStreams streams, uint256 streamId) external view returns (string memory);

    /// @notice The raw SVG image of a stream, exactly as embedded in {tokenURI}.
    /// @param streams The vesting contract to read the stream from.
    /// @param streamId The stream to render.
    /// @return The SVG document.
    function svgOf(IVestingStreams streams, uint256 streamId) external view returns (string memory);
}
