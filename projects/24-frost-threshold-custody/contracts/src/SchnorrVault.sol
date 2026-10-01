// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

import {ISchnorrVault} from "./ISchnorrVault.sol";
import {SchnorrSecp256k1} from "./SchnorrSecp256k1.sol";

/// @title SchnorrVault
/// @notice Holds ETH and ERC-20 tokens on behalf of a t-of-n FROST group. The group key
///         is a single secp256k1 point; every withdrawal, limit change, key rotation and
///         guardian change is an EIP-712 intent signed by that key and verified with one
///         `ecrecover` (see SchnorrSecp256k1). Anyone may relay a signed intent.
/// @dev Defence in depth on top of the threshold signature:
///      - unordered nonces (bitmap) and inclusive deadlines on every intent;
///      - per-token limits per UTC day, with increases time-locked by LIMIT_INCREASE_DELAY;
///      - a guardian (Ownable2Step owner) that can pause withdrawals and cancel queued
///        limit increases but can never move funds; the group can replace the guardian,
///        but only after GUARDIAN_CHANGE_DELAY, so a stolen group key cannot silence the
///        guardian before it reacts;
///      - key rotation requires a signature from the new key as proof of possession,
///        retired keys can never be re-activated, and every change queued under a
///        retired key becomes void.
contract SchnorrVault is ISchnorrVault, EIP712, Ownable2Step, Pausable, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @notice EIP-712 type hash of WithdrawalIntent.
    bytes32 public constant WITHDRAWAL_TYPEHASH = keccak256(
        "WithdrawalIntent(address to,address token,uint256 amount,uint256 nonce,uint256 deadline)"
    );

    /// @notice EIP-712 type hash of KeyRotation.
    bytes32 public constant KEY_ROTATION_TYPEHASH = keccak256(
        "KeyRotation(uint256 newPubKeyX,uint8 newPubKeyYParity,uint256 nonce,uint256 deadline)"
    );

    /// @notice EIP-712 type hash of DailyLimitUpdate.
    bytes32 public constant DAILY_LIMIT_UPDATE_TYPEHASH = keccak256(
        "DailyLimitUpdate(address token,uint256 newLimit,uint256 nonce,uint256 deadline)"
    );

    /// @notice EIP-712 type hash of GuardianUpdate.
    bytes32 public constant GUARDIAN_UPDATE_TYPEHASH =
        keccak256("GuardianUpdate(address newGuardian,uint256 nonce,uint256 deadline)");

    /// @notice Time lock applied to every daily-limit increase.
    uint256 public constant LIMIT_INCREASE_DELAY = 2 days;

    /// @notice Time lock applied to a guardian replacement queued by the group.
    uint256 public constant GUARDIAN_CHANGE_DELAY = 2 days;

    /// @notice Largest accepted daily limit (a queued limit is packed with its activation
    ///         time and key epoch into one storage slot).
    uint256 public constant MAX_DAILY_LIMIT = type(uint128).max;

    /// @notice Sentinel token address that denotes native ETH.
    address public constant NATIVE_TOKEN = address(0);

    /// @notice Active group key and its rotation counter.
    /// @param x x-coordinate of the group key, in [1, Q-1].
    /// @param yParity 0 for even y, 1 for odd y.
    /// @param epoch Number of rotations performed so far.
    struct GroupKey {
        uint256 x;
        uint8 yParity;
        uint64 epoch;
    }

    /// @notice Amount withdrawn during `day` (days since the Unix epoch, UTC).
    /// @param day UTC day the counter refers to.
    /// @param spent Amount withdrawn during that day.
    struct DailyUsage {
        uint64 day;
        uint192 spent;
    }

    /// @notice A queued daily-limit increase.
    /// @param newLimit Limit that takes effect on activation.
    /// @param effectiveAt Earliest activation timestamp.
    /// @param keyEpoch Key epoch that authorised it; void after a rotation.
    struct PendingLimit {
        uint128 newLimit;
        uint64 effectiveAt;
        uint64 keyEpoch;
    }

    /// @notice A queued guardian replacement.
    /// @param guardian Guardian that takes over on activation.
    /// @param effectiveAt Earliest activation timestamp.
    /// @param keyEpoch Key epoch that authorised it; void after a rotation.
    struct PendingGuardian {
        address guardian;
        uint64 effectiveAt;
        uint64 keyEpoch;
    }

    /// @notice The group key that authorises every intent.
    GroupKey internal _groupKey;

    /// @notice Used-nonce bitmap: bit `nonce & 255` of word `nonce >> 8`.
    mapping(uint256 wordPosition => uint256 bitmap) public nonceBitmap;

    /// @notice Effective withdrawal limit per UTC day for each token.
    mapping(address token => uint256 limit) public dailyLimit;

    /// @notice Withdrawal accounting for the most recent UTC day with activity.
    mapping(address token => DailyUsage usage) internal _usage;

    /// @notice Limit increases waiting for their time lock.
    mapping(address token => PendingLimit pending) public pendingLimit;

    /// @notice Keys replaced by a rotation, by `keccak256(abi.encode(x, yParity))`.
    ///         A retired key can never be re-activated, so every signature it ever
    ///         produced is permanently void.
    mapping(bytes32 keyId => bool retired) public retiredKey;

    /// @notice Guardian replacement waiting for its time lock.
    PendingGuardian public pendingGuardian;

    /// @notice Deploys the vault for an existing FROST group.
    /// @param pubKeyX x-coordinate of the group key produced by the DKG.
    /// @param pubKeyYParity Parity of the group key.
    /// @param initialGuardian Address allowed to pause withdrawals and cancel limit increases.
    /// @param tokens Tokens with an initial daily limit (address(0) = ETH).
    /// @param limits Initial daily limits, index-aligned with `tokens`.
    constructor(
        uint256 pubKeyX,
        uint8 pubKeyYParity,
        address initialGuardian,
        address[] memory tokens,
        uint256[] memory limits
    ) EIP712("SchnorrVault", "1") Ownable(initialGuardian) {
        _requireValidKey(pubKeyX, pubKeyYParity);
        require(tokens.length == limits.length, LengthMismatch(tokens.length, limits.length));
        _groupKey = GroupKey({x: pubKeyX, yParity: pubKeyYParity, epoch: 0});
        for (uint256 i = 0; i < tokens.length; ++i) {
            // Rejecting the whole deployment on one bad limit is intended.
            // forge-lint: disable-next-line(require-revert-in-loop)
            require(limits[i] <= MAX_DAILY_LIMIT, LimitTooLarge(limits[i], MAX_DAILY_LIMIT));
            dailyLimit[tokens[i]] = limits[i];
            emit DailyLimitUpdated(tokens[i], 0, limits[i]);
        }
    }

    /// @notice Accepts ETH deposits.
    receive() external payable {
        emit Deposited(msg.sender, msg.value);
    }

    // ---------------------------------------------------------------------
    // Group-authorised actions (relayable by anyone)
    // ---------------------------------------------------------------------

    /// @notice Executes a withdrawal signed by the group.
    /// @param intent The signed withdrawal.
    /// @param signature FROST aggregate signature over `hashWithdrawal(intent)`.
    function withdraw(
        WithdrawalIntent calldata intent,
        SchnorrSecp256k1.Signature calldata signature
    ) external nonReentrant whenNotPaused {
        require(intent.to != address(0), ZeroRecipient());
        require(intent.amount != 0, ZeroAmount());
        _consumeAuthorization(hashWithdrawal(intent), intent.nonce, intent.deadline, signature);
        _consumeDailyLimit(intent.token, intent.amount);

        emit Withdrawn(intent.nonce, intent.token, intent.to, intent.amount);

        if (intent.token == NATIVE_TOKEN) {
            // The destination is fixed by the group-signed intent (and bounded by the
            // daily limit); paying a caller-chosen address is the purpose of withdraw.
            // forge-lint: disable-next-line(arbitrary-send-eth)
            Address.sendValue(payable(intent.to), intent.amount);
        } else {
            IERC20(intent.token).safeTransfer(intent.to, intent.amount);
        }
    }

    /// @notice Rotates the group key. The rotation must be signed by the current key
    ///         (authorisation) and by the new key (proof of possession).
    /// @param rotation The signed rotation.
    /// @param currentKeySignature Signature by the current group key.
    /// @param newKeySignature Signature by the new group key over the same digest.
    function rotateGroupKey(
        KeyRotation calldata rotation,
        SchnorrSecp256k1.Signature calldata currentKeySignature,
        SchnorrSecp256k1.Signature calldata newKeySignature
    ) external {
        _requireValidKey(rotation.newPubKeyX, rotation.newPubKeyYParity);
        GroupKey memory old = _groupKey;
        require(
            rotation.newPubKeyX != old.x || rotation.newPubKeyYParity != old.yParity,
            RotationToSameKey()
        );
        require(
            !retiredKey[keyId(rotation.newPubKeyX, rotation.newPubKeyYParity)],
            KeyRetired(rotation.newPubKeyX, rotation.newPubKeyYParity)
        );
        bytes32 digest = hashKeyRotation(rotation);
        _consumeAuthorization(digest, rotation.nonce, rotation.deadline, currentKeySignature);
        require(
            SchnorrSecp256k1.verify(
                rotation.newPubKeyX, rotation.newPubKeyYParity, digest, newKeySignature
            ),
            InvalidProofOfPossession(digest)
        );

        uint64 epoch = old.epoch + 1;
        retiredKey[keyId(old.x, old.yParity)] = true;
        _groupKey =
            GroupKey({x: rotation.newPubKeyX, yParity: rotation.newPubKeyYParity, epoch: epoch});
        emit GroupKeyRotated(
            epoch,
            old.x,
            old.yParity,
            rotation.newPubKeyX,
            rotation.newPubKeyYParity,
            rotation.nonce
        );
    }

    /// @notice Changes a daily limit. Decreases (and equal values) apply immediately and
    ///         drop any queued increase; increases are queued for LIMIT_INCREASE_DELAY.
    /// @param update The signed limit change.
    /// @param signature Signature by the group key.
    function updateDailyLimit(
        DailyLimitUpdate calldata update,
        SchnorrSecp256k1.Signature calldata signature
    ) external {
        require(update.newLimit <= MAX_DAILY_LIMIT, LimitTooLarge(update.newLimit, MAX_DAILY_LIMIT));
        _consumeAuthorization(
            hashDailyLimitUpdate(update), update.nonce, update.deadline, signature
        );

        uint256 current = dailyLimit[update.token];
        if (update.newLimit <= current) {
            _dropPendingIncrease(update.token);
            dailyLimit[update.token] = update.newLimit;
            emit DailyLimitDecreased(update.token, current, update.newLimit, update.nonce);
        } else {
            // casting to 'uint64' is safe because block.timestamp is far below 2^64 - 2 days
            // forge-lint: disable-next-line(unsafe-typecast)
            uint64 effectiveAt = uint64(block.timestamp + LIMIT_INCREASE_DELAY);
            pendingLimit[update.token] = PendingLimit({
                // casting to 'uint128' is safe because newLimit <= MAX_DAILY_LIMIT
                // == type(uint128).max was checked above
                // forge-lint: disable-next-line(unsafe-typecast)
                newLimit: uint128(update.newLimit),
                effectiveAt: effectiveAt,
                keyEpoch: _groupKey.epoch
            });
            emit DailyLimitIncreaseQueued(update.token, update.newLimit, effectiveAt, update.nonce);
        }
    }

    /// @notice Queues a guardian replacement that anyone can activate after
    ///         GUARDIAN_CHANGE_DELAY. Lets the group recover from a lost or malicious
    ///         guardian (for example one that keeps the vault paused). The current guardian
    ///         cannot cancel it; a newer signed update or a key rotation supersedes it.
    /// @param update The signed guardian change.
    /// @param signature Signature by the group key.
    function queueGuardianReplacement(
        GuardianUpdate calldata update,
        SchnorrSecp256k1.Signature calldata signature
    ) external {
        require(update.newGuardian != address(0), ZeroGuardian());
        _consumeAuthorization(hashGuardianUpdate(update), update.nonce, update.deadline, signature);
        // casting to 'uint64' is safe because block.timestamp is far below 2^64 - 2 days
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 effectiveAt = uint64(block.timestamp + GUARDIAN_CHANGE_DELAY);
        pendingGuardian = PendingGuardian({
            guardian: update.newGuardian, effectiveAt: effectiveAt, keyEpoch: _groupKey.epoch
        });
        emit GuardianReplacementQueued(update.newGuardian, effectiveAt, update.nonce);
    }

    // ---------------------------------------------------------------------
    // Permissionless
    // ---------------------------------------------------------------------

    /// @notice Applies a queued limit increase once its time lock has elapsed.
    /// @param token Token whose pending increase is activated.
    function activateDailyLimit(address token) external {
        PendingLimit memory pending = pendingLimit[token];
        require(pending.effectiveAt != 0, NoPendingIncrease(token));
        uint64 epoch = _groupKey.epoch;
        require(pending.keyEpoch == epoch, QueuedUnderRetiredKey(pending.keyEpoch, epoch));
        require(
            block.timestamp >= pending.effectiveAt,
            IncreaseNotMature(token, pending.effectiveAt, block.timestamp)
        );
        delete pendingLimit[token];
        uint256 current = dailyLimit[token];
        dailyLimit[token] = pending.newLimit;
        emit DailyLimitUpdated(token, current, pending.newLimit);
    }

    /// @notice Applies a queued guardian replacement once its time lock has elapsed.
    function activateGuardianReplacement() external {
        PendingGuardian memory pending = pendingGuardian;
        require(pending.effectiveAt != 0, NoPendingGuardianReplacement());
        uint64 epoch = _groupKey.epoch;
        require(pending.keyEpoch == epoch, QueuedUnderRetiredKey(pending.keyEpoch, epoch));
        require(
            block.timestamp >= pending.effectiveAt,
            GuardianReplacementNotMature(pending.effectiveAt, block.timestamp)
        );
        delete pendingGuardian;
        address previous = owner();
        // Ownable2Step._transferOwnership also clears any pending two-step transfer.
        _transferOwnership(pending.guardian);
        emit GuardianReplacedByGroup(previous, pending.guardian);
    }

    // ---------------------------------------------------------------------
    // Guardian
    // ---------------------------------------------------------------------

    /// @notice Blocks withdrawals. Rotations and limit changes remain available so the
    ///         group can respond to an incident.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Re-enables withdrawals.
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Cancels a queued limit increase.
    /// @param token Token whose pending increase is cancelled.
    function cancelDailyLimitIncrease(address token) external onlyOwner {
        require(pendingLimit[token].effectiveAt != 0, NoPendingIncrease(token));
        _dropPendingIncrease(token);
    }

    /// @notice Disabled: the guardian can be replaced but never removed.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @notice Returns the active group key.
    /// @return x x-coordinate of the key.
    /// @return yParity Parity of the key.
    /// @return epoch Number of rotations performed so far.
    function groupKey() external view returns (uint256 x, uint8 yParity, uint64 epoch) {
        GroupKey memory key = _groupKey;
        return (key.x, key.yParity, key.epoch);
    }

    /// @notice Identifier of a key in `retiredKey`.
    /// @param x Key x-coordinate.
    /// @param yParity Key parity.
    /// @return `keccak256(abi.encode(x, yParity))`.
    function keyId(uint256 x, uint8 yParity) public pure returns (bytes32) {
        return keccak256(abi.encode(x, yParity));
    }

    /// @notice Returns the guardian (alias of `owner()`).
    /// @return The current guardian.
    function guardian() external view returns (address) {
        return owner();
    }

    /// @notice Returns whether `nonce` has been consumed.
    /// @param nonce Nonce to query.
    /// @return True if an intent with this nonce was executed.
    function isNonceUsed(uint256 nonce) external view returns (bool) {
        return nonceBitmap[nonce >> 8] & (1 << (nonce & 0xff)) != 0;
    }

    /// @notice Amount of `token` withdrawn during the current UTC day.
    /// @param token Token to query.
    /// @return spent Amount withdrawn today.
    function spentToday(address token) public view returns (uint256 spent) {
        DailyUsage memory usage = _usage[token];
        return usage.day == _today() ? usage.spent : 0;
    }

    /// @notice Amount of `token` that can still be withdrawn during the current UTC day.
    /// @param token Token to query.
    /// @return remaining Remaining allowance (zero if the limit was lowered below usage).
    function remainingToday(address token) public view returns (uint256 remaining) {
        uint256 limit = dailyLimit[token];
        uint256 spent = spentToday(token);
        return limit > spent ? limit - spent : 0;
    }

    /// @notice EIP-712 digest of a withdrawal intent.
    /// @param intent The intent.
    /// @return The digest the group signs.
    function hashWithdrawal(WithdrawalIntent calldata intent) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    WITHDRAWAL_TYPEHASH,
                    intent.to,
                    intent.token,
                    intent.amount,
                    intent.nonce,
                    intent.deadline
                )
            )
        );
    }

    /// @notice EIP-712 digest of a key rotation.
    /// @param rotation The rotation.
    /// @return The digest both keys sign.
    function hashKeyRotation(KeyRotation calldata rotation) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    KEY_ROTATION_TYPEHASH,
                    rotation.newPubKeyX,
                    rotation.newPubKeyYParity,
                    rotation.nonce,
                    rotation.deadline
                )
            )
        );
    }

    /// @notice EIP-712 digest of a daily-limit update.
    /// @param update The update.
    /// @return The digest the group signs.
    function hashDailyLimitUpdate(DailyLimitUpdate calldata update) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    DAILY_LIMIT_UPDATE_TYPEHASH,
                    update.token,
                    update.newLimit,
                    update.nonce,
                    update.deadline
                )
            )
        );
    }

    /// @notice EIP-712 digest of a guardian update.
    /// @param update The update.
    /// @return The digest the group signs.
    function hashGuardianUpdate(GuardianUpdate calldata update) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    GUARDIAN_UPDATE_TYPEHASH, update.newGuardian, update.nonce, update.deadline
                )
            )
        );
    }

    /// @notice EIP-712 domain separator (chain id and address bound).
    /// @return The domain separator.
    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    // ---------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------

    /// @dev Checks deadline, nonce freshness and the group signature, then burns the nonce.
    function _consumeAuthorization(
        bytes32 digest,
        uint256 nonce,
        uint256 deadline,
        SchnorrSecp256k1.Signature calldata signature
    ) internal {
        require(block.timestamp <= deadline, IntentExpired(deadline, block.timestamp));
        uint256 wordPosition = nonce >> 8;
        uint256 bit = 1 << (nonce & 0xff);
        uint256 bitmap = nonceBitmap[wordPosition];
        require(bitmap & bit == 0, NonceAlreadyUsed(nonce));
        GroupKey memory key = _groupKey;
        require(
            SchnorrSecp256k1.verify(key.x, key.yParity, digest, signature), InvalidSignature(digest)
        );
        nonceBitmap[wordPosition] = bitmap | bit;
    }

    /// @dev Charges `amount` against today's allowance for `token`.
    function _consumeDailyLimit(address token, uint256 amount) internal {
        uint64 today = _today();
        DailyUsage memory usage = _usage[token];
        uint256 spent = usage.day == today ? usage.spent : 0;
        uint256 limit = dailyLimit[token];
        uint256 remaining = limit > spent ? limit - spent : 0;
        require(amount <= remaining, DailyLimitExceeded(token, amount, remaining));
        // casting to 'uint192' is safe because spent + amount <= limit <= MAX_DAILY_LIMIT
        // < type(uint192).max
        // forge-lint: disable-next-line(unsafe-typecast)
        _usage[token] = DailyUsage({day: today, spent: uint192(spent + amount)});
    }

    /// @dev Deletes a queued increase and emits the cancellation, if one exists.
    function _dropPendingIncrease(address token) internal {
        PendingLimit memory pending = pendingLimit[token];
        if (pending.effectiveAt != 0) {
            delete pendingLimit[token];
            emit DailyLimitIncreaseCancelled(token, pending.newLimit);
        }
    }

    /// @dev Reverts unless the key can be verified with the ecrecover trick.
    function _requireValidKey(uint256 pubKeyX, uint8 pubKeyYParity) internal pure {
        require(
            SchnorrSecp256k1.isValidKeyX(pubKeyX) && pubKeyYParity <= 1,
            InvalidGroupKey(pubKeyX, pubKeyYParity)
        );
    }

    /// @dev Days since the Unix epoch (UTC).
    function _today() internal view returns (uint64) {
        // casting to 'uint64' is safe because block.timestamp / 1 days < 2^64 for any
        // realistic timestamp
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint64(block.timestamp / 1 days);
    }
}
