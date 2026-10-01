// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {AccessManaged} from "@openzeppelin-contracts/access/manager/AccessManaged.sol";
import {SafeCast} from "@openzeppelin-contracts/utils/math/SafeCast.sol";
import {IERC1643} from "../interfaces/IERC1643.sol";

/// @title DocumentRegistry
/// @notice ERC-1643 document registry for the fund (prospectus, NAV methodology, lawful orders, ...), with
///         permanent hash anchoring: the first time a content hash is registered its timestamp is recorded
///         and survives later replacement or removal of the document, giving a proof-of-existence trail.
/// @dev Lawful orders backing referenced forced transfers must be anchored here first, by the fund
///      administrator, which splits the power to seize tokens between two roles.
contract DocumentRegistry is AccessManaged, IERC1643 {
    /// @dev Current version of a document; `position` is the 1-based index in `_names` (0 = absent).
    struct Document {
        string uri;
        bytes32 documentHash;
        uint64 lastModified;
        uint32 position;
    }

    /// @notice Maximum number of live documents; bounds `getAllDocuments`.
    uint256 public constant MAX_DOCUMENTS = 256;

    /// @notice First time each content hash was registered (0 = never).
    mapping(bytes32 documentHash => uint64 anchoredAt) public anchoredAt;

    /// @dev Current documents.
    mapping(bytes32 name => Document) private _documents;
    /// @dev Keys of current documents.
    bytes32[] private _names;

    /// @notice Emitted the first time a content hash is anchored.
    /// @param documentHash Content hash.
    /// @param name Document it was first registered under.
    /// @param timestamp Anchoring time.
    event HashAnchored(bytes32 indexed documentHash, bytes32 indexed name, uint64 timestamp);

    /// @notice Empty name or zero hash.
    error InvalidDocument(bytes32 name, bytes32 documentHash);
    /// @notice No such document.
    error DocumentNotFound(bytes32 name);
    /// @notice `MAX_DOCUMENTS` reached.
    error TooManyDocuments(uint256 max);

    /// @param initialAuthority AccessManager governing restricted functions.
    constructor(address initialAuthority) AccessManaged(initialAuthority) {}

    /// @inheritdoc IERC1643
    function setDocument(bytes32 name, string calldata uri, bytes32 documentHash) external restricted {
        require(name != bytes32(0) && documentHash != bytes32(0), InvalidDocument(name, documentHash));
        Document storage doc = _documents[name];
        if (doc.position == 0) {
            require(_names.length < MAX_DOCUMENTS, TooManyDocuments(MAX_DOCUMENTS));
            _names.push(name);
            doc.position = SafeCast.toUint32(_names.length);
        }
        doc.uri = uri;
        doc.documentHash = documentHash;
        uint64 nowTs = SafeCast.toUint64(block.timestamp);
        doc.lastModified = nowTs;
        if (anchoredAt[documentHash] == 0) {
            anchoredAt[documentHash] = nowTs;
            emit HashAnchored(documentHash, name, nowTs);
        }
        emit DocumentUpdated(name, uri, documentHash);
    }

    /// @inheritdoc IERC1643
    function removeDocument(bytes32 name) external restricted {
        Document storage doc = _documents[name];
        uint256 position = doc.position;
        require(position != 0, DocumentNotFound(name));
        string memory uri = doc.uri;
        bytes32 documentHash = doc.documentHash;

        uint256 lastIndex = _names.length - 1;
        if (position - 1 != lastIndex) {
            bytes32 moved = _names[lastIndex];
            _names[position - 1] = moved;
            _documents[moved].position = SafeCast.toUint32(position);
        }
        _names.pop();
        delete _documents[name];
        emit DocumentRemoved(name, uri, documentHash);
    }

    /// @inheritdoc IERC1643
    function getDocument(bytes32 name)
        external
        view
        returns (string memory uri, bytes32 documentHash, uint256 lastModified)
    {
        Document storage doc = _documents[name];
        return (doc.uri, doc.documentHash, doc.lastModified);
    }

    /// @inheritdoc IERC1643
    function getAllDocuments() external view returns (bytes32[] memory names) {
        return _names;
    }

    /// @notice Whether `name` currently resolves to content hash `documentHash`.
    /// @param name Document key.
    /// @param documentHash Expected hash.
    /// @return True if the current version matches.
    function verifyDocument(bytes32 name, bytes32 documentHash) external view returns (bool) {
        return documentHash != bytes32(0) && _documents[name].documentHash == documentHash;
    }
}
