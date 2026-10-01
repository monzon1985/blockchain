// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title ISchnorrVault
/// @notice Types, events and errors of the threshold-custody vault. Every privileged
///         action is an EIP-712 typed message signed by the FROST group key.
interface ISchnorrVault {
    // ---------------------------------------------------------------------
    // Typed messages (EIP-712 domain: name "SchnorrVault", version "1")
    // ---------------------------------------------------------------------

    /// @notice Moves `amount` of `token` (address(0) = ETH) to `to`.
    /// @param to Recipient; must not be the zero address.
    /// @param token ERC-20 token, or address(0) for native ETH.
    /// @param amount Amount in the token's smallest unit; must be non-zero.
    /// @param nonce Unordered nonce shared by all intent types (bitmap).
    /// @param deadline Last timestamp (inclusive) at which the intent is valid.
    struct WithdrawalIntent {
        address to;
        address token;
        uint256 amount;
        uint256 nonce;
        uint256 deadline;
    }

    /// @notice Replaces the group key. Signed by the current key and by the new key.
    /// @param newPubKeyX x-coordinate of the new group key, in [1, Q-1].
    /// @param newPubKeyYParity 0 for even y, 1 for odd y.
    /// @param nonce Unordered nonce.
    /// @param deadline Last valid timestamp.
    struct KeyRotation {
        uint256 newPubKeyX;
        uint8 newPubKeyYParity;
        uint256 nonce;
        uint256 deadline;
    }

    /// @notice Changes a token's daily withdrawal limit. Decreases apply immediately,
    ///         increases after `LIMIT_INCREASE_DELAY`.
    /// @param token Token whose limit changes (address(0) = ETH).
    /// @param newLimit New limit per UTC day, at most type(uint128).max.
    /// @param nonce Unordered nonce.
    /// @param deadline Last valid timestamp.
    struct DailyLimitUpdate {
        address token;
        uint256 newLimit;
        uint256 nonce;
        uint256 deadline;
    }

    /// @notice Replaces the guardian (the Ownable2Step owner) after GUARDIAN_CHANGE_DELAY.
    /// @param newGuardian New guardian; must not be the zero address.
    /// @param nonce Unordered nonce.
    /// @param deadline Last valid timestamp.
    struct GuardianUpdate {
        address newGuardian;
        uint256 nonce;
        uint256 deadline;
    }

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    /// @notice ETH was sent to the vault.
    /// @param from Sender.
    /// @param amount Wei received.
    event Deposited(address indexed from, uint256 amount);

    /// @notice A signed withdrawal intent was executed.
    /// @param nonce Nonce consumed by the intent.
    /// @param token Token withdrawn (address(0) = ETH).
    /// @param to Recipient.
    /// @param amount Amount transferred.
    event Withdrawn(
        uint256 indexed nonce, address indexed token, address indexed to, uint256 amount
    );

    /// @notice The group key was rotated.
    /// @param epoch New key epoch (incremented on every rotation).
    /// @param oldPubKeyX Previous key x-coordinate.
    /// @param oldPubKeyYParity Previous key parity.
    /// @param newPubKeyX New key x-coordinate.
    /// @param newPubKeyYParity New key parity.
    /// @param nonce Nonce consumed by the rotation.
    event GroupKeyRotated(
        uint64 indexed epoch,
        uint256 oldPubKeyX,
        uint8 oldPubKeyYParity,
        uint256 newPubKeyX,
        uint8 newPubKeyYParity,
        uint256 nonce
    );

    /// @notice A token's effective daily limit was set by the constructor or by activating a
    ///         queued increase.
    /// @param token Token whose limit changed.
    /// @param oldLimit Previous limit.
    /// @param newLimit New limit.
    event DailyLimitUpdated(address indexed token, uint256 oldLimit, uint256 newLimit);

    /// @notice A signed update lowered (or re-confirmed) a token's daily limit with immediate
    ///         effect. Like every other group-signed event it names the nonce it consumed, so
    ///         signers and indexers can tell which signed intents are spent.
    /// @param token Token whose limit changed.
    /// @param oldLimit Previous limit.
    /// @param newLimit New limit (at most `oldLimit`).
    /// @param nonce Nonce consumed by the update.
    event DailyLimitDecreased(
        address indexed token, uint256 oldLimit, uint256 newLimit, uint256 nonce
    );

    /// @notice A limit increase was queued behind the time lock.
    /// @param token Token whose limit will increase.
    /// @param newLimit Limit that becomes activatable at `effectiveAt`.
    /// @param effectiveAt Timestamp from which `activateDailyLimit` succeeds.
    /// @param nonce Nonce consumed by the update.
    event DailyLimitIncreaseQueued(
        address indexed token, uint256 newLimit, uint64 effectiveAt, uint256 nonce
    );

    /// @notice A pending limit increase was cancelled by the guardian or superseded by
    ///         a signed decrease.
    /// @param token Token whose pending increase was dropped.
    /// @param cancelledLimit The limit that will not take effect.
    event DailyLimitIncreaseCancelled(address indexed token, uint256 cancelledLimit);

    /// @notice A signed GuardianUpdate was queued behind the time lock.
    /// @param newGuardian Guardian that takes over on activation.
    /// @param effectiveAt Timestamp from which `activateGuardianReplacement` succeeds.
    /// @param nonce Nonce consumed by the update.
    event GuardianReplacementQueued(address indexed newGuardian, uint64 effectiveAt, uint256 nonce);

    /// @notice A queued guardian replacement took effect.
    /// @param previousGuardian Guardian before the replacement.
    /// @param newGuardian Guardian after the replacement.
    event GuardianReplacedByGroup(address indexed previousGuardian, address indexed newGuardian);

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    /// @notice The Schnorr signature does not verify under the current group key.
    /// @param digest EIP-712 digest that was checked.
    error InvalidSignature(bytes32 digest);

    /// @notice The rotation was not also signed by the new key (proof of possession).
    /// @param digest EIP-712 digest that the new key had to sign.
    error InvalidProofOfPossession(bytes32 digest);

    /// @notice The nonce was already consumed by an earlier intent.
    /// @param nonce The replayed nonce.
    error NonceAlreadyUsed(uint256 nonce);

    /// @notice The intent's deadline has passed.
    /// @param deadline Deadline in the intent.
    /// @param timestamp Current block timestamp.
    error IntentExpired(uint256 deadline, uint256 timestamp);

    /// @notice The withdrawal exceeds what is left of today's limit.
    /// @param token Token being withdrawn.
    /// @param requested Amount requested.
    /// @param remaining Amount still available in the current UTC day.
    error DailyLimitExceeded(address token, uint256 requested, uint256 remaining);

    /// @notice The key cannot be verified with the ecrecover trick.
    /// @param pubKeyX Rejected x-coordinate.
    /// @param pubKeyYParity Rejected parity.
    error InvalidGroupKey(uint256 pubKeyX, uint8 pubKeyYParity);

    /// @notice A rotation to the key that is already active.
    error RotationToSameKey();

    /// @notice A rotation to a key that was active before; retired keys stay retired.
    /// @param pubKeyX Retired key x-coordinate.
    /// @param pubKeyYParity Retired key parity.
    error KeyRetired(uint256 pubKeyX, uint8 pubKeyYParity);

    /// @notice The withdrawal recipient is the zero address.
    error ZeroRecipient();

    /// @notice The withdrawal amount is zero.
    error ZeroAmount();

    /// @notice The requested limit does not fit the packed usage accounting.
    /// @param limit Requested limit.
    /// @param max Maximum accepted limit.
    error LimitTooLarge(uint256 limit, uint256 max);

    /// @notice No limit increase is queued for the token.
    /// @param token Token queried.
    error NoPendingIncrease(address token);

    /// @notice The queued increase is still time-locked.
    /// @param token Token queried.
    /// @param effectiveAt Timestamp from which activation succeeds.
    /// @param timestamp Current block timestamp.
    error IncreaseNotMature(address token, uint64 effectiveAt, uint256 timestamp);

    /// @notice Constructor arrays differ in length.
    /// @param tokens Length of the token array.
    /// @param limits Length of the limit array.
    error LengthMismatch(uint256 tokens, uint256 limits);

    /// @notice The guardian cannot be removed, only replaced.
    error RenounceDisabled();

    /// @notice The zero address cannot be the guardian.
    error ZeroGuardian();

    /// @notice No guardian replacement is queued.
    error NoPendingGuardianReplacement();

    /// @notice The queued guardian replacement is still time-locked.
    /// @param effectiveAt Timestamp from which activation succeeds.
    /// @param timestamp Current block timestamp.
    error GuardianReplacementNotMature(uint64 effectiveAt, uint256 timestamp);

    /// @notice The queued change was authorised by a key that has since been rotated out.
    /// @param queuedEpoch Key epoch that queued the change.
    /// @param currentEpoch Current key epoch.
    error QueuedUnderRetiredKey(uint64 queuedEpoch, uint64 currentEpoch);
}
