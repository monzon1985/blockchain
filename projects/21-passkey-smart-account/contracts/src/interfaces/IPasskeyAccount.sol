// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title IPasskeyAccount
/// @notice Types, events and errors of the passkey-first smart account.
/// @dev Kept in a separate interface so that the factory, the tests and the off-chain tooling share one ABI.
interface IPasskeyAccount {
    /// @notice A WebAuthn credential public key bound to a relying party.
    /// @param qx X coordinate of the P-256 public key.
    /// @param qy Y coordinate of the P-256 public key.
    /// @param rpIdHash SHA-256 of the WebAuthn relying-party id. Assertions whose authenticator data carries a
    ///        different `rpIdHash` (i.e. produced for another relying party) are rejected. The origin in
    ///        `clientDataJSON` is not checked.
    struct Passkey {
        bytes32 qx;
        bytes32 qy;
        bytes32 rpIdHash;
    }

    /// @notice One-time configuration applied by the initializer.
    /// @param passkey Primary signer of the account.
    /// @param guardians Recovery guardians (EOAs or ERC-1271 contracts), at most `MAX_GUARDIANS`.
    /// @param threshold Number of guardian approvals needed to schedule a recovery (0 only when there are no guardians).
    struct InitParams {
        Passkey passkey;
        address[] guardians;
        uint8 threshold;
    }

    /// @notice A recovery that reached the guardian threshold and waits for its timelock.
    /// @param recoveryId Identifier of the approved recovery (binds the new passkey and the recovery epoch).
    /// @param executableAt Timestamp from which {executeRecovery} may be called.
    /// @param newPasskey Passkey installed when the recovery executes.
    struct PendingRecovery {
        bytes32 recoveryId;
        uint48 executableAt;
        Passkey newPasskey;
    }

    /// @notice Emitted once, when the account is configured.
    /// @param qx X coordinate of the initial passkey.
    /// @param qy Y coordinate of the initial passkey.
    /// @param rpIdHash Relying-party id hash of the initial passkey.
    /// @param guardianCount Number of guardians configured.
    /// @param threshold Guardian approval threshold.
    event AccountInitialized(bytes32 qx, bytes32 qy, bytes32 rpIdHash, uint256 guardianCount, uint8 threshold);

    /// @notice Emitted whenever the primary passkey changes (rotation or recovery).
    /// @param qx X coordinate of the new passkey.
    /// @param qy Y coordinate of the new passkey.
    /// @param rpIdHash Relying-party id hash of the new passkey.
    event PasskeyChanged(bytes32 qx, bytes32 qy, bytes32 rpIdHash);

    /// @notice Emitted when a guardian is added.
    /// @param guardian The new guardian.
    event GuardianAdded(address indexed guardian);

    /// @notice Emitted when a guardian is removed.
    /// @param guardian The removed guardian.
    event GuardianRemoved(address indexed guardian);

    /// @notice Emitted when the guardian threshold changes.
    /// @param threshold The new threshold.
    event GuardianThresholdChanged(uint8 threshold);

    /// @notice Emitted when a guardian approves a recovery.
    /// @param guardian The approving guardian.
    /// @param recoveryId The approved recovery.
    /// @param approvals Number of approvals the recovery has after this one.
    event RecoveryApproved(address indexed guardian, bytes32 indexed recoveryId, uint256 approvals);

    /// @notice Emitted when a recovery reaches the threshold and its timelock starts.
    /// @param recoveryId The scheduled recovery.
    /// @param executableAt Timestamp from which the recovery can be executed.
    event RecoveryScheduled(bytes32 indexed recoveryId, uint48 executableAt);

    /// @notice Emitted when a scheduled recovery is executed.
    /// @param recoveryId The executed recovery.
    event RecoveryExecuted(bytes32 indexed recoveryId);

    /// @notice Emitted when the recovery epoch is bumped, invalidating every in-flight approval.
    /// @param newEpoch The epoch after the bump.
    /// @param cancelledRecoveryId The scheduled recovery that was discarded (zero if none was scheduled).
    event RecoveryEpochBumped(uint64 newEpoch, bytes32 cancelledRecoveryId);

    /// @notice Emitted when the account is frozen.
    /// @param by The owner path (the account itself or the EntryPoint) or the guardian that froze the account.
    /// @param frozenUntil Timestamp until which user operations and owner actions are blocked.
    event Frozen(address indexed by, uint48 frozenUntil);

    /// @notice Emitted when an executed recovery lifts an active freeze.
    event FreezeLifted();

    /// @notice The EntryPoint address is zero.
    error InvalidEntryPoint();

    /// @notice The account was already initialized.
    error AlreadyInitialized();

    /// @notice The caller may not initialize this account.
    /// @param caller The rejected caller.
    error InitializerUnauthorized(address caller);

    /// @notice The EOA signature over the initialization parameters is invalid.
    error InvalidInitSignature();

    /// @notice A signature deadline has passed.
    /// @param deadline The expired deadline.
    error SignatureExpired(uint256 deadline);

    /// @notice The P-256 public key is not a valid curve point.
    /// @param qx X coordinate supplied.
    /// @param qy Y coordinate supplied.
    error InvalidPasskey(bytes32 qx, bytes32 qy);

    /// @notice The guardian address cannot be used (zero, the account itself, or a duplicate).
    /// @param guardian The rejected guardian.
    error InvalidGuardian(address guardian);

    /// @notice The address is not a guardian.
    /// @param account The address that is not a guardian.
    error NotGuardian(address account);

    /// @notice Adding a guardian would exceed the maximum.
    /// @param max The maximum number of guardians.
    error TooManyGuardians(uint256 max);

    /// @notice The threshold is incompatible with the guardian count.
    /// @param threshold The requested threshold.
    /// @param guardianCount The current number of guardians.
    error InvalidThreshold(uint8 threshold, uint256 guardianCount);

    /// @notice The guardian already approved this recovery.
    /// @param guardian The guardian.
    /// @param recoveryId The recovery.
    error AlreadyApproved(address guardian, bytes32 recoveryId);

    /// @notice A recovery is already scheduled; it must be executed or cancelled first.
    /// @param recoveryId The scheduled recovery.
    error RecoveryAlreadyScheduled(bytes32 recoveryId);

    /// @notice No recovery is scheduled.
    error NoRecoveryScheduled();

    /// @notice The recovery timelock has not elapsed yet.
    /// @param executableAt Timestamp from which the recovery can be executed.
    error RecoveryTimelockActive(uint48 executableAt);

    /// @notice The guardian signature over the recovery approval is invalid.
    /// @param guardian The guardian whose signature failed.
    error InvalidGuardianSignature(address guardian);

    /// @notice The account is frozen and the action is blocked.
    /// @param frozenUntil Timestamp until which the account stays frozen.
    error AccountFrozen(uint48 frozenUntil);

    /// @notice The caller is neither the owner path (EntryPoint or self) nor a guardian.
    /// @param caller The rejected caller.
    error FreezeUnauthorized(address caller);

    /// @notice The guardian already used its freeze in the current recovery epoch.
    /// @param guardian The guardian that tried to freeze again.
    /// @param epoch The recovery epoch in which the freeze was already used.
    error FreezeAlreadyUsed(address guardian, uint64 epoch);

    /// @notice The owner signature over the relayed veto is invalid (wrong signer, wrong epoch or wrong account).
    error InvalidVetoSignature();
}
