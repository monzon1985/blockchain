// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title IERC1643
/// @notice Document management (ERC-1643, part of the ERC-1400 security-token family).
interface IERC1643 {
    /// @notice Emitted when document `name` is created or replaced.
    /// @param name Document key.
    /// @param uri Off-chain location.
    /// @param documentHash Content hash anchored on-chain.
    event DocumentUpdated(bytes32 indexed name, string uri, bytes32 documentHash);

    /// @notice Emitted when document `name` is removed.
    /// @param name Document key.
    /// @param uri Last off-chain location.
    /// @param documentHash Last content hash.
    event DocumentRemoved(bytes32 indexed name, string uri, bytes32 documentHash);

    /// @notice Returns the current version of document `name`.
    /// @param name Document key.
    /// @return uri Off-chain location.
    /// @return documentHash Content hash.
    /// @return lastModified Timestamp of the last update.
    function getDocument(bytes32 name)
        external
        view
        returns (string memory uri, bytes32 documentHash, uint256 lastModified);

    /// @notice Creates or replaces document `name`.
    /// @param name Document key.
    /// @param uri Off-chain location.
    /// @param documentHash Content hash (non-zero).
    function setDocument(bytes32 name, string calldata uri, bytes32 documentHash) external;

    /// @notice Removes document `name`.
    /// @param name Document key.
    function removeDocument(bytes32 name) external;

    /// @notice Keys of all current documents.
    /// @return names Document keys.
    function getAllDocuments() external view returns (bytes32[] memory names);
}
