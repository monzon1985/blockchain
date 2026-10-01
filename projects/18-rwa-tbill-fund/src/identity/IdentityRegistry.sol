// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {AccessManaged} from "@openzeppelin-contracts/access/manager/AccessManaged.sol";
import {EIP712} from "@openzeppelin-contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin-contracts/utils/cryptography/SignatureChecker.sol";
import {SafeCast} from "@openzeppelin-contracts/utils/math/SafeCast.sol";
import {IIdentityRegistry} from "../interfaces/IIdentityRegistry.sol";

/// @title IdentityRegistry
/// @notice Claims-based investor identity: wallets are bound to identities by the compliance officer, and
///         identities collect EIP-712 claims (KYC, accreditation, jurisdiction) signed by trusted issuers. A wallet
///         is verified when its identity holds a valid claim for every required topic.
/// @dev Plays the role of ERC-3643's IdentityRegistry + ClaimTopicsRegistry + TrustedIssuersRegistry, with
///      signed claims stored in the registry instead of ONCHAINID contracts. Issuers may be EOAs or ERC-1271
///      contracts (`SignatureChecker`). A claim is valid while its issuer is still trusted for the topic and
///      `block.timestamp < expiresAt`; revoked claims are deleted, so the hot path never reads a revocation list.
///      Every (identity, topic) keeps a `minIssuedAt` watermark that only moves forward: it is raised to the
///      `issuedAt` of every accepted claim, and to the current time when the stored claim is removed by the
///      compliance officer or revoked by its issuer. A claim is accepted only if it was issued strictly after the
///      watermark, so a removal or revocation cannot be undone by relaying an older claim that was signed but
///      never submitted, whether or not a valid claim is currently stored.
contract IdentityRegistry is AccessManaged, EIP712, IIdentityRegistry {
    /// @notice Signed attestation about an identity.
    /// @param identity Investor identity the claim is about.
    /// @param topic Claim topic (1..31).
    /// @param data Topic payload (for jurisdiction: ISO 3166-1 numeric country code).
    /// @param issuer Signer; must be trusted for `topic`.
    /// @param issuedAt Issuance time; must be strictly after the (identity, topic) watermark.
    /// @param expiresAt End of validity (exclusive).
    /// @param nonce Issuer-chosen serial; makes otherwise identical claims distinct.
    struct Claim {
        bytes32 identity;
        uint256 topic;
        uint32 data;
        address issuer;
        uint64 issuedAt;
        uint64 expiresAt;
        uint256 nonce;
    }

    /// @notice Claim as stored for an (identity, topic) pair.
    /// @dev Slot 0 (`issuer`, `expiresAt`, `data`) is everything the verification hot path reads. Slot 1 packs
    ///      `issuedAt` with `minIssuedAt`, the watermark, which survives removal and revocation (every other field
    ///      is zeroed then).
    struct StoredClaim {
        address issuer;
        uint64 expiresAt;
        uint32 data;
        uint64 issuedAt;
        uint64 minIssuedAt;
        bytes32 digest;
    }

    /// @notice Know-your-customer claim topic.
    uint256 public constant TOPIC_KYC = 1;
    /// @notice Accredited / qualified investor claim topic.
    uint256 public constant TOPIC_ACCREDITATION = 2;
    /// @notice Jurisdiction claim topic; `data` is the ISO 3166-1 numeric country code.
    uint256 public constant TOPIC_JURISDICTION = 3;
    /// @notice Highest claim topic accepted; bounds the verification loop.
    uint256 public constant MAX_TOPIC = 31;
    /// @notice Highest ISO 3166-1 numeric code.
    uint32 public constant MAX_COUNTRY_CODE = 999;

    /// @notice EIP-712 type hash of {Claim}.
    bytes32 public constant CLAIM_TYPEHASH = keccak256(
        "Claim(bytes32 identity,uint256 topic,uint32 data,address issuer,uint64 issuedAt,uint64 expiresAt,uint256 nonce)"
    );

    /// @notice Identity each wallet is bound to (zero if unregistered).
    mapping(address wallet => bytes32 identity) public identityOf;

    /// @notice Bitmap of topics each issuer is trusted for (bit `t` set = trusted for topic `t`).
    mapping(address issuer => uint256 topics) public trustedTopics;

    /// @notice Claim digests that were ever accepted; each signed claim can be added once.
    mapping(bytes32 digest => bool used) public claimUsed;

    /// @notice Claim digests revoked by their issuer, including claims never submitted.
    mapping(bytes32 digest => bool revoked) public claimRevoked;

    /// @notice Bitmap of topics every verified identity must hold; always includes the jurisdiction topic.
    uint256 public requiredTopics;

    /// @dev Current claim per (identity, topic).
    mapping(bytes32 identity => mapping(uint256 topic => StoredClaim)) private _claims;

    /// @notice Emitted when `wallet` is bound to `identity`.
    /// @param wallet Wallet.
    /// @param identity Identity.
    event WalletRegistered(address indexed wallet, bytes32 indexed identity);
    /// @notice Emitted when `wallet` is unbound from `identity`.
    /// @param wallet Wallet.
    /// @param identity Previous identity.
    event WalletUnregistered(address indexed wallet, bytes32 indexed identity);
    /// @notice Emitted when the topics `issuer` is trusted for change.
    /// @param issuer Issuer.
    /// @param topics New topic bitmap (zero = untrusted).
    event TrustedIssuerSet(address indexed issuer, uint256 topics);
    /// @notice Emitted when the required topic bitmap changes.
    /// @param topics New bitmap.
    event RequiredTopicsSet(uint256 topics);
    /// @notice Emitted when a claim is accepted.
    /// @param identity Identity.
    /// @param topic Topic.
    /// @param issuer Issuer.
    /// @param digest EIP-712 digest (claim id).
    /// @param data Payload.
    /// @param expiresAt Expiry.
    event ClaimAdded(
        bytes32 indexed identity,
        uint256 indexed topic,
        address indexed issuer,
        bytes32 digest,
        uint32 data,
        uint64 expiresAt
    );
    /// @notice Emitted when an issuer revokes a claim digest.
    /// @param digest Revoked digest.
    /// @param identity Identity the claim is about.
    /// @param topic Topic.
    /// @param issuer Issuer.
    /// @param wasActive True if the revoked claim was the stored claim and got deleted.
    event ClaimRevoked(
        bytes32 indexed digest, bytes32 indexed identity, uint256 indexed topic, address issuer, bool wasActive
    );
    /// @notice Emitted when the compliance officer deletes a stored claim.
    /// @param identity Identity.
    /// @param topic Topic.
    /// @param digest Digest of the removed claim.
    /// @param minIssuedAt New watermark: only claims issued after it can be added for (identity, topic).
    event ClaimRemoved(bytes32 indexed identity, uint256 indexed topic, bytes32 digest, uint64 minIssuedAt);

    /// @notice Zero wallet or zero identity.
    error InvalidRegistration(address wallet, bytes32 identity);
    /// @notice `wallet` is already bound to `identity`.
    error WalletAlreadyRegistered(address wallet, bytes32 identity);
    /// @notice `wallet` is not bound to any identity.
    error WalletNotRegistered(address wallet);
    /// @notice Topic outside `1..MAX_TOPIC`, or a bitmap with bits outside that range.
    error InvalidTopic(uint256 topic);
    /// @notice The required bitmap must include the jurisdiction topic.
    error JurisdictionTopicRequired(uint256 topics);
    /// @notice `issuer` is not trusted for `topic`.
    error UntrustedIssuer(address issuer, uint256 topic);
    /// @notice Claim validity window is empty or has not started.
    error InvalidClaimWindow(uint64 issuedAt, uint64 expiresAt, uint256 nowTs);
    /// @notice Claim already expired.
    error ClaimExpired(uint64 expiresAt, uint256 nowTs);
    /// @notice Jurisdiction claim payload is not an ISO 3166-1 numeric code.
    error InvalidCountry(uint32 data);
    /// @notice Claim about the zero identity.
    error InvalidIdentity();
    /// @notice The digest was revoked by its issuer.
    error ClaimIsRevoked(bytes32 digest);
    /// @notice The exact signed claim was already added once.
    error ClaimAlreadyUsed(bytes32 digest);
    /// @notice The claim was not issued after the (identity, topic) watermark: a claim at least as recent was
    ///         already accepted, or the stored claim was removed or revoked at or after `issuedAt`.
    error ClaimNotNewer(uint64 issuedAt, uint64 minIssuedAt);
    /// @notice The signature does not verify against `issuer`.
    error InvalidClaimSignature(address issuer, bytes32 digest);
    /// @notice Only the claim's issuer can revoke it.
    error NotClaimIssuer(address caller, address issuer);
    /// @notice No stored claim for (identity, topic).
    error NoSuchClaim(bytes32 identity, uint256 topic);

    /// @param initialAuthority AccessManager governing restricted functions.
    /// @param initialRequiredTopics Initial required topic bitmap (must include jurisdiction).
    constructor(address initialAuthority, uint256 initialRequiredTopics)
        AccessManaged(initialAuthority)
        EIP712("TBillFund IdentityRegistry", "1")
    {
        _setRequiredTopics(initialRequiredTopics);
    }

    // ---------------------------------------------------------------------------------------------
    // Compliance officer: wallet binding
    // ---------------------------------------------------------------------------------------------

    /// @notice Binds `wallet` to `identity`. A wallet belongs to at most one identity at a time.
    /// @dev Compliance officer only (deployment wiring): the transfer agent executes recoveries to wallets of
    ///      the same identity, so it must not also be able to bind wallets.
    /// @param wallet Wallet.
    /// @param identity Identity id (non-zero).
    function registerWallet(address wallet, bytes32 identity) external restricted {
        require(wallet != address(0) && identity != bytes32(0), InvalidRegistration(wallet, identity));
        bytes32 current = identityOf[wallet];
        require(current == bytes32(0), WalletAlreadyRegistered(wallet, current));
        identityOf[wallet] = identity;
        emit WalletRegistered(wallet, identity);
    }

    /// @notice Unbinds `wallet`. Holdings stay attributed to the old identity until the wallet is emptied
    ///         (the compliance engine snapshots the identity when a wallet starts holding).
    /// @param wallet Wallet.
    function unregisterWallet(address wallet) external restricted {
        bytes32 current = identityOf[wallet];
        require(current != bytes32(0), WalletNotRegistered(wallet));
        delete identityOf[wallet];
        emit WalletUnregistered(wallet, current);
    }

    // ---------------------------------------------------------------------------------------------
    // Compliance officer: trust configuration
    // ---------------------------------------------------------------------------------------------

    /// @notice Sets the topic bitmap `issuer` is trusted for; zero removes the issuer, which instantly
    ///         invalidates every claim it signed.
    /// @param issuer Issuer address (EOA or ERC-1271 contract).
    /// @param topics Topic bitmap.
    function setTrustedIssuer(address issuer, uint256 topics) external restricted {
        _validateTopicBitmap(topics);
        trustedTopics[issuer] = topics;
        emit TrustedIssuerSet(issuer, topics);
    }

    /// @notice Sets the topics a verified identity must hold.
    /// @param topics Topic bitmap; must include `TOPIC_JURISDICTION`.
    function setRequiredTopics(uint256 topics) external restricted {
        _setRequiredTopics(topics);
    }

    /// @notice Deletes the stored claim of `identity` for `topic` (e.g. sanctions hit, issuer error) and raises
    ///         the watermark to now: every claim issued up to this moment, submitted or not, can no longer be added.
    /// @param identity Identity.
    /// @param topic Topic.
    function removeClaim(bytes32 identity, uint256 topic) external restricted {
        StoredClaim storage stored = _claims[identity][topic];
        require(stored.issuer != address(0), NoSuchClaim(identity, topic));
        bytes32 digest = stored.digest;
        uint64 watermark = _clear(stored);
        emit ClaimRemoved(identity, topic, digest, watermark);
    }

    // ---------------------------------------------------------------------------------------------
    // Permissionless: claim submission and issuer self-revocation
    // ---------------------------------------------------------------------------------------------

    /// @notice Adds a claim signed by a trusted issuer. Anyone may relay it; authority comes from the signature.
    /// @dev Rejects: untrusted issuer/topic, empty or future validity window, expired claims, invalid
    ///      country codes, revoked digests, replays of an already-added digest, claims not issued strictly after
    ///      the (identity, topic) watermark, and bad signatures (EOA or ERC-1271).
    /// @param claim The signed claim.
    /// @param signature Issuer signature over the EIP-712 digest of `claim`.
    /// @return digest The claim id.
    function addClaim(Claim calldata claim, bytes calldata signature) external returns (bytes32 digest) {
        _validateClaimFields(claim);
        digest = claimDigest(claim);
        require(!claimRevoked[digest], ClaimIsRevoked(digest));
        require(!claimUsed[digest], ClaimAlreadyUsed(digest));

        uint64 watermark = _claims[claim.identity][claim.topic].minIssuedAt;
        require(claim.issuedAt > watermark, ClaimNotNewer(claim.issuedAt, watermark));
        require(
            SignatureChecker.isValidSignatureNowCalldata(claim.issuer, digest, signature),
            InvalidClaimSignature(claim.issuer, digest)
        );

        claimUsed[digest] = true;
        _claims[claim.identity][claim.topic] = StoredClaim({
            issuer: claim.issuer,
            expiresAt: claim.expiresAt,
            data: claim.data,
            issuedAt: claim.issuedAt,
            minIssuedAt: claim.issuedAt,
            digest: digest
        });
        emit ClaimAdded(claim.identity, claim.topic, claim.issuer, digest, claim.data, claim.expiresAt);
    }

    /// @notice Revokes `claim`. Callable by its issuer only, before or after it was submitted; a revoked
    ///         digest can never be added. If it is the stored claim it is deleted immediately and the watermark
    ///         is raised to now, exactly like a removal, so no older claim can take its place.
    /// @dev Revoking a claim that is not the stored one only blacklists its digest and never moves the
    ///      watermark: anyone can call this with a made-up claim that names the caller as issuer, so letting such
    ///      a call raise the watermark would let anybody block an identity's future claims.
    /// @param claim The claim to revoke.
    function revokeClaim(Claim calldata claim) external {
        require(msg.sender == claim.issuer, NotClaimIssuer(msg.sender, claim.issuer));
        bytes32 digest = claimDigest(claim);
        require(!claimRevoked[digest], ClaimIsRevoked(digest));
        claimRevoked[digest] = true;
        StoredClaim storage stored = _claims[claim.identity][claim.topic];
        bool wasActive = stored.digest == digest;
        if (wasActive) _clear(stored);
        emit ClaimRevoked(digest, claim.identity, claim.topic, claim.issuer, wasActive);
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IIdentityRegistry
    function isVerified(address wallet) external view returns (bool verified) {
        bytes32 identity = identityOf[wallet];
        if (identity == bytes32(0)) return false;
        return _hasRequiredClaims(identity);
    }

    /// @notice Whether `identity` holds a valid claim for every required topic (ignores wallet binding).
    /// @param identity Identity.
    /// @return True if all required claims are valid.
    function isIdentityVerified(bytes32 identity) external view returns (bool) {
        return _hasRequiredClaims(identity);
    }

    /// @inheritdoc IIdentityRegistry
    function investorCountry(bytes32 identity) external view returns (uint16 country) {
        StoredClaim storage stored = _claims[identity][TOPIC_JURISDICTION];
        // Jurisdiction data is range-checked to <= 999 on insertion; SafeCast documents and enforces it.
        return _isValid(stored, TOPIC_JURISDICTION) ? SafeCast.toUint16(stored.data) : 0;
    }

    /// @notice Whether the stored claim of `identity` for `topic` is currently valid.
    /// @param identity Identity.
    /// @param topic Topic.
    /// @return True if valid.
    function isClaimValid(bytes32 identity, uint256 topic) external view returns (bool) {
        return _isValid(_claims[identity][topic], topic);
    }

    /// @notice Stored claim of `identity` for `topic` (all zero if none).
    /// @param identity Identity.
    /// @param topic Topic.
    /// @return The stored claim.
    function getClaim(bytes32 identity, uint256 topic) external view returns (StoredClaim memory) {
        return _claims[identity][topic];
    }

    /// @notice EIP-712 digest of `claim` under this registry's domain (chain id and address bound).
    /// @param claim Claim.
    /// @return EIP-712 digest.
    function claimDigest(Claim calldata claim) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    CLAIM_TYPEHASH,
                    claim.identity,
                    claim.topic,
                    claim.data,
                    claim.issuer,
                    claim.issuedAt,
                    claim.expiresAt,
                    claim.nonce
                )
            )
        );
    }

    /// @notice The EIP-712 domain separator of this registry.
    /// @return Domain separator.
    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    // ---------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------

    function _hasRequiredClaims(bytes32 identity) private view returns (bool) {
        uint256 required = requiredTopics;
        for (uint256 topic = 1; topic <= MAX_TOPIC; ++topic) {
            if ((required >> topic) == 0) break;
            if ((required >> topic) & 1 == 1 && !_isValid(_claims[identity][topic], topic)) return false;
        }
        return true;
    }

    /// @dev Deletes a stored claim and sets its watermark to now. The watermark never goes down: it is the
    ///      `issuedAt` of an accepted claim (<= the time it was accepted) or an earlier removal time.
    function _clear(StoredClaim storage stored) private returns (uint64 watermark) {
        watermark = SafeCast.toUint64(block.timestamp);
        stored.issuer = address(0);
        stored.expiresAt = 0;
        stored.data = 0;
        stored.issuedAt = 0;
        stored.minIssuedAt = watermark;
        stored.digest = bytes32(0);
    }

    function _isValid(StoredClaim storage stored, uint256 topic) private view returns (bool) {
        address issuer = stored.issuer;
        return issuer != address(0) && stored.expiresAt > block.timestamp && (trustedTopics[issuer] >> topic) & 1 == 1;
    }

    function _validateClaimFields(Claim calldata claim) private view {
        require(claim.identity != bytes32(0), InvalidIdentity());
        require(claim.topic != 0 && claim.topic <= MAX_TOPIC, InvalidTopic(claim.topic));
        require((trustedTopics[claim.issuer] >> claim.topic) & 1 == 1, UntrustedIssuer(claim.issuer, claim.topic));
        require(
            claim.issuedAt < claim.expiresAt && claim.issuedAt <= block.timestamp,
            InvalidClaimWindow(claim.issuedAt, claim.expiresAt, block.timestamp)
        );
        require(claim.expiresAt > block.timestamp, ClaimExpired(claim.expiresAt, block.timestamp));
        if (claim.topic == TOPIC_JURISDICTION) {
            require(claim.data != 0 && claim.data <= MAX_COUNTRY_CODE, InvalidCountry(claim.data));
        }
    }

    function _setRequiredTopics(uint256 topics) private {
        _validateTopicBitmap(topics);
        require((topics >> TOPIC_JURISDICTION) & 1 == 1, JurisdictionTopicRequired(topics));
        requiredTopics = topics;
        emit RequiredTopicsSet(topics);
    }

    function _validateTopicBitmap(uint256 topics) private pure {
        // Bit 0 (topic 0) and bits above MAX_TOPIC are invalid.
        require(topics & 1 == 0 && topics >> (MAX_TOPIC + 1) == 0, InvalidTopic(topics));
    }
}
