// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IGroth16Verifier, IPlonkVerifier, PUBLIC_SIGNALS} from "./interfaces/IVerifiers.sol";

/// @title ZkGate
/// @author zk-kyc-credential-gate (technical demonstration)
/// @notice On-chain gate for a zero-knowledge KYC credential proof. A user
///         proves, in zero knowledge, that they hold an unrevoked credential
///         from a trusted issuer attesting age >= 18 and a non-sanctioned
///         country, without revealing their identity. The gate verifies a
///         Groth16 or PLONK proof, validates every public input, burns a
///         per-scope nullifier and admits the caller to an allowlist for the
///         rest of the current epoch.
/// @dev This is a technical demonstration, NOT a compliant financial product
///      and NOT professionally audited. The gate holds no value pool.
///
///      Public signal layout (the circuit ABI):
///        [0]      nullifier       Poseidon(subjectSecret, appScope)
///        [1]      currentDate     YYYYMMDD, must equal `currentDate`
///        [2]      issuerRoot      must be an accepted issuer root
///        [3]      revocationRoot  must be an accepted revocation root
///        [4..19]  sanctioned[16]  must equal the canonical list
///        [20]     appScope        must equal `appScope()` (this gate, this epoch)
///        [21]     recipient       must equal uint160(msg.sender)
///
///      Registration semantics: the credential's properties (unrevoked,
///      unexpired, non-sanctioned, trusted issuer) are proven at registration
///      time. Because `appScope` includes the epoch, a registration lapses at
///      the end of its epoch and the holder must prove again with a fresh
///      proof (and a fresh, epoch-scoped nullifier), so a revocation, expiry,
///      sanctions change or issuer removal takes effect for existing members
///      within at most one epoch. The governor can also `deregister` an
///      account immediately.
contract ZkGate is AccessControl, ReentrancyGuardTransient {
    /// @notice BN254 scalar field modulus `r`; every public signal must be < r.
    uint256 public constant FIELD = 21888242871839275222246405745257275088548364400416034343698204186575808495617;

    /// @notice Size of each root history ring buffer (issuer and revocation).
    uint256 public constant ROOT_HISTORY = 30;

    /// @notice Number of sanctioned-country slots (matches the circuit).
    uint256 public constant SANCTIONED_COUNT = 16;

    /// @notice Upper bound on the root grace periods, so `supersededAt + grace` cannot overflow and a
    ///         superseded root can never stay acceptable for more than 30 days.
    uint256 public constant MAX_ROOT_GRACE_PERIOD = 30 days;

    /// @notice Earliest reference date the oracle may publish (YYYYMMDD).
    uint256 public constant MIN_DATE = 19000101;

    /// @notice Latest reference date the oracle may publish (YYYYMMDD); keeps `currentDate` < 2^32 so the
    ///         circuit's `Num2Bits(32)` range check can be satisfied.
    uint256 public constant MAX_DATE = 99991231;

    // Public-signal indices.
    uint256 private constant IDX_NULLIFIER = 0;
    uint256 private constant IDX_CURRENT_DATE = 1;
    uint256 private constant IDX_ISSUER_ROOT = 2;
    uint256 private constant IDX_REVOCATION_ROOT = 3;
    uint256 private constant IDX_SANCTIONED_START = 4;
    uint256 private constant IDX_APP_SCOPE = 20;
    uint256 private constant IDX_RECIPIENT = 21;

    /// @notice Role allowed to publish/invalidate roots, replace the sanctioned list and deregister accounts.
    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");

    /// @notice Role allowed to advance the reference `currentDate`.
    bytes32 public constant DATE_ORACLE_ROLE = keccak256("DATE_ORACLE_ROLE");

    /// @notice Which proof system a registration used.
    enum ProofSystem {
        Groth16,
        Plonk
    }

    /// @notice Which root history an event or error refers to.
    enum RootKind {
        Issuer,
        Revocation
    }

    /// @notice Per-root bookkeeping.
    /// @param inHistory True while the root occupies a slot of the ring buffer.
    /// @param invalidated True once the governor has invalidated the root (emergency kill switch).
    /// @param supersededAt Timestamp at which a newer root replaced it (0 while it is the latest).
    struct RootInfo {
        bool inHistory;
        bool invalidated;
        uint64 supersededAt;
    }

    /// @notice A bounded root history: the last ROOT_HISTORY published roots plus their status.
    /// @param ring The ring buffer of recently published roots (0 = empty slot).
    /// @param count Number of roots ever published (ring write cursor).
    /// @param latest The most recently published root.
    /// @param info Status of every root currently in the ring.
    struct RootHistory {
        uint256[ROOT_HISTORY] ring;
        uint256 count;
        uint256 latest;
        mapping(uint256 root => RootInfo) info;
    }

    /// @notice Immutable Groth16 verifier for the credential circuit.
    IGroth16Verifier public immutable groth16Verifier;

    /// @notice Immutable PLONK verifier for the credential circuit.
    IPlonkVerifier public immutable plonkVerifier;

    /// @notice Action identifier bound into every scope (e.g. keccak256("zk-kyc-gate:allowlist-v1")).
    bytes32 public immutable actionId;

    /// @notice Length of a registration epoch in seconds; registrations lapse at the end of their epoch.
    uint256 public immutable epochDuration;

    /// @notice How long a superseded issuer root stays acceptable, in seconds (0 = only the latest root).
    uint256 public immutable issuerRootGracePeriod;

    /// @notice How long a superseded revocation root stays acceptable, in seconds (0 = only the latest).
    /// @dev Keep this short: during the grace window a credential revoked by the newer root can still
    ///      register against the older one.
    uint256 public immutable revocationRootGracePeriod;

    /// @notice Reference date (YYYYMMDD) the proof's currentDate must match; only moves forward.
    uint256 public currentDate;

    /// @notice The canonical sanctioned-country list (ISO-3166 numeric codes).
    uint256[SANCTIONED_COUNT] private _sanctioned;

    /// @notice History and status of trusted-issuer Merkle roots.
    RootHistory private _issuerRoots;

    /// @notice History and status of revocation sparse-Merkle-tree roots.
    RootHistory private _revocationRoots;

    /// @notice Whether a scoped nullifier has already been consumed (never cleared).
    mapping(uint256 nullifier => bool used) public isNullifierUsed;

    /// @notice Timestamp at which an account's current registration lapses (0 = never registered or
    ///         deregistered). An account is registered while `block.timestamp < registeredUntil`.
    mapping(address account => uint256 until) public registeredUntil;

    /// @notice Number of successful registrations (equals the number of burned nullifiers).
    uint256 public registrationCount;

    /// @notice Emitted when a root is published.
    /// @param kind Issuer or revocation history.
    /// @param root The newly published root.
    /// @param slot The ring slot it occupies.
    event RootAdded(RootKind indexed kind, uint256 indexed root, uint256 slot);

    /// @notice Emitted when publishing a newer root starts the grace window of the previous latest root.
    /// @param kind Issuer or revocation history.
    /// @param root The root that is no longer the latest.
    /// @param acceptedUntil Timestamp after which the root is rejected.
    event RootSuperseded(RootKind indexed kind, uint256 indexed root, uint256 acceptedUntil);

    /// @notice Emitted when a root ages out of the retained history.
    /// @param kind Issuer or revocation history.
    /// @param root The evicted root.
    event RootEvicted(RootKind indexed kind, uint256 indexed root);

    /// @notice Emitted when the governor invalidates a root with immediate effect.
    /// @param kind Issuer or revocation history.
    /// @param root The invalidated root.
    event RootInvalidated(RootKind indexed kind, uint256 indexed root);

    /// @notice Emitted when the reference date is advanced.
    /// @param previousDate The prior YYYYMMDD value.
    /// @param newDate The new YYYYMMDD value.
    event CurrentDateUpdated(uint256 previousDate, uint256 newDate);

    /// @notice Emitted when the sanctioned-country list is replaced.
    /// @param list The new 16-entry list.
    event SanctionedListUpdated(uint256[SANCTIONED_COUNT] list);

    /// @notice Emitted on a successful registration.
    /// @param account The registered caller (the proof's bound recipient).
    /// @param nullifier The consumed scoped nullifier.
    /// @param epoch The epoch the registration is valid for.
    /// @param system The proof system used.
    event Registered(address indexed account, uint256 indexed nullifier, uint256 epoch, ProofSystem system);

    /// @notice Emitted when the governor removes an account from the allowlist.
    /// @param account The deregistered account.
    /// @param by The governor that removed it.
    event Deregistered(address indexed account, address indexed by);

    /// @notice A public signal is not a canonical field element (>= r).
    /// @param index The offending signal index.
    /// @param value The offending value.
    error PublicInputOutOfField(uint256 index, uint256 value);

    /// @notice The proof is bound to a different submitter than the caller (front-running guard).
    /// @param provided The recipient public signal.
    /// @param expected uint160(msg.sender).
    error RecipientMismatch(uint256 provided, uint256 expected);

    /// @notice The proof's currentDate does not match the gate's reference date.
    /// @param provided The proof's date signal.
    /// @param expected The gate's `currentDate`.
    error UnexpectedCurrentDate(uint256 provided, uint256 expected);

    /// @notice The issuer root was never published or has been evicted from the history.
    /// @param root The unknown root.
    error UnknownIssuerRoot(uint256 root);

    /// @notice The revocation root was never published or has been evicted from the history.
    /// @param root The unknown root.
    error UnknownRevocationRoot(uint256 root);

    /// @notice The root was superseded and its grace period has elapsed.
    /// @param kind Issuer or revocation history.
    /// @param root The stale root.
    /// @param supersededAt When a newer root replaced it.
    error StaleRoot(RootKind kind, uint256 root, uint256 supersededAt);

    /// @notice The root was invalidated by the governor.
    /// @param kind Issuer or revocation history.
    /// @param root The invalidated root.
    error RootWasInvalidated(RootKind kind, uint256 root);

    /// @notice The proof's sanctioned list does not match the canonical list.
    /// @param index The first mismatching slot.
    /// @param provided The proof's value in that slot.
    /// @param expected The canonical value in that slot.
    error SanctionedListMismatch(uint256 index, uint256 provided, uint256 expected);

    /// @notice The proof's appScope is not this gate's scope for the current epoch.
    /// @param provided The proof's appScope signal.
    /// @param expected `appScope()` at the time of the call.
    error UnexpectedAppScope(uint256 provided, uint256 expected);

    /// @notice The proof failed cryptographic verification.
    error InvalidProof();

    /// @notice The scoped nullifier has already been consumed (replay).
    /// @param nullifier The already-burned nullifier.
    error NullifierAlreadyUsed(uint256 nullifier);

    /// @notice A required constructor address was the zero address.
    error ZeroAddress();

    /// @notice The epoch duration must be non-zero.
    error ZeroEpochDuration();

    /// @notice A root grace period exceeds MAX_ROOT_GRACE_PERIOD.
    /// @param gracePeriod The rejected value.
    error GracePeriodTooLong(uint256 gracePeriod);

    /// @notice A root was published that is already within the retained history.
    /// @param root The duplicate root.
    error RootAlreadyKnown(uint256 root);

    /// @notice A zero root was published; zero is reserved as the empty-slot sentinel.
    error ZeroRoot();

    /// @notice The oracle published a value that is not a calendar date in [MIN_DATE, MAX_DATE].
    /// @param date The rejected value.
    error InvalidDate(uint256 date);

    /// @notice The oracle tried to move the reference date backwards.
    /// @param newDate The rejected value.
    /// @param currentDate The current reference date.
    error DateRegression(uint256 newDate, uint256 currentDate);

    /// @notice The account is not currently registered.
    /// @param account The account.
    error NotRegistered(address account);

    /// @notice Immutable and initial configuration for the gate.
    /// @param groth16Verifier The Groth16 verifier contract.
    /// @param plonkVerifier The PLONK verifier contract.
    /// @param admin Receives DEFAULT_ADMIN_ROLE, GOVERNOR_ROLE and DATE_ORACLE_ROLE.
    /// @param actionId Action identifier bound into the scope.
    /// @param epochDuration Registration epoch length in seconds (> 0).
    /// @param issuerRootGracePeriod Seconds a superseded issuer root stays acceptable (<= 30 days).
    /// @param revocationRootGracePeriod Seconds a superseded revocation root stays acceptable (<= 30 days).
    /// @param issuerRoot Initial trusted-issuer root.
    /// @param revocationRoot Initial revocation root.
    /// @param currentDate Initial reference date (YYYYMMDD).
    /// @param sanctioned Initial sanctioned-country list.
    struct GateConfig {
        address groth16Verifier;
        address plonkVerifier;
        address admin;
        bytes32 actionId;
        uint256 epochDuration;
        uint256 issuerRootGracePeriod;
        uint256 revocationRootGracePeriod;
        uint256 issuerRoot;
        uint256 revocationRoot;
        uint256 currentDate;
        uint256[SANCTIONED_COUNT] sanctioned;
    }

    /// @notice Deploy and initialise the gate.
    /// @param cfg Immutable verifiers/scope/epoch/grace settings plus the initial governance state.
    constructor(GateConfig memory cfg) {
        if (cfg.groth16Verifier == address(0) || cfg.plonkVerifier == address(0) || cfg.admin == address(0)) {
            revert ZeroAddress();
        }
        if (cfg.epochDuration == 0) revert ZeroEpochDuration();
        if (cfg.issuerRootGracePeriod > MAX_ROOT_GRACE_PERIOD) revert GracePeriodTooLong(cfg.issuerRootGracePeriod);
        if (cfg.revocationRootGracePeriod > MAX_ROOT_GRACE_PERIOD) {
            revert GracePeriodTooLong(cfg.revocationRootGracePeriod);
        }

        groth16Verifier = IGroth16Verifier(cfg.groth16Verifier);
        plonkVerifier = IPlonkVerifier(cfg.plonkVerifier);
        actionId = cfg.actionId;
        epochDuration = cfg.epochDuration;
        issuerRootGracePeriod = cfg.issuerRootGracePeriod;
        revocationRootGracePeriod = cfg.revocationRootGracePeriod;

        _grantRole(DEFAULT_ADMIN_ROLE, cfg.admin);
        _grantRole(GOVERNOR_ROLE, cfg.admin);
        _grantRole(DATE_ORACLE_ROLE, cfg.admin);

        _addRoot(_issuerRoots, RootKind.Issuer, cfg.issuerRoot);
        _addRoot(_revocationRoots, RootKind.Revocation, cfg.revocationRoot);
        _setCurrentDate(cfg.currentDate);
        _setSanctionedList(cfg.sanctioned);
    }

    // ---------------------------------------------------------------------
    // Registration
    // ---------------------------------------------------------------------

    /// @notice Register the caller using a Groth16 proof of the credential statement.
    /// @param a Proof element A.
    /// @param b Proof element B.
    /// @param c Proof element C.
    /// @param pub The 22 public signals in circuit order (recipient must be the caller).
    function registerWithGroth16(
        uint256[2] calldata a,
        uint256[2][2] calldata b,
        uint256[2] calldata c,
        uint256[PUBLIC_SIGNALS] calldata pub
    ) external nonReentrant {
        uint256 epoch = _validatePublicInputs(pub);
        if (!groth16Verifier.verifyProof(a, b, c, pub)) revert InvalidProof();
        _consume(pub[IDX_NULLIFIER], epoch, ProofSystem.Groth16);
    }

    /// @notice Register the caller using a PLONK proof of the credential statement.
    /// @param proof The 24-word PLONK proof.
    /// @param pub The 22 public signals in circuit order (recipient must be the caller).
    function registerWithPlonk(uint256[24] calldata proof, uint256[PUBLIC_SIGNALS] calldata pub) external nonReentrant {
        uint256 epoch = _validatePublicInputs(pub);
        if (!plonkVerifier.verifyProof(proof, pub)) revert InvalidProof();
        _consume(pub[IDX_NULLIFIER], epoch, ProofSystem.Plonk);
    }

    // ---------------------------------------------------------------------
    // Governance
    // ---------------------------------------------------------------------

    /// @notice Publish a new trusted-issuer Merkle root; the previous latest root enters its grace period.
    /// @param root The issuer root to trust.
    function addIssuerRoot(uint256 root) external onlyRole(GOVERNOR_ROLE) {
        _addRoot(_issuerRoots, RootKind.Issuer, root);
    }

    /// @notice Publish a new revocation root; the previous latest root enters its (short) grace period.
    /// @param root The revocation root to trust.
    function addRevocationRoot(uint256 root) external onlyRole(GOVERNOR_ROLE) {
        _addRoot(_revocationRoots, RootKind.Revocation, root);
    }

    /// @notice Stop accepting an issuer root immediately (e.g. it contains a compromised issuer).
    /// @dev Invalidating the latest root pauses registration until a new root is published.
    /// @param root The issuer root to invalidate.
    function invalidateIssuerRoot(uint256 root) external onlyRole(GOVERNOR_ROLE) {
        _invalidateRoot(_issuerRoots, RootKind.Issuer, root);
    }

    /// @notice Stop accepting a revocation root immediately (e.g. it omits an urgent revocation).
    /// @dev Invalidating the latest root pauses registration until a new root is published.
    /// @param root The revocation root to invalidate.
    function invalidateRevocationRoot(uint256 root) external onlyRole(GOVERNOR_ROLE) {
        _invalidateRoot(_revocationRoots, RootKind.Revocation, root);
    }

    /// @notice Advance the reference date proofs must attest against.
    /// @param newDate The new YYYYMMDD value; must be a calendar date in [MIN_DATE, MAX_DATE] and >= currentDate.
    function setCurrentDate(uint256 newDate) external onlyRole(DATE_ORACLE_ROLE) {
        _setCurrentDate(newDate);
    }

    /// @notice Replace the canonical sanctioned-country list.
    /// @param list The new 16-entry list of ISO-3166 numeric codes.
    function setSanctionedList(uint256[SANCTIONED_COUNT] calldata list) external onlyRole(GOVERNOR_ROLE) {
        _setSanctionedList(list);
    }

    /// @notice Remove an account from the allowlist with immediate effect. Its nullifier stays burned, so
    ///         the same credential cannot re-register at this gate during the current epoch.
    /// @param account The account to remove.
    function deregister(address account) external onlyRole(GOVERNOR_ROLE) {
        if (!isRegistered(account)) revert NotRegistered(account);
        registeredUntil[account] = 0;
        emit Deregistered(account, msg.sender);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @notice Whether `account` is currently on the allowlist (registered this epoch, not deregistered).
    /// @param account The account to query.
    /// @return registered True iff the account's registration has not lapsed.
    function isRegistered(address account) public view returns (bool registered) {
        // Epoch boundaries are days apart; a validator's few seconds of timestamp drift is irrelevant.
        // slither-disable-start timestamp
        // forge-lint: disable-next-line(block-timestamp)
        registered = block.timestamp < registeredUntil[account];
        // slither-disable-end timestamp
    }

    /// @notice The current registration epoch, `block.timestamp / epochDuration`.
    /// @return epoch The epoch number.
    function currentEpoch() public view returns (uint256 epoch) {
        epoch = block.timestamp / epochDuration;
    }

    /// @notice The scope a proof must use in `epoch`:
    ///         `keccak256(abi.encode(block.chainid, address(this), actionId, epoch)) % FIELD`.
    /// @dev Binding this gate's address stops proofs made for a clone (same actionId, other address) from
    ///      being replayed here; binding the epoch makes registrations lapse. Derived only from chain data,
    ///      never from proof bytes (Groth16 proofs are malleable).
    /// @param epoch The epoch number.
    /// @return scope The scope scalar (< FIELD).
    function scopeForEpoch(uint256 epoch) public view returns (uint256 scope) {
        // Not randomness: `% FIELD` reduces a domain-separation hash into the SNARK scalar field, and every
        // input is public by design (slither's weak-prng heuristic only sees a timestamp-derived epoch).
        // slither-disable-next-line weak-prng
        scope = uint256(keccak256(abi.encode(block.chainid, address(this), actionId, epoch))) % FIELD;
    }

    /// @notice The scope a proof submitted now must use (this gate, the current epoch).
    /// @return scope The scope scalar.
    function appScope() public view returns (uint256 scope) {
        scope = scopeForEpoch(currentEpoch());
    }

    /// @notice Whether a proof against `root` would currently pass the issuer-root check.
    /// @param root The issuer root.
    /// @return accepted True iff the root is in the history, not invalidated, and latest or within grace.
    function isAcceptedIssuerRoot(uint256 root) external view returns (bool accepted) {
        accepted = _rootAccepted(_issuerRoots.info[root], issuerRootGracePeriod);
    }

    /// @notice Whether a proof against `root` would currently pass the revocation-root check.
    /// @param root The revocation root.
    /// @return accepted True iff the root is in the history, not invalidated, and latest or within grace.
    function isAcceptedRevocationRoot(uint256 root) external view returns (bool accepted) {
        accepted = _rootAccepted(_revocationRoots.info[root], revocationRootGracePeriod);
    }

    /// @notice Status of an issuer root.
    /// @param root The issuer root.
    /// @return info Its RootInfo (all zero if unknown).
    function issuerRootInfo(uint256 root) external view returns (RootInfo memory info) {
        info = _issuerRoots.info[root];
    }

    /// @notice Status of a revocation root.
    /// @param root The revocation root.
    /// @return info Its RootInfo (all zero if unknown).
    function revocationRootInfo(uint256 root) external view returns (RootInfo memory info) {
        info = _revocationRoots.info[root];
    }

    /// @notice The most recently published issuer root.
    /// @return root The latest issuer root.
    function latestIssuerRoot() external view returns (uint256 root) {
        root = _issuerRoots.latest;
    }

    /// @notice The most recently published revocation root.
    /// @return root The latest revocation root.
    function latestRevocationRoot() external view returns (uint256 root) {
        root = _revocationRoots.latest;
    }

    /// @notice Return the canonical sanctioned-country list.
    /// @return list The 16-entry list.
    function sanctionedList() external view returns (uint256[SANCTIONED_COUNT] memory list) {
        list = _sanctioned;
    }

    /// @notice Return the retained issuer root history (ring buffer order, 0 = empty slot).
    /// @return roots The ring buffer contents.
    function issuerRoots() external view returns (uint256[ROOT_HISTORY] memory roots) {
        roots = _issuerRoots.ring;
    }

    /// @notice Return the retained revocation root history (ring buffer order, 0 = empty slot).
    /// @return roots The ring buffer contents.
    function revocationRoots() external view returns (uint256[ROOT_HISTORY] memory roots) {
        roots = _revocationRoots.ring;
    }

    // ---------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------

    /// @dev Validate every public signal: field range, then semantic binding. Returns the current epoch.
    function _validatePublicInputs(uint256[PUBLIC_SIGNALS] calldata pub) internal view returns (uint256 epoch) {
        // Field range check on every signal. The verifier would merely return
        // false for >= r; we fail early with a precise error instead.
        for (uint256 i = 0; i < PUBLIC_SIGNALS; ++i) {
            // Intentional fail-fast: report the exact offending index/value.
            // forge-lint: disable-next-line(require-revert-in-loop)
            if (pub[i] >= FIELD) revert PublicInputOutOfField(i, pub[i]);
        }

        uint256 sender = uint256(uint160(msg.sender));
        if (pub[IDX_RECIPIENT] != sender) revert RecipientMismatch(pub[IDX_RECIPIENT], sender);

        if (pub[IDX_CURRENT_DATE] != currentDate) {
            revert UnexpectedCurrentDate(pub[IDX_CURRENT_DATE], currentDate);
        }

        _requireAcceptedRoot(_issuerRoots, RootKind.Issuer, pub[IDX_ISSUER_ROOT], issuerRootGracePeriod);
        _requireAcceptedRoot(_revocationRoots, RootKind.Revocation, pub[IDX_REVOCATION_ROOT], revocationRootGracePeriod);

        for (uint256 i = 0; i < SANCTIONED_COUNT; ++i) {
            uint256 provided = pub[IDX_SANCTIONED_START + i];
            uint256 expected = _sanctioned[i];
            // Intentional fail-fast: report the exact mismatching slot.
            // forge-lint: disable-next-line(require-revert-in-loop)
            if (provided != expected) revert SanctionedListMismatch(i, provided, expected);
        }

        epoch = currentEpoch();
        uint256 scope = scopeForEpoch(epoch);
        // The scope depends on block.timestamp only through the epoch number (epochs are days long).
        // slither-disable-next-line timestamp
        if (pub[IDX_APP_SCOPE] != scope) revert UnexpectedAppScope(pub[IDX_APP_SCOPE], scope);
    }

    /// @dev Burn the nullifier and admit the caller until the end of `epoch`.
    function _consume(uint256 nullifier, uint256 epoch, ProofSystem system) internal {
        if (isNullifierUsed[nullifier]) revert NullifierAlreadyUsed(nullifier);
        isNullifierUsed[nullifier] = true;
        registeredUntil[msg.sender] = (epoch + 1) * epochDuration;
        ++registrationCount;
        emit Registered(msg.sender, nullifier, epoch, system);
    }

    /// @dev Whether a root with this status is currently acceptable.
    function _rootAccepted(RootInfo memory info, uint256 grace) internal view returns (bool) {
        if (!info.inHistory || info.invalidated) return false;
        // Grace windows are hours/days; validator timestamp drift (seconds) cannot matter.
        // slither-disable-start timestamp
        // forge-lint: disable-next-line(block-timestamp)
        return info.supersededAt == 0 || block.timestamp < uint256(info.supersededAt) + grace;
        // slither-disable-end timestamp
    }

    /// @dev Revert with the precise reason if `root` is not currently acceptable.
    function _requireAcceptedRoot(RootHistory storage h, RootKind kind, uint256 root, uint256 grace) internal view {
        RootInfo memory info = h.info[root];
        if (!info.inHistory) {
            if (kind == RootKind.Issuer) revert UnknownIssuerRoot(root);
            revert UnknownRevocationRoot(root);
        }
        if (info.invalidated) revert RootWasInvalidated(kind, root);
        // Grace windows are hours/days; validator timestamp drift (seconds) cannot matter.
        // slither-disable-start timestamp
        // forge-lint: disable-next-line(block-timestamp)
        bool expired = info.supersededAt != 0 && block.timestamp >= uint256(info.supersededAt) + grace;
        if (expired) revert StaleRoot(kind, root, info.supersededAt);
        // slither-disable-end timestamp
    }

    /// @dev Insert `root` into a history ring, evicting the oldest and superseding the previous latest.
    function _addRoot(RootHistory storage h, RootKind kind, uint256 root) internal {
        if (root == 0) revert ZeroRoot();
        if (h.info[root].inHistory) revert RootAlreadyKnown(root);

        uint256 slot = h.count % ROOT_HISTORY;
        uint256 evicted = h.ring[slot];
        if (evicted != 0) {
            delete h.info[evicted];
            emit RootEvicted(kind, evicted);
        }

        uint256 previous = h.latest;
        // `previous` is never the evicted root while ROOT_HISTORY > 1, so its info is still live.
        if (previous != 0) {
            // casting to 'uint64' is safe because block timestamps stay below 2^64 for ~5.8e11 years.
            // forge-lint: disable-next-line(unsafe-typecast)
            h.info[previous].supersededAt = uint64(block.timestamp);
            uint256 grace = kind == RootKind.Issuer ? issuerRootGracePeriod : revocationRootGracePeriod;
            emit RootSuperseded(kind, previous, block.timestamp + grace);
        }

        h.ring[slot] = root;
        h.info[root] = RootInfo({inHistory: true, invalidated: false, supersededAt: 0});
        h.latest = root;
        unchecked {
            // Cursor increments once per governance call; overflow is unreachable.
            ++h.count;
        }
        emit RootAdded(kind, root, slot);
    }

    /// @dev Mark a root in the history as invalidated.
    function _invalidateRoot(RootHistory storage h, RootKind kind, uint256 root) internal {
        RootInfo storage info = h.info[root];
        if (!info.inHistory) {
            if (kind == RootKind.Issuer) revert UnknownIssuerRoot(root);
            revert UnknownRevocationRoot(root);
        }
        if (info.invalidated) revert RootWasInvalidated(kind, root);
        info.invalidated = true;
        emit RootInvalidated(kind, root);
    }

    /// @dev Validate and set the reference date, then emit the change.
    function _setCurrentDate(uint256 newDate) internal {
        if (!_isCalendarDate(newDate)) revert InvalidDate(newDate);
        uint256 previous = currentDate;
        if (newDate < previous) revert DateRegression(newDate, previous);
        currentDate = newDate;
        emit CurrentDateUpdated(previous, newDate);
    }

    /// @dev True iff `d` is a real YYYYMMDD calendar date in [MIN_DATE, MAX_DATE] (Gregorian leap years).
    function _isCalendarDate(uint256 d) internal pure returns (bool) {
        if (d < MIN_DATE || d > MAX_DATE) return false;
        uint256 year = d / 10000;
        uint256 month = (d / 100) % 100;
        uint256 day = d % 100;
        if (month < 1 || month > 12 || day < 1) return false;
        uint256 daysInMonth;
        if (month == 2) {
            bool leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0;
            daysInMonth = leap ? 29 : 28;
        } else if (month == 4 || month == 6 || month == 9 || month == 11) {
            daysInMonth = 30;
        } else {
            daysInMonth = 31;
        }
        return day <= daysInMonth;
    }

    /// @dev Replace the sanctioned list and emit the change.
    function _setSanctionedList(uint256[SANCTIONED_COUNT] memory list) internal {
        _sanctioned = list;
        emit SanctionedListUpdated(list);
    }
}
