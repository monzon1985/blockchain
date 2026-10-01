// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ICumulativeMerkleDistributor} from "./interfaces/ICumulativeMerkleDistributor.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

/// @title CumulativeMerkleDistributor
/// @notice Distributes any number of ERC-20 rewards across any number of epochs from a single, timelocked Merkle root
///         whose leaves commit cumulative allocations.
/// @dev Accounting: `claimed[account][token]` is the only per-user state. Each root commits, per (account, token), the
///      total ever allocated; a claim pays the difference and records the new total. A new epoch is one new root, and
///      an account that skipped ten epochs claims all of them with one proof.
///
///      Root lifecycle: updater `proposeRoot` -> 24 h veto window (guardian `revokePendingRoot`) -> anyone
///      `acceptRoot`. There is no bypass: every change to what can be claimed is public for at least 24 hours.
///
///      Tokens only leave the contract through a claim backed by a proof against the active root. There is no sweep:
///      unallocated funds are recovered by allocating them (to a treasury leaf) in a future root.
contract CumulativeMerkleDistributor is
    ICumulativeMerkleDistributor,
    Ownable2Step,
    EIP712,
    Nonces,
    ReentrancyGuardTransient
{
    using SafeERC20 for IERC20;

    /// @inheritdoc ICumulativeMerkleDistributor
    uint256 public constant ROOT_TIMELOCK = 24 hours;

    /// @inheritdoc ICumulativeMerkleDistributor
    bytes32 public constant CLAIM_AUTHORIZATION_TYPEHASH = keccak256(
        "ClaimAuthorization(address account,address token,uint256 cumulativeAmount,address recipient,uint256 nonce,uint256 deadline)"
    );

    /// @inheritdoc ICumulativeMerkleDistributor
    bytes32 public root;

    /// @inheritdoc ICumulativeMerkleDistributor
    bytes32 public metadataHash;

    /// @inheritdoc ICumulativeMerkleDistributor
    PendingRoot public pendingRoot;

    /// @inheritdoc ICumulativeMerkleDistributor
    address public updater;

    /// @inheritdoc ICumulativeMerkleDistributor
    /// @dev Packed with `updater` in one slot.
    uint64 public epoch;

    /// @inheritdoc ICumulativeMerkleDistributor
    address public guardian;

    /// @inheritdoc ICumulativeMerkleDistributor
    mapping(address account => mapping(address token => uint256 cumulativeAmount)) public claimed;

    /// @notice Restricts a function to the updater.
    modifier onlyUpdater() {
        require(msg.sender == updater, NotUpdater(msg.sender));
        _;
    }

    /// @notice Restricts a function to the guardian.
    modifier onlyGuardian() {
        require(msg.sender == guardian, NotGuardian(msg.sender));
        _;
    }

    /// @notice Deploys the distributor with no active root.
    /// @param initialOwner Owner (sets the updater and the guardian; two-step transfer).
    /// @param initialUpdater Address allowed to propose roots (zero: none until the owner sets one).
    /// @param initialGuardian Address allowed to veto pending roots (zero: no veto until the owner sets one).
    constructor(address initialOwner, address initialUpdater, address initialGuardian)
        Ownable(initialOwner)
        EIP712("CumulativeMerkleDistributor", "1")
    {
        _setUpdater(initialUpdater);
        _setGuardian(initialGuardian);
    }

    // ------------------------------------------------------------------------------------------------ root lifecycle

    /// @inheritdoc ICumulativeMerkleDistributor
    function proposeRoot(bytes32 newRoot, bytes32 newMetadataHash) external onlyUpdater {
        require(newRoot != bytes32(0), ZeroRoot());

        PendingRoot memory displaced = pendingRoot;
        if (displaced.validAt != 0) emit RootRevoked(displaced.root, msg.sender);

        // Safe cast: block timestamps fit in 64 bits for the next ~584 billion years.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 validAt = uint64(block.timestamp + ROOT_TIMELOCK);
        pendingRoot = PendingRoot({root: newRoot, metadataHash: newMetadataHash, validAt: validAt});
        emit RootProposed(newRoot, newMetadataHash, validAt);
    }

    /// @inheritdoc ICumulativeMerkleDistributor
    function revokePendingRoot() external onlyGuardian {
        PendingRoot memory pending = pendingRoot;
        require(pending.validAt != 0, NoPendingRoot());

        delete pendingRoot;
        emit RootRevoked(pending.root, msg.sender);
    }

    /// @inheritdoc ICumulativeMerkleDistributor
    function acceptRoot() external {
        PendingRoot memory pending = pendingRoot;
        require(pending.validAt != 0, NoPendingRoot());
        // A validator can skew the timestamp by seconds; the veto window is 24 hours.
        // slither-disable-start timestamp
        // forge-lint: disable-next-line(block-timestamp)
        require(block.timestamp >= pending.validAt, RootTimelocked(pending.validAt, block.timestamp));
        // slither-disable-end timestamp

        root = pending.root;
        metadataHash = pending.metadataHash;
        uint64 newEpoch = epoch + 1;
        epoch = newEpoch;
        delete pendingRoot;
        emit RootAccepted(pending.root, pending.metadataHash, newEpoch);
    }

    // ------------------------------------------------------------------------------------------------ claims

    /// @inheritdoc ICumulativeMerkleDistributor
    function claim(address account, address token, uint256 cumulativeAmount, bytes32[] calldata proof)
        external
        nonReentrant
        returns (uint256 amount)
    {
        amount = _claim(account, token, cumulativeAmount, proof, account);
    }

    /// @inheritdoc ICumulativeMerkleDistributor
    function claimFor(
        address account,
        address token,
        uint256 cumulativeAmount,
        bytes32[] calldata proof,
        address recipient,
        uint256 deadline,
        bytes calldata signature
    ) external nonReentrant returns (uint256 amount) {
        // Deadlines are signer-chosen; a few seconds of validator skew cannot meaningfully extend one.
        // slither-disable-start timestamp
        // forge-lint: disable-next-line(block-timestamp)
        require(block.timestamp <= deadline, SignatureExpired(deadline, block.timestamp));
        // slither-disable-end timestamp
        require(recipient != address(0) && recipient != address(this), InvalidRecipient(recipient));

        uint256 nonce = _useNonce(account);
        emit NonceUsed(account, nonce);
        bytes32 digest = _hashClaimAuthorization(account, token, cumulativeAmount, recipient, nonce, deadline);
        // The only external call before the claim's effects is the ERC-1271 check, a STATICCALL: it cannot write state
        // or emit events, so it cannot re-enter or reorder the `Claimed` log that follows.
        require(_isValidSignature(account, digest, signature), InvalidSignature(account, digest));

        amount = _claim(account, token, cumulativeAmount, proof, recipient);
    }

    /// @inheritdoc ICumulativeMerkleDistributor
    function claimMany(ClaimLeaf[] calldata claims, bytes32[] calldata proof, bool[] calldata proofFlags)
        external
        nonReentrant
        returns (uint256[] memory amounts)
    {
        uint256 count = claims.length;
        require(count != 0, EmptyClaimBatch());
        bytes32 activeRoot = root;
        require(activeRoot != bytes32(0), NoActiveRoot());

        bytes32[] memory leaves = new bytes32[](count);
        for (uint256 i; i < count; ++i) {
            ClaimLeaf calldata c = claims[i];
            leaves[i] = _leafHash(c.account, c.token, c.cumulativeAmount);
        }
        // A non-empty leaf set rules out MerkleProof's "empty multiproof proves proof[0]" edge case. Every leaf is
        // consumed by the reconstruction, so each claim below is individually proven.
        require(MerkleProof.multiProofVerifyCalldata(proof, proofFlags, activeRoot, leaves), InvalidMultiProof(count));

        amounts = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            ClaimLeaf calldata c = claims[i];
            uint256 alreadyClaimed = claimed[c.account][c.token];
            // Skip (instead of reverting on) leaves that were claimed in the meantime, e.g. by a front-runner.
            if (c.cumulativeAmount > alreadyClaimed) {
                amounts[i] = _pay(c.account, c.token, c.cumulativeAmount, alreadyClaimed, c.account);
            }
        }
    }

    /// @inheritdoc ICumulativeMerkleDistributor
    function invalidateNonce() external {
        emit NonceUsed(msg.sender, _useNonce(msg.sender));
    }

    // ------------------------------------------------------------------------------------------------ admin

    /// @inheritdoc ICumulativeMerkleDistributor
    function setUpdater(address newUpdater) external onlyOwner {
        _setUpdater(newUpdater);
    }

    /// @inheritdoc ICumulativeMerkleDistributor
    function setGuardian(address newGuardian) external onlyOwner {
        _setGuardian(newGuardian);
    }

    // ------------------------------------------------------------------------------------------------ views

    /// @inheritdoc ICumulativeMerkleDistributor
    function nonces(address account) public view override(ICumulativeMerkleDistributor, Nonces) returns (uint256) {
        return super.nonces(account);
    }

    /// @inheritdoc ICumulativeMerkleDistributor
    function leafHash(address account, address token, uint256 cumulativeAmount) external pure returns (bytes32) {
        return _leafHash(account, token, cumulativeAmount);
    }

    /// @inheritdoc ICumulativeMerkleDistributor
    function hashClaimAuthorization(
        address account,
        address token,
        uint256 cumulativeAmount,
        address recipient,
        uint256 nonce,
        uint256 deadline
    ) external view returns (bytes32) {
        return _hashClaimAuthorization(account, token, cumulativeAmount, recipient, nonce, deadline);
    }

    /// @inheritdoc ICumulativeMerkleDistributor
    // slither-disable-next-line naming-convention
    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    // ------------------------------------------------------------------------------------------------ internals

    /// @dev Verifies one leaf against the active root and pays the unclaimed remainder to `recipient`.
    function _claim(
        address account,
        address token,
        uint256 cumulativeAmount,
        bytes32[] calldata proof,
        address recipient
    ) private returns (uint256 amount) {
        bytes32 activeRoot = root;
        require(activeRoot != bytes32(0), NoActiveRoot());
        require(
            MerkleProof.verifyCalldata(proof, activeRoot, _leafHash(account, token, cumulativeAmount)),
            InvalidProof(account, token, cumulativeAmount)
        );

        uint256 alreadyClaimed = claimed[account][token];
        require(cumulativeAmount > alreadyClaimed, NothingToClaim(account, token, cumulativeAmount, alreadyClaimed));
        amount = _pay(account, token, cumulativeAmount, alreadyClaimed, recipient);
    }

    /// @dev Records the new cumulative total, then transfers the difference (checks-effects-interactions).
    ///      Precondition: `cumulativeAmount > alreadyClaimed`.
    function _pay(address account, address token, uint256 cumulativeAmount, uint256 alreadyClaimed, address recipient)
        private
        returns (uint256 amount)
    {
        // Cannot underflow: both callers check `cumulativeAmount > alreadyClaimed` first.
        unchecked {
            amount = cumulativeAmount - alreadyClaimed;
        }
        claimed[account][token] = cumulativeAmount;
        // Reached after an ERC-1271 STATICCALL on the `claimFor` path only; see `claimFor`.
        // forge-lint: disable-next-line(reentrancy-events)
        emit Claimed(account, token, recipient, amount, cumulativeAmount);
        IERC20(token).safeTransfer(recipient, amount);
    }

    /// @dev ECDSA first, ERC-1271 second. OpenZeppelin's `SignatureChecker.isValidSignatureNow` routes every address
    ///      with code to ERC-1271 only, which rejects plain signatures from an EIP-7702 account whose delegate does not
    ///      implement ERC-1271, even though that account's key can move its funds at will. Recovering first is sound
    ///      for every account type: an ordinary contract has no private key, so no signature can recover to it.
    function _isValidSignature(address account, bytes32 digest, bytes calldata signature) private view returns (bool) {
        // The third return value only details a malformed signature; `err` already says whether recovery failed.
        // slither-disable-next-line unused-return
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecoverCalldata(digest, signature);
        if (err == ECDSA.RecoverError.NoError && recovered == account) return true;
        return
            account.code.length != 0 && SignatureChecker.isValidERC1271SignatureNowCalldata(account, digest, signature);
    }

    /// @dev EIP-712 digest of a `ClaimAuthorization`.
    function _hashClaimAuthorization(
        address account,
        address token,
        uint256 cumulativeAmount,
        address recipient,
        uint256 nonce,
        uint256 deadline
    ) private view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(CLAIM_AUTHORIZATION_TYPEHASH, account, token, cumulativeAmount, recipient, nonce, deadline)
            )
        );
    }

    /// @dev `StandardMerkleTree` leaf: the ABI encoding is 96 bytes and is hashed twice, so no 64-byte inner node
    ///      (`keccak256(left || right)`) can ever be presented as a leaf (second-preimage protection).
    function _leafHash(address account, address token, uint256 cumulativeAmount) private pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(account, token, cumulativeAmount))));
    }

    /// @dev Stores the updater and emits `UpdaterSet`.
    function _setUpdater(address newUpdater) private {
        address previousUpdater = updater;
        updater = newUpdater;
        emit UpdaterSet(previousUpdater, newUpdater);
    }

    /// @dev Stores the guardian and emits `GuardianSet`.
    function _setGuardian(address newGuardian) private {
        address previousGuardian = guardian;
        guardian = newGuardian;
        emit GuardianSet(previousGuardian, newGuardian);
    }
}
