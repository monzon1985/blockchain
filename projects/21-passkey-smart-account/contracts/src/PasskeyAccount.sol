// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Account} from "@openzeppelin/contracts/account/Account.sol";
import {ERC7821} from "@openzeppelin/contracts/account/extensions/draft-ERC7821.sol";
import {EIP7702Utils} from "@openzeppelin/contracts/account/utils/EIP7702Utils.sol";
import {ERC4337Utils} from "@openzeppelin/contracts/account/utils/ERC4337Utils.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {IAccount, IEntryPoint, PackedUserOperation} from "@openzeppelin/contracts/interfaces/IERC4337.sol";
import {IERC7821} from "@openzeppelin/contracts/interfaces/draft-IERC7821.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {P256} from "@openzeppelin/contracts/utils/cryptography/P256.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {WebAuthn} from "@openzeppelin/contracts/utils/cryptography/WebAuthn.sol";
import {AbstractSigner} from "@openzeppelin/contracts/utils/cryptography/signers/AbstractSigner.sol";
import {SignerEIP7702} from "@openzeppelin/contracts/utils/cryptography/signers/SignerEIP7702.sol";
import {ERC7739} from "@openzeppelin/contracts/utils/cryptography/signers/draft-ERC7739.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {IPasskeyAccount} from "./interfaces/IPasskeyAccount.sol";

/// @title PasskeyAccount
/// @author Passkey Smart Account contributors
/// @notice A WebAuthn (P-256) passkey account that works both as an ERC-4337 v0.9 account deployed by
/// {PasskeyAccountFactory} and as an EIP-7702 delegate of an existing EOA.
/// @dev Design points:
/// - Signers: the passkey (WebAuthn assertion, verified through the EIP-7951 P-256 precompile with OpenZeppelin's
///   pure-Solidity fallback) and, in 7702 mode only, the EOA key itself ({SignerEIP7702}). Signatures carry a one byte
///   type prefix: `0x00` WebAuthn, `0x01` EOA ECDSA.
/// - ERC-1271 goes through ERC-7739 defensive rehashing, so a signature for one account never validates on another
///   account controlled by the same passkey.
/// - All state lives in one ERC-7201 namespace (`passkeysa.account.v1`), so re-delegating an EOA between this and
///   another implementation never reinterprets foreign storage.
/// - Initialization is never "first caller wins": only the EOA key (self-call, EntryPoint op signed by the EOA, or an
///   EIP-712 signature by the EOA) or the factory (atomically with deployment) can configure the account.
/// - Social recovery: `threshold`-of-N guardians schedule a passkey replacement that executes after a 48 hour
///   timelock; the owner can veto at any time before execution. The owner or a guardian can freeze the account for
///   7 days (each guardian once per recovery epoch). A freeze invalidates every user operation, so no ETH leaves the
///   account, not even as gas; the owner can still veto through {cancelRecoveryWithSig}, which a third party relays
///   and pays for.
contract PasskeyAccount is
    IPasskeyAccount,
    Account,
    EIP712,
    ERC7739,
    SignerEIP7702,
    ERC7821,
    ERC721Holder,
    ERC1155Holder
{
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @custom:storage-location erc7201:passkeysa.account.v1
    struct AccountStorage {
        Passkey passkey;
        bool initialized;
        uint8 threshold;
        uint48 frozenUntil;
        uint64 recoveryEpoch;
        EnumerableSet.AddressSet guardians;
        PendingRecovery pending;
        mapping(bytes32 recoveryId => uint256) approvalCount;
        mapping(bytes32 recoveryId => mapping(address guardian => bool)) approved;
        /// @dev `epoch + 1` of the recovery epoch in which the guardian last froze the account (0 = never).
        mapping(address guardian => uint64 epochPlusOne) freezeEpoch;
    }

    /// @dev `keccak256(abi.encode(uint256(keccak256("passkeysa.account.v1")) - 1)) & ~bytes32(uint256(0xff))`.
    bytes32 private constant ACCOUNT_STORAGE_SLOT = 0x1ab98a993e960ba9421ad09bc249211ba6a0e1facaa807b437fdd35018ef2000;

    /// @notice Signature type prefix for a WebAuthn assertion by the passkey.
    bytes1 public constant SIG_TYPE_WEBAUTHN = 0x00;

    /// @notice Signature type prefix for an ECDSA signature by the delegating EOA (7702 mode only).
    bytes1 public constant SIG_TYPE_EOA = 0x01;

    /// @notice Delay between a recovery reaching the guardian threshold and its execution.
    uint48 public constant RECOVERY_TIMELOCK = 48 hours;

    /// @notice Duration of an emergency freeze.
    uint48 public constant FREEZE_DURATION = 7 days;

    /// @notice Maximum number of guardians (bounds the gas of guardian enumeration).
    uint256 public constant MAX_GUARDIANS = 8;

    /// @notice EIP-712 typehash of the EOA-signed initialization message used by {initializeWithSig}.
    bytes32 public constant INITIALIZE_TYPEHASH = keccak256(
        "Initialize(bytes32 qx,bytes32 qy,bytes32 rpIdHash,address[] guardians,uint8 threshold,uint256 deadline)"
    );

    /// @notice EIP-712 typehash of a guardian's off-chain recovery approval used by {approveRecoveryWithSig}.
    bytes32 public constant RECOVERY_APPROVAL_TYPEHASH =
        keccak256("RecoveryApproval(bytes32 qx,bytes32 qy,bytes32 rpIdHash,uint64 epoch,uint256 deadline)");

    /// @notice EIP-712 typehash of the owner's relayed veto used by {cancelRecoveryWithSig}.
    bytes32 public constant CANCEL_RECOVERY_TYPEHASH = keccak256("CancelRecovery(uint64 epoch,uint256 deadline)");

    /// @notice The EntryPoint this account trusts (v0.9 in this repository).
    // slither-disable-next-line naming-convention
    IEntryPoint private immutable _ENTRY_POINT;

    /// @notice The factory allowed to initialize clones of this implementation.
    // slither-disable-next-line naming-convention
    address public immutable FACTORY;

    /// @notice Deploys the implementation and permanently locks its own storage.
    /// @dev Locking only affects the implementation address. Clones and 7702-delegating EOAs have their own storage.
    /// @param entryPoint_ The ERC-4337 EntryPoint.
    /// @param factory_ The factory allowed to initialize clones.
    /// Pass `factory_ = address(0)` for a delegation-only implementation (no clone initialization path).
    // forge-lint: disable-next-line(missing-zero-check)
    constructor(IEntryPoint entryPoint_, address factory_) EIP712("PasskeyAccount", "1") {
        require(address(entryPoint_) != address(0), InvalidEntryPoint());
        _ENTRY_POINT = entryPoint_;
        // slither-disable-next-line missing-zero-check
        FACTORY = factory_;
        _s().initialized = true;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Initialization
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Configures the account.
    /// @dev Allowed callers: the account itself (7702 EOA sending a transaction to itself, atomically with its
    /// authorization), the EntryPoint (only reachable through a user operation signed by the EOA key, because an
    /// uninitialized account has no passkey), or the factory for a clone it just deployed.
    /// @param params Passkey, guardians and threshold.
    function initialize(InitParams calldata params) external {
        address caller = msg.sender;
        bool authorized = caller == address(this) || caller == address(entryPoint())
            || (caller == FACTORY && EIP7702Utils.fetchDelegate(address(this)) == address(0));
        require(authorized, InitializerUnauthorized(caller));
        _initialize(params);
    }

    /// @notice Configures a 7702-delegated EOA from a relayed transaction, authorized by an EIP-712 signature of the EOA.
    /// @dev The signature binds chain id and `address(this)` through the domain, so it cannot be replayed on another
    /// chain (e.g. after a chainId-0 authorization is replayed there) or on another account. It is single-use because
    /// initialization happens once.
    /// @param params Passkey, guardians and threshold.
    /// @param deadline Last timestamp at which the signature is accepted.
    /// @param signature 65-byte ECDSA signature by the EOA over the `Initialize` typed data.
    function initializeWithSig(InitParams calldata params, uint256 deadline, bytes calldata signature) external {
        // Second-granularity deadline; proposer timestamp drift (~12 s) is irrelevant (docs/static-analysis.md).
        // slither-disable-next-line timestamp
        require(block.timestamp <= deadline, SignatureExpired(deadline)); // forge-lint: disable-line(block-timestamp)
        bytes32 digest = _hashTypedDataV4(
            keccak256(
                abi.encode(
                    INITIALIZE_TYPEHASH,
                    params.passkey.qx,
                    params.passkey.qy,
                    params.passkey.rpIdHash,
                    keccak256(abi.encodePacked(params.guardians)),
                    params.threshold,
                    deadline
                )
            )
        );
        require(SignerEIP7702._rawSignatureValidation(digest, signature), InvalidInitSignature());
        _initialize(params);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // ERC-4337 validation and execution
    // ---------------------------------------------------------------------------------------------------------------

    /// @inheritdoc Account
    function entryPoint() public view override returns (IEntryPoint) {
        return _ENTRY_POINT;
    }

    /// @notice ERC-7821 batch execution, callable by the EntryPoint or the account itself.
    /// @dev Blocked while the account is frozen.
    /// @param mode ERC-7821 execution mode (single batch, default exec type).
    /// @param executionData ABI-encoded `Call[]`.
    function execute(bytes32 mode, bytes calldata executionData) public payable override {
        _requireNotFrozen();
        super.execute(mode, executionData);
    }

    /// @notice ERC-1271 signature check with ERC-7739 defensive rehashing.
    /// @dev Returns the failure value while the account is frozen, so a stolen passkey cannot sign permits.
    /// @param hash The hash the application wants signed.
    /// @param signature ERC-7739 wrapped signature (typed data or personal sign).
    /// @return result `0x1626ba7e` if valid, `0xffffffff` otherwise.
    function isValidSignature(bytes32 hash, bytes calldata signature) public view override returns (bytes4 result) {
        if (_isFrozenNow()) return bytes4(0xffffffff);
        return super.isValidSignature(hash, signature);
    }

    /// @inheritdoc ERC1155Holder
    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == type(IAccount).interfaceId || interfaceId == type(IERC1271).interfaceId
            || interfaceId == type(IERC7821).interfaceId || interfaceId == type(IERC721Receiver).interfaceId
            || super.supportsInterface(interfaceId);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Owner actions (EntryPoint or self)
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Replaces the passkey.
    /// @param newPasskey The new passkey.
    function rotatePasskey(Passkey calldata newPasskey) external onlyEntryPointOrSelf {
        _requireNotFrozen();
        _setPasskey(newPasskey);
    }

    /// @notice Adds a guardian. Invalidates in-flight recovery approvals.
    /// @param guardian The guardian to add.
    function addGuardian(address guardian) external onlyEntryPointOrSelf {
        _requireNotFrozen();
        _addGuardian(guardian);
        _bumpRecoveryEpoch();
    }

    /// @notice Removes a guardian. Invalidates in-flight recovery approvals.
    /// @dev Removing the last guardian turns social recovery off: the threshold drops to 0 with it. Otherwise the
    /// threshold must still be reachable, so lower it first when needed.
    /// @param guardian The guardian to remove.
    // EnumerableSet is an internal library, not an external call (docs/static-analysis.md).
    // forge-lint: disable-next-item(reentrancy-events)
    function removeGuardian(address guardian) external onlyEntryPointOrSelf {
        _requireNotFrozen();
        AccountStorage storage $ = _s();
        require($.guardians.remove(guardian), NotGuardian(guardian));
        emit GuardianRemoved(guardian);
        uint256 count = $.guardians.length();
        if (count == 0) {
            if ($.threshold != 0) {
                $.threshold = 0;
                emit GuardianThresholdChanged(0);
            }
        } else {
            require($.threshold <= count, InvalidThreshold($.threshold, count));
        }
        _bumpRecoveryEpoch();
    }

    /// @notice Sets the number of guardian approvals needed to schedule a recovery.
    /// @param threshold The new threshold (1..guardianCount, or 0 when there are no guardians).
    function setGuardianThreshold(uint8 threshold) external onlyEntryPointOrSelf {
        _requireNotFrozen();
        _setThreshold(threshold);
        _bumpRecoveryEpoch();
    }

    /// @notice Owner veto: discards the scheduled recovery (if any) and every in-flight approval.
    /// @dev Not blocked by a freeze, but a frozen account validates no user operation, so while frozen this path is
    /// only reachable by the EOA key calling its own code (7702 mode). Everyone else uses {cancelRecoveryWithSig}.
    function cancelRecovery() external onlyEntryPointOrSelf {
        _bumpRecoveryEpoch();
    }

    /// @notice Owner veto relayed by anyone, authorized by the owner's signature over the current recovery epoch.
    /// @dev The veto that works while the account is frozen, so colluding guardians cannot freeze the owner and then
    /// recover. The relayer pays the gas and the account pays nothing, which is why a stolen passkey can at most stall
    /// a recovery and never spend the account's ETH. The signature covers the recovery epoch, which the veto bumps, so
    /// each signature works once.
    /// @param deadline Last timestamp at which the signature is accepted.
    /// @param signature Type-prefixed owner signature (as for user operations) over {cancelRecoveryDigest}.
    function cancelRecoveryWithSig(uint256 deadline, bytes calldata signature) external {
        // Second-granularity deadline; proposer timestamp drift (~12 s) is irrelevant (docs/static-analysis.md).
        // slither-disable-next-line timestamp
        require(block.timestamp <= deadline, SignatureExpired(deadline)); // forge-lint: disable-line(block-timestamp)
        require(_rawSignatureValidation(cancelRecoveryDigest(deadline), signature), InvalidVetoSignature());
        _bumpRecoveryEpoch();
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Guardian actions
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Freezes the account for {FREEZE_DURATION}. Callable by the owner path or by a guardian, each guardian
    /// once per recovery epoch.
    /// @dev A freeze can only be extended, never shortened. It ends by expiry or by an executed recovery. The per-epoch
    /// limit stops a single compromised guardian from keeping the account frozen forever: once its freeze expires the
    /// owner can remove it. The epoch moves on every veto, guardian change and executed recovery, so guardians who keep
    /// scheduling recoveries against a thief that vetoes them also regain their freezes.
    // EnumerableSet is an internal library, not an external call (docs/static-analysis.md).
    // forge-lint: disable-next-item(reentrancy-events)
    function freeze() external {
        address caller = msg.sender;
        AccountStorage storage $ = _s();
        if (caller != address(this) && caller != address(entryPoint())) {
            require($.guardians.contains(caller), FreezeUnauthorized(caller));
            uint64 epoch = $.recoveryEpoch;
            require($.freezeEpoch[caller] != epoch + 1, FreezeAlreadyUsed(caller, epoch));
            $.freezeEpoch[caller] = epoch + 1;
        }
        // uint48 timestamps overflow in the year 8.9 million.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint48 until = uint48(block.timestamp) + FREEZE_DURATION;
        if (until > $.frozenUntil) $.frozenUntil = until;
        emit Frozen(caller, $.frozenUntil);
    }

    /// @notice Approves replacing the passkey with `newPasskey`. The approval counts for the current recovery epoch.
    /// @param newPasskey The passkey the guardian wants to install.
    function approveRecovery(Passkey calldata newPasskey) external {
        require(_s().guardians.contains(msg.sender), NotGuardian(msg.sender));
        _approveRecovery(msg.sender, newPasskey);
    }

    /// @notice Relayed guardian approval, authorized by an EIP-712 signature (EOA or ERC-1271 guardian).
    /// @param newPasskey The passkey the guardian wants to install.
    /// @param guardian The approving guardian.
    /// @param deadline Last timestamp at which the signature is accepted.
    /// @param signature Guardian signature over `RecoveryApproval(qx,qy,rpIdHash,epoch,deadline)`.
    function approveRecoveryWithSig(
        Passkey calldata newPasskey,
        address guardian,
        uint256 deadline,
        bytes calldata signature
    ) external {
        // Second-granularity deadline; proposer timestamp drift (~12 s) is irrelevant (docs/static-analysis.md).
        // slither-disable-next-line timestamp
        require(block.timestamp <= deadline, SignatureExpired(deadline)); // forge-lint: disable-line(block-timestamp)
        require(_s().guardians.contains(guardian), NotGuardian(guardian));
        bytes32 digest = _hashTypedDataV4(
            keccak256(
                abi.encode(
                    RECOVERY_APPROVAL_TYPEHASH,
                    newPasskey.qx,
                    newPasskey.qy,
                    newPasskey.rpIdHash,
                    _s().recoveryEpoch,
                    deadline
                )
            )
        );
        require(SignatureChecker.isValidSignatureNow(guardian, digest, signature), InvalidGuardianSignature(guardian));
        _approveRecovery(guardian, newPasskey);
    }

    /// @notice Executes the scheduled recovery once its timelock has elapsed. Callable by anyone.
    /// @dev Installs the new passkey, lifts any freeze and bumps the recovery epoch.
    // The 48 h timelock tolerates proposer timestamp drift; P256 is an internal library (docs/static-analysis.md).
    // forge-lint: disable-next-item(block-timestamp,reentrancy-events)
    function executeRecovery() external {
        AccountStorage storage $ = _s();
        PendingRecovery memory pending = $.pending;
        require(pending.executableAt != 0, NoRecoveryScheduled());
        // slither-disable-next-line timestamp
        require(block.timestamp >= pending.executableAt, RecoveryTimelockActive(pending.executableAt));
        delete $.pending;
        if ($.frozenUntil != 0) {
            $.frozenUntil = 0;
            emit FreezeLifted();
        }
        uint64 newEpoch = ++$.recoveryEpoch;
        _setPasskey(pending.newPasskey);
        emit RecoveryEpochBumped(newEpoch, bytes32(0));
        emit RecoveryExecuted(pending.recoveryId);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Whether the account has been configured.
    /// @return True once initialized (always true for the implementation contract itself).
    function initialized() external view returns (bool) {
        return _s().initialized;
    }

    /// @notice The current passkey.
    /// @return The passkey (all zero for an uninitialized 7702 account).
    function passkey() external view returns (Passkey memory) {
        return _s().passkey;
    }

    /// @notice The guardian set.
    /// @return The guardians, in insertion order modulo removals.
    function guardians() external view returns (address[] memory) {
        return _s().guardians.values();
    }

    /// @notice Whether `account` is a guardian.
    /// @param account Address to check.
    /// @return True if `account` is a guardian.
    function isGuardian(address account) external view returns (bool) {
        return _s().guardians.contains(account);
    }

    /// @notice Guardian approvals needed to schedule a recovery.
    /// @return The threshold.
    function guardianThreshold() external view returns (uint8) {
        return _s().threshold;
    }

    /// @notice Timestamp until which the account is frozen (0 or a past value when not frozen).
    /// @return The freeze deadline.
    function frozenUntil() external view returns (uint48) {
        return _s().frozenUntil;
    }

    /// @notice Current recovery epoch. Approvals from older epochs are void.
    /// @return The epoch.
    function recoveryEpoch() external view returns (uint64) {
        return _s().recoveryEpoch;
    }

    /// @notice The scheduled recovery, if any (`executableAt == 0` means none).
    /// @return The pending recovery.
    function pendingRecovery() external view returns (PendingRecovery memory) {
        return _s().pending;
    }

    /// @notice Identifier of a recovery to `newPasskey` in the current epoch.
    /// @param newPasskey The candidate passkey.
    /// @return The recovery id guardians approve.
    function recoveryIdFor(Passkey calldata newPasskey) external view returns (bytes32) {
        return _recoveryId(newPasskey, _s().recoveryEpoch);
    }

    /// @notice Number of approvals a recovery has collected.
    /// @param recoveryId The recovery id.
    /// @return The approval count.
    function recoveryApprovals(bytes32 recoveryId) external view returns (uint256) {
        return _s().approvalCount[recoveryId];
    }

    /// @notice Whether `guardian` approved `recoveryId`.
    /// @param recoveryId The recovery id.
    /// @param guardian The guardian.
    /// @return True if approved.
    function hasApproved(bytes32 recoveryId, address guardian) external view returns (bool) {
        return _s().approved[recoveryId][guardian];
    }

    /// @notice Whether `guardian` can still freeze the account in the current recovery epoch.
    /// @param guardian The guardian.
    /// @return True if `guardian` is a guardian that has not frozen the account in this epoch.
    function freezeAvailable(address guardian) external view returns (bool) {
        AccountStorage storage $ = _s();
        return $.guardians.contains(guardian) && $.freezeEpoch[guardian] != $.recoveryEpoch + 1;
    }

    /// @notice EIP-712 digest the owner signs to veto through {cancelRecoveryWithSig} in the current recovery epoch.
    /// @param deadline Last timestamp at which the signature is accepted.
    /// @return The digest (the WebAuthn challenge, or the hash the EOA key signs in 7702 mode).
    function cancelRecoveryDigest(uint256 deadline) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(CANCEL_RECOVERY_TYPEHASH, _s().recoveryEpoch, deadline)));
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Internal: signature validation
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Adds the freeze to the validation result without reading `block.timestamp` (banned by ERC-7562 during
    /// validation): a frozen account returns `validAfter = frozenUntil` and the EntryPoint enforces the time range.
    /// No operation is exempt, the veto included. Gas is paid from the account's ETH (prefund or EntryPoint deposit)
    /// to a beneficiary the submitter picks, so any operation that stayed valid during a freeze would let a stolen
    /// passkey spend the whole balance as gas. The owner vetoes through {cancelRecoveryWithSig} instead.
    function _validateUserOp(PackedUserOperation calldata userOp, bytes32 userOpHash, bytes calldata signature)
        internal
        override
        returns (uint256)
    {
        uint256 validationData = super._validateUserOp(userOp, userOpHash, signature);
        uint48 frozen = _s().frozenUntil;
        if (validationData != ERC4337Utils.SIG_VALIDATION_SUCCESS || frozen == 0) return validationData;
        return ERC4337Utils.packValidationData(true, frozen, 0);
    }

    /// @dev Dispatches on the signature type byte. WebAuthn assertions must come from the configured passkey, carry the
    /// configured `rpIdHash`, have UP and UV set and use a low-s signature. EOA signatures are only satisfiable in 7702
    /// mode, where `address(this)` is the EOA.
    function _rawSignatureValidation(bytes32 hash, bytes calldata signature)
        internal
        view
        override(AbstractSigner, SignerEIP7702)
        returns (bool)
    {
        if (signature.length == 0) return false;
        bytes1 sigType = signature[0];
        if (sigType == SIG_TYPE_EOA) return SignerEIP7702._rawSignatureValidation(hash, signature[1:]);
        if (sigType != SIG_TYPE_WEBAUTHN) return false;

        (bool decoded, WebAuthn.WebAuthnAuth calldata auth) = WebAuthn.tryDecodeAuth(signature[1:]);
        if (!decoded) return false;
        Passkey memory key = _s().passkey;
        // authenticatorData starts with the 32-byte rpIdHash (WebAuthn L2 section 6.1). OpenZeppelin's WebAuthn library
        // deliberately skips this check; binding it here rejects assertions made for another relying party. The
        // clientDataJSON origin is not checked: any origin the browser lets use this RP id can produce valid assertions.
        if (auth.authenticatorData.length < 37 || bytes32(auth.authenticatorData[0:32]) != key.rpIdHash) return false;
        return _verifyWebAuthn(abi.encodePacked(hash), auth, key.qx, key.qy);
    }

    /// @dev Verifies a WebAuthn assertion (type, challenge, UP, UV, BE/BS consistency, low-s P-256 signature).
    /// Uses the EIP-7951 precompile when present and OpenZeppelin's pure-Solidity P-256 otherwise. Virtual so that a
    /// deployment can plug another verifier; the gas benchmark uses it to measure the pure-Solidity path in isolation.
    function _verifyWebAuthn(bytes memory challenge, WebAuthn.WebAuthnAuth calldata auth, bytes32 qx, bytes32 qy)
        internal
        view
        virtual
        returns (bool)
    {
        return WebAuthn.verify(challenge, auth, qx, qy, true);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Internal: state transitions
    // ---------------------------------------------------------------------------------------------------------------

    // The helpers below call internal libraries (EnumerableSet, P256), not external contracts, so the
    // reentrancy-events lint does not apply to their events (docs/static-analysis.md).
    // forge-lint: disable-next-item(reentrancy-events)
    function _initialize(InitParams calldata params) private {
        AccountStorage storage $ = _s();
        require(!$.initialized, AlreadyInitialized());
        $.initialized = true;
        _setPasskey(params.passkey);
        uint256 count = params.guardians.length;
        for (uint256 i = 0; i < count; ++i) {
            _addGuardian(params.guardians[i]);
        }
        _setThreshold(params.threshold);
        emit AccountInitialized(params.passkey.qx, params.passkey.qy, params.passkey.rpIdHash, count, params.threshold);
    }

    // forge-lint: disable-next-item(reentrancy-events)
    function _setPasskey(Passkey memory newPasskey) private {
        require(P256.isValidPublicKey(newPasskey.qx, newPasskey.qy), InvalidPasskey(newPasskey.qx, newPasskey.qy));
        _s().passkey = newPasskey;
        emit PasskeyChanged(newPasskey.qx, newPasskey.qy, newPasskey.rpIdHash);
    }

    // Called in the initialization loop, which must be all-or-nothing: one bad guardian aborts the whole init.
    // forge-lint: disable-next-item(reentrancy-events,require-revert-in-loop)
    function _addGuardian(address guardian) private {
        AccountStorage storage $ = _s();
        require(guardian != address(0) && guardian != address(this), InvalidGuardian(guardian));
        require($.guardians.length() < MAX_GUARDIANS, TooManyGuardians(MAX_GUARDIANS));
        require($.guardians.add(guardian), InvalidGuardian(guardian));
        emit GuardianAdded(guardian);
    }

    // forge-lint: disable-next-item(reentrancy-events)
    function _setThreshold(uint8 threshold) private {
        AccountStorage storage $ = _s();
        uint256 count = $.guardians.length();
        bool valid = count == 0 ? threshold == 0 : (threshold != 0 && threshold <= count);
        require(valid, InvalidThreshold(threshold, count));
        $.threshold = threshold;
        emit GuardianThresholdChanged(threshold);
    }

    // forge-lint: disable-next-item(reentrancy-events)
    function _approveRecovery(address guardian, Passkey calldata newPasskey) private {
        require(P256.isValidPublicKey(newPasskey.qx, newPasskey.qy), InvalidPasskey(newPasskey.qx, newPasskey.qy));
        AccountStorage storage $ = _s();
        bytes32 scheduled = $.pending.recoveryId;
        require($.pending.executableAt == 0, RecoveryAlreadyScheduled(scheduled));

        bytes32 recoveryId = _recoveryId(newPasskey, $.recoveryEpoch);
        require(!$.approved[recoveryId][guardian], AlreadyApproved(guardian, recoveryId));
        $.approved[recoveryId][guardian] = true;
        uint256 approvals = ++$.approvalCount[recoveryId];
        emit RecoveryApproved(guardian, recoveryId, approvals);

        if (approvals >= $.threshold) {
            // uint48 timestamps overflow in the year 8.9 million.
            // forge-lint: disable-next-line(unsafe-typecast)
            uint48 executableAt = uint48(block.timestamp) + RECOVERY_TIMELOCK;
            $.pending = PendingRecovery({recoveryId: recoveryId, executableAt: executableAt, newPasskey: newPasskey});
            emit RecoveryScheduled(recoveryId, executableAt);
        }
    }

    /// @dev Any change to who can recover (guardians, threshold) or an owner veto voids every in-flight approval and
    /// the scheduled recovery.
    // forge-lint: disable-next-item(reentrancy-events)
    function _bumpRecoveryEpoch() private {
        AccountStorage storage $ = _s();
        bytes32 cancelled = $.pending.recoveryId;
        delete $.pending;
        uint64 newEpoch = ++$.recoveryEpoch;
        emit RecoveryEpochBumped(newEpoch, cancelled);
    }

    function _requireNotFrozen() private view {
        uint48 until = _s().frozenUntil;
        // slither-disable-next-line timestamp
        require(block.timestamp >= until, AccountFrozen(until)); // forge-lint: disable-line(block-timestamp)
    }

    function _isFrozenNow() private view returns (bool) {
        // slither-disable-next-line timestamp
        return block.timestamp < _s().frozenUntil; // forge-lint: disable-line(block-timestamp)
    }

    function _recoveryId(Passkey calldata newPasskey, uint64 epoch) private pure returns (bytes32) {
        return keccak256(abi.encode(newPasskey.qx, newPasskey.qy, newPasskey.rpIdHash, epoch));
    }

    function _s() private pure returns (AccountStorage storage $) {
        // Assembly is the only way to point a storage reference at an ERC-7201 slot; the slot is a constant.
        // slither-disable-next-line assembly
        assembly ("memory-safe") {
            $.slot := ACCOUNT_STORAGE_SLOT
        }
    }

    /// @dev ERC-7821 execution is allowed from the EntryPoint (validated user operations) and from the account itself
    /// (batches, or the EOA key calling its own code in 7702 mode).
    // Called by OpenZeppelin's ERC7821.execute; Slither cannot build IR for that caller (docs/static-analysis.md).
    // slither-disable-next-line dead-code
    function _erc7821AuthorizedExecutor(address caller, bytes32 mode, bytes calldata executionData)
        internal
        view
        override
        returns (bool)
    {
        return caller == address(entryPoint()) || super._erc7821AuthorizedExecutor(caller, mode, executionData);
    }
}
