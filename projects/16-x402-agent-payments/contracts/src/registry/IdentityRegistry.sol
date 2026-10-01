// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721URIStorage} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";

/// @title IdentityRegistry
/// @notice ERC-8004-style identity registry. Each agent is an ERC-721 token whose `tokenURI` (the `agentURI`)
///         resolves to an agent card listing its services; the local stack uses self-contained `data:` URIs so
///         discovery works offline. The reserved `agentWallet` is the agent's payment address: it starts as the
///         owner, can only be changed with a signature from the new wallet, and is cleared on transfer.
///
///         Two additions make wallets usable as the anchor of receipt-backed reputation:
///         - Every wallet change is checkpointed by block timestamp, so a receipt is checked against the wallet that
///           was in force when it settled ({wasAgentWalletAt}). An owner cannot void past receipts, and so censor the
///           feedback they back, by rotating or clearing the wallet.
///         - A wallet serves at most one agent at a time ({WalletInUse}), so a receipt paid to a wallet identifies
///           the agent it paid and cannot back feedback on a sibling agent of the same operator.
/// @dev Follows the ERC-8004 draft interface for `register`, metadata, `setAgentURI` and agent wallets. The EIP-712
///      struct for wallet changes is not fixed by the draft; this registry uses
///      `SetAgentWallet(uint256 agentId,address newWallet,address owner,uint256 nonce,uint256 deadline)` with a
///      per-wallet nonce. Deviation: the registrant becomes the wallet only if it does not already serve another
///      agent (otherwise the new agent starts without a wallet). Tokens are minted with `_mint` (no receiver
///      callback) because the registrant is the caller itself.
contract IdentityRegistry is ERC721URIStorage, EIP712, Nonces {
    using Checkpoints for Checkpoints.Trace160;

    /// @notice ERC-8004 metadata entry.
    /// @param metadataKey Key (any string except `agentWallet`).
    /// @param metadataValue Opaque value.
    struct MetadataEntry {
        string metadataKey;
        bytes metadataValue;
    }

    /// @notice EIP-712 type hash authorizing a wallet change.
    bytes32 public constant SET_AGENT_WALLET_TYPEHASH =
        keccak256("SetAgentWallet(uint256 agentId,address newWallet,address owner,uint256 nonce,uint256 deadline)");

    /// @dev keccak256 of the reserved metadata key.
    bytes32 private constant AGENT_WALLET_KEY_HASH = keccak256("agentWallet");

    /// @notice Last agent id minted (ids start at 1).
    uint256 private _lastAgentId;

    /// @dev Free-form metadata.
    mapping(uint256 agentId => mapping(string key => bytes value)) private _metadata;

    /// @dev Verified payment address history per agent, keyed by block timestamp; the latest value is the current
    ///      wallet (zero when unset). Several changes within one second keep only the last one.
    mapping(uint256 agentId => Checkpoints.Trace160) private _walletHistory;

    /// @dev Agent currently paid at each wallet (0 = none).
    mapping(address wallet => uint256 agentId) private _walletAgent;

    /// @notice Emitted on registration.
    /// @param agentId New agent id.
    /// @param agentURI Agent card URI.
    /// @param owner Registrant.
    event Registered(uint256 indexed agentId, string agentURI, address indexed owner);

    /// @notice Emitted when metadata is set.
    /// @param agentId Agent id.
    /// @param indexedMetadataKey Indexed copy of the key.
    /// @param metadataKey The key.
    /// @param metadataValue The value.
    event MetadataSet(
        uint256 indexed agentId, string indexed indexedMetadataKey, string metadataKey, bytes metadataValue
    );

    /// @notice Emitted when the agent card URI changes.
    /// @param agentId Agent id.
    /// @param newURI New URI.
    /// @param updatedBy Caller.
    event URIUpdated(uint256 indexed agentId, string newURI, address indexed updatedBy);

    /// @notice Emitted whenever the payment address changes (including clearing on transfer).
    /// @param agentId Agent id.
    /// @param wallet New wallet (zero when cleared).
    event AgentWalletSet(uint256 indexed agentId, address indexed wallet);

    /// @notice `agentWallet` cannot be written through generic metadata.
    error ReservedMetadataKey();

    /// @notice The wallet-change signature expired.
    /// @param deadline Signature deadline.
    error SignatureExpired(uint256 deadline);

    /// @notice The new wallet did not sign the change.
    /// @param wallet The wallet.
    error InvalidWalletSignature(address wallet);

    /// @notice Zero address given as wallet.
    error ZeroWallet();

    /// @notice The wallet already receives payments for another agent.
    /// @param wallet The wallet.
    /// @param agentId The agent it serves.
    error WalletInUse(address wallet, uint256 agentId);

    constructor() ERC721("ERC-8004 Agent Identity (local)", "AGENT") EIP712("IdentityRegistry", "1") {}

    /// @notice Registers an agent with a card URI and metadata.
    /// @param agentURI Agent card URI.
    /// @param metadata Initial metadata (must not contain `agentWallet`).
    /// @return agentId The new agent id.
    function register(string calldata agentURI, MetadataEntry[] calldata metadata) external returns (uint256 agentId) {
        agentId = _register(agentURI);
        for (uint256 i = 0; i < metadata.length; ++i) {
            _setMetadata(agentId, metadata[i].metadataKey, metadata[i].metadataValue);
        }
    }

    /// @notice Registers an agent with a card URI.
    /// @param agentURI Agent card URI.
    /// @return agentId The new agent id.
    function register(string calldata agentURI) external returns (uint256 agentId) {
        return _register(agentURI);
    }

    /// @notice Registers an agent without a card (URI can be set later).
    /// @return agentId The new agent id.
    function register() external returns (uint256 agentId) {
        return _register("");
    }

    /// @notice Updates the agent card URI. Owner or approved operator only.
    /// @param agentId Agent id.
    /// @param newURI New URI.
    function setAgentURI(uint256 agentId, string calldata newURI) external {
        _checkAuthorized(_requireOwned(agentId), msg.sender, agentId);
        _setTokenURI(agentId, newURI);
        emit URIUpdated(agentId, newURI, msg.sender);
    }

    /// @notice Sets a metadata entry. Owner or approved operator only.
    /// @param agentId Agent id.
    /// @param metadataKey Key (not `agentWallet`).
    /// @param metadataValue Value.
    function setMetadata(uint256 agentId, string calldata metadataKey, bytes calldata metadataValue) external {
        _checkAuthorized(_requireOwned(agentId), msg.sender, agentId);
        _setMetadata(agentId, metadataKey, metadataValue);
    }

    /// @notice Changes the payment address. Owner or approved operator only, with the new wallet's EIP-712 (EOA)
    ///         or ERC-1271 (contract) consent. The wallet must not serve another agent.
    /// @param agentId Agent id.
    /// @param newWallet New payment address.
    /// @param deadline Signature expiry (inclusive).
    /// @param signature `newWallet`'s signature over {SET_AGENT_WALLET_TYPEHASH}.
    function setAgentWallet(uint256 agentId, address newWallet, uint256 deadline, bytes calldata signature) external {
        address owner = _requireOwned(agentId);
        _checkAuthorized(owner, msg.sender, agentId);
        require(newWallet != address(0), ZeroWallet());
        uint256 holder = _walletAgent[newWallet];
        require(holder == 0 || holder == agentId, WalletInUse(newWallet, holder));
        require(block.timestamp <= deadline, SignatureExpired(deadline));
        bytes32 digest = _hashTypedDataV4(
            keccak256(abi.encode(SET_AGENT_WALLET_TYPEHASH, agentId, newWallet, owner, _useNonce(newWallet), deadline))
        );
        require(SignatureChecker.isValidSignatureNow(newWallet, digest, signature), InvalidWalletSignature(newWallet));
        _setWallet(agentId, newWallet);
    }

    /// @notice Clears the payment address. Owner or approved operator only. Receipts paid to the previous wallet
    ///         keep backing feedback (see {wasAgentWalletAt}).
    /// @param agentId Agent id.
    function unsetAgentWallet(uint256 agentId) external {
        _checkAuthorized(_requireOwned(agentId), msg.sender, agentId);
        _setWallet(agentId, address(0));
    }

    /// @notice The agent's verified payment address (zero if unset or cleared by a transfer).
    /// @param agentId Agent id.
    /// @return The wallet.
    function getAgentWallet(uint256 agentId) external view returns (address) {
        _requireOwned(agentId);
        return address(_walletHistory[agentId].latest());
    }

    /// @notice The agent's payment address at the end of second `timestamp` (zero if none was set then).
    /// @param agentId Agent id.
    /// @param timestamp Unix time in seconds.
    /// @return The wallet in force at that time.
    function getAgentWalletAt(uint256 agentId, uint256 timestamp) public view returns (address) {
        _requireOwned(agentId);
        return address(_walletHistory[agentId].upperLookupRecent(SafeCast.toUint96(timestamp)));
    }

    /// @notice Whether `wallet` was `agentId`'s payment address at `timestamp`: at the end of that second, or at
    ///         the end of the previous one. The second case covers a change made in the same block after the
    ///         payment; the wallet at the end of the previous second is the one a payer read before paying.
    /// @dev Used by the reputation registry with a receipt's `settledAt`. Only the last of several changes within
    ///      one second is kept, so a wallet that was set and replaced inside a single second is not matched.
    /// @param agentId Agent id.
    /// @param wallet Candidate wallet (zero never matches).
    /// @param timestamp Unix time in seconds (typically a receipt's `settledAt`).
    /// @return True if `wallet` was in force at `timestamp`.
    function wasAgentWalletAt(uint256 agentId, address wallet, uint256 timestamp) external view returns (bool) {
        if (wallet == address(0)) return false;
        if (getAgentWalletAt(agentId, timestamp) == wallet) return true;
        return timestamp != 0 && getAgentWalletAt(agentId, timestamp - 1) == wallet;
    }

    /// @notice The agent currently paid at `wallet`.
    /// @param wallet Wallet address.
    /// @return The agent id (0 if the wallet serves no agent).
    function agentOfWallet(address wallet) external view returns (uint256) {
        return _walletAgent[wallet];
    }

    /// @notice Reads a metadata entry.
    /// @param agentId Agent id.
    /// @param metadataKey Key.
    /// @return The value (empty if unset).
    function getMetadata(uint256 agentId, string calldata metadataKey) external view returns (bytes memory) {
        _requireOwned(agentId);
        return _metadata[agentId][metadataKey];
    }

    /// @notice Number of agents ever registered; ids are `1..totalAgents()`.
    /// @return The count.
    function totalAgents() external view returns (uint256) {
        return _lastAgentId;
    }

    /// @notice Whether `account` is the owner or an approved operator of `agentId`.
    /// @param agentId Agent id.
    /// @param account Account to test.
    /// @return True if authorized.
    function isOwnerOrOperator(uint256 agentId, address account) external view returns (bool) {
        return _isAuthorized(_requireOwned(agentId), account, agentId);
    }

    /// @notice EIP-712 digest a wallet signs to become `agentId`'s payment address.
    /// @param agentId Agent id.
    /// @param newWallet Wallet.
    /// @param deadline Signature expiry.
    /// @return The digest for the wallet's current nonce.
    function agentWalletDigest(uint256 agentId, address newWallet, uint256 deadline) external view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    SET_AGENT_WALLET_TYPEHASH, agentId, newWallet, _requireOwned(agentId), nonces(newWallet), deadline
                )
            )
        );
    }

    /// @dev Clears the payment address on every transfer between two non-zero owners.
    function _update(address to, uint256 tokenId, address auth) internal override returns (address from) {
        from = super._update(to, tokenId, auth);
        if (from != address(0) && to != from && _walletHistory[tokenId].latest() != 0) {
            _setWallet(tokenId, address(0));
        }
    }

    function _register(string memory agentURI) private returns (uint256 agentId) {
        agentId = ++_lastAgentId;
        _mint(msg.sender, agentId);
        if (bytes(agentURI).length != 0) _setTokenURI(agentId, agentURI);
        emit Registered(agentId, agentURI, msg.sender);
        // The registrant becomes the payment address unless it already receives payments for another agent.
        if (_walletAgent[msg.sender] == 0) _setWallet(agentId, msg.sender);
    }

    /// @dev Moves `agentId`'s payment address to `newWallet` (zero clears it) and checkpoints the change.
    function _setWallet(uint256 agentId, address newWallet) private {
        address oldWallet = address(_walletHistory[agentId].latest());
        if (oldWallet != address(0)) delete _walletAgent[oldWallet];
        if (newWallet != address(0)) _walletAgent[newWallet] = agentId;
        // The key is the block timestamp, never user input, so keys only grow and fit in 96 bits.
        // slither-disable-next-line unused-return (the previous and new values are not needed)
        _walletHistory[agentId].push(SafeCast.toUint96(block.timestamp), uint160(newWallet));
        emit AgentWalletSet(agentId, newWallet);
    }

    function _setMetadata(uint256 agentId, string calldata metadataKey, bytes calldata metadataValue) private {
        require(keccak256(bytes(metadataKey)) != AGENT_WALLET_KEY_HASH, ReservedMetadataKey());
        _metadata[agentId][metadataKey] = metadataValue;
        emit MetadataSet(agentId, metadataKey, metadataKey, metadataValue);
    }
}
