// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC5267} from "@openzeppelin/contracts/interfaces/IERC5267.sol";

/// @title ICumulativeMerkleDistributor
/// @notice Multi-token, multi-epoch rewards distributor whose Merkle leaves commit cumulative amounts.
/// @dev A leaf is `keccak256(bytes.concat(keccak256(abi.encode(account, token, cumulativeAmount))))`, the
///      `StandardMerkleTree` encoding of `["address", "address", "uint256"]`. A claim pays
///      `cumulativeAmount - claimed[account][token]`, so publishing one new root tops up every account at once and the
///      contract never needs per-epoch state.
interface ICumulativeMerkleDistributor is IERC5267 {
    // ------------------------------------------------------------------------------------------------ types

    /// @notice A root waiting out the timelock.
    /// @param root Merkle root that becomes claimable once accepted.
    /// @param metadataHash keccak256 of the off-chain manifest that describes the root (inputs, totals, epoch).
    /// @param validAt Earliest timestamp at which `acceptRoot` succeeds. Zero means "no pending root".
    struct PendingRoot {
        bytes32 root;
        bytes32 metadataHash;
        uint64 validAt;
    }

    /// @notice One leaf of the active root, as passed to `claimMany`.
    /// @param account Owner of the rewards; the tokens are always paid to this address.
    /// @param token ERC-20 being distributed.
    /// @param cumulativeAmount Total ever allocated to `account` in `token`, as committed by the active root.
    struct ClaimLeaf {
        address account;
        address token;
        uint256 cumulativeAmount;
    }

    // ------------------------------------------------------------------------------------------------ events

    /// @notice The updater proposed a root; it can be accepted by anyone from `validAt` on unless revoked first.
    /// @param root Proposed Merkle root.
    /// @param metadataHash keccak256 of the off-chain manifest describing `root`.
    /// @param validAt Timestamp from which `acceptRoot` succeeds (`block.timestamp + ROOT_TIMELOCK`).
    event RootProposed(bytes32 indexed root, bytes32 indexed metadataHash, uint256 validAt);

    /// @notice A pending root was discarded, either vetoed by the guardian or displaced by a newer proposal.
    /// @param root The discarded root.
    /// @param caller The guardian (veto) or the updater (replacement).
    event RootRevoked(bytes32 indexed root, address indexed caller);

    /// @notice A pending root became the active root after its timelock.
    /// @param root New active root.
    /// @param metadataHash Manifest hash carried over from the proposal.
    /// @param epoch Number of roots accepted so far, including this one.
    event RootAccepted(bytes32 indexed root, bytes32 indexed metadataHash, uint256 indexed epoch);

    /// @notice Rewards were paid out.
    /// @param account Owner of the rewards.
    /// @param token ERC-20 paid.
    /// @param recipient Address that received the tokens (`account` unless paid through `claimFor`).
    /// @param amount Tokens transferred by this claim (`cumulativeAmount - previously claimed`).
    /// @param cumulativeAmount New value of `claimed[account][token]`.
    event Claimed(
        address indexed account,
        address indexed token,
        address indexed recipient,
        uint256 amount,
        uint256 cumulativeAmount
    );

    /// @notice A claim-authorization nonce was consumed, by a `claimFor` or by `invalidateNonce`.
    /// @param account Account whose nonce was consumed.
    /// @param nonce The consumed nonce; the next valid one is `nonce + 1`.
    event NonceUsed(address indexed account, uint256 nonce);

    /// @notice The owner changed the address allowed to propose roots.
    /// @param previousUpdater Updater before the change.
    /// @param newUpdater Updater after the change (zero disables proposals).
    event UpdaterSet(address indexed previousUpdater, address indexed newUpdater);

    /// @notice The owner changed the address allowed to veto pending roots.
    /// @param previousGuardian Guardian before the change.
    /// @param newGuardian Guardian after the change (zero disables vetoes).
    event GuardianSet(address indexed previousGuardian, address indexed newGuardian);

    // ------------------------------------------------------------------------------------------------ errors

    /// @notice The caller is not the updater.
    /// @param caller The rejected caller.
    error NotUpdater(address caller);

    /// @notice The caller is not the guardian.
    /// @param caller The rejected caller.
    error NotGuardian(address caller);

    /// @notice A zero root was proposed; it would make every proof fail.
    error ZeroRoot();

    /// @notice `acceptRoot` or `revokePendingRoot` was called with nothing pending.
    error NoPendingRoot();

    /// @notice The pending root is still inside its veto window.
    /// @param validAt Timestamp from which the root can be accepted.
    /// @param timestamp Current block timestamp.
    error RootTimelocked(uint256 validAt, uint256 timestamp);

    /// @notice No root has been accepted yet, so nothing is claimable.
    error NoActiveRoot();

    /// @notice The proof does not connect the leaf to the active root.
    /// @param account Account of the rejected leaf.
    /// @param token Token of the rejected leaf.
    /// @param cumulativeAmount Cumulative amount of the rejected leaf.
    error InvalidProof(address account, address token, uint256 cumulativeAmount);

    /// @notice The multiproof does not connect the batch of leaves to the active root.
    /// @param leafCount Number of leaves in the rejected batch.
    error InvalidMultiProof(uint256 leafCount);

    /// @notice `claimMany` was called with no leaves.
    error EmptyClaimBatch();

    /// @notice The leaf is valid but everything it allocates has already been claimed.
    /// @param account Account of the leaf.
    /// @param token Token of the leaf.
    /// @param cumulativeAmount Cumulative amount committed by the leaf.
    /// @param alreadyClaimed `claimed[account][token]` before the call.
    error NothingToClaim(address account, address token, uint256 cumulativeAmount, uint256 alreadyClaimed);

    /// @notice The claim authorization's deadline has passed.
    /// @param deadline Deadline signed by the account.
    /// @param timestamp Current block timestamp.
    error SignatureExpired(uint256 deadline, uint256 timestamp);

    /// @notice The signature is neither an ECDSA signature by `account` nor accepted by `account`'s ERC-1271 hook.
    /// @param account Account the signature was checked against.
    /// @param digest EIP-712 digest that was checked.
    error InvalidSignature(address account, bytes32 digest);

    /// @notice `claimFor` was asked to pay the zero address or the distributor itself.
    /// @param recipient The rejected recipient.
    error InvalidRecipient(address recipient);

    // ------------------------------------------------------------------------------------------------ root lifecycle

    /// @notice Proposes `newRoot`; it becomes acceptable `ROOT_TIMELOCK` seconds from now.
    /// @dev Only the updater. A root that is already pending is displaced (and `RootRevoked` is emitted for it), which
    ///      restarts the timelock: a correction never shortens the veto window.
    /// @param newRoot Merkle root of the cumulative tree; must be non-zero.
    /// @param newMetadataHash keccak256 of the manifest that describes the tree (not interpreted on-chain).
    function proposeRoot(bytes32 newRoot, bytes32 newMetadataHash) external;

    /// @notice Vetoes the pending root.
    /// @dev Only the guardian. Allowed at any time before the root is accepted, including after `validAt`.
    function revokePendingRoot() external;

    /// @notice Activates the pending root once its timelock has elapsed. Permissionless.
    function acceptRoot() external;

    // ------------------------------------------------------------------------------------------------ claims

    /// @notice Pays `account` everything the active root allocates to it in `token` that it has not claimed yet.
    /// @dev Permissionless: anyone may trigger the payout, but the tokens always go to `account`.
    /// @param account Owner of the rewards (and recipient of the tokens).
    /// @param token ERC-20 to claim.
    /// @param cumulativeAmount Cumulative amount committed by the leaf.
    /// @param proof Merkle proof of the leaf against the active root.
    /// @return amount Tokens transferred.
    function claim(address account, address token, uint256 cumulativeAmount, bytes32[] calldata proof)
        external
        returns (uint256 amount);

    /// @notice Claims on `account`'s behalf and pays `recipient`, authorized by an EIP-712 signature of `account`.
    /// @dev The signature covers `ClaimAuthorization(account, token, cumulativeAmount, recipient, nonce, deadline)` where
    ///      `nonce` is `nonces(account)`. It is accepted if it is an ECDSA signature by `account` (EOAs, and EIP-7702
    ///      accounts whatever their delegate) or if `account` has code whose ERC-1271 hook accepts it.
    /// @param account Owner of the rewards and signer of the authorization.
    /// @param token ERC-20 to claim.
    /// @param cumulativeAmount Cumulative amount committed by the leaf (and signed).
    /// @param proof Merkle proof of the leaf against the active root.
    /// @param recipient Address that receives the tokens (signed).
    /// @param deadline Last timestamp at which the authorization is valid (signed).
    /// @param signature 65-byte ECDSA signature or an ERC-1271 signature blob.
    /// @return amount Tokens transferred.
    function claimFor(
        address account,
        address token,
        uint256 cumulativeAmount,
        bytes32[] calldata proof,
        address recipient,
        uint256 deadline,
        bytes calldata signature
    ) external returns (uint256 amount);

    /// @notice Claims a batch of leaves with one multiproof; every leaf pays its own account.
    /// @dev Leaves must be in the order the multiproof expects (the order `getMultiProof` returns). Leaves with nothing
    ///      left to claim are skipped (amount 0) rather than reverting, so a front-run claim cannot break a batch.
    /// @param claims Leaves to claim.
    /// @param proof Sibling hashes of the multiproof.
    /// @param proofFlags Multiproof flags (`true`: combine two queued hashes, `false`: consume a proof hash).
    /// @return amounts Tokens transferred for each leaf, in the same order.
    function claimMany(ClaimLeaf[] calldata claims, bytes32[] calldata proof, bool[] calldata proofFlags)
        external
        returns (uint256[] memory amounts);

    /// @notice Consumes the caller's current nonce, invalidating any outstanding claim authorization signed with it.
    function invalidateNonce() external;

    // ------------------------------------------------------------------------------------------------ admin

    /// @notice Sets the address allowed to propose roots. Only the owner.
    /// @param newUpdater New updater; zero disables proposals.
    function setUpdater(address newUpdater) external;

    /// @notice Sets the address allowed to veto pending roots. Only the owner.
    /// @param newGuardian New guardian; zero disables vetoes.
    function setGuardian(address newGuardian) external;

    // ------------------------------------------------------------------------------------------------ views

    /// @notice Minimum delay between `proposeRoot` and `acceptRoot`.
    /// @return The delay in seconds (24 hours).
    // slither-disable-next-line naming-convention
    function ROOT_TIMELOCK() external view returns (uint256);

    /// @notice EIP-712 type hash of the claim authorization signed for `claimFor`.
    /// @return keccak256 of the `ClaimAuthorization` type string.
    // slither-disable-next-line naming-convention
    function CLAIM_AUTHORIZATION_TYPEHASH() external view returns (bytes32);

    /// @notice The active Merkle root (zero until the first root is accepted).
    /// @return The active root.
    function root() external view returns (bytes32);

    /// @notice Manifest hash of the active root.
    /// @return keccak256 of the manifest describing the active root.
    function metadataHash() external view returns (bytes32);

    /// @notice Number of roots accepted so far.
    /// @return The epoch counter.
    function epoch() external view returns (uint64);

    /// @notice The root waiting out its timelock, if any.
    /// @return root_ Pending root (zero if none).
    /// @return metadataHash_ Its manifest hash.
    /// @return validAt Timestamp from which it can be accepted (zero if none).
    function pendingRoot() external view returns (bytes32 root_, bytes32 metadataHash_, uint64 validAt);

    /// @notice Address allowed to propose roots.
    /// @return The updater.
    function updater() external view returns (address);

    /// @notice Address allowed to veto pending roots.
    /// @return The guardian.
    function guardian() external view returns (address);

    /// @notice Cumulative amount of `token` already paid out for `account`.
    /// @param account Owner of the rewards.
    /// @param token ERC-20.
    /// @return The claimed cumulative amount.
    function claimed(address account, address token) external view returns (uint256);

    /// @notice Next unused claim-authorization nonce of `account`.
    /// @param account Account to query.
    /// @return The nonce the next `claimFor` signature must commit to.
    function nonces(address account) external view returns (uint256);

    /// @notice Leaf hash for a (account, token, cumulativeAmount) triple, identical to `StandardMerkleTree.leafHash`.
    /// @param account Owner of the rewards.
    /// @param token ERC-20.
    /// @param cumulativeAmount Cumulative allocation.
    /// @return The double-hashed leaf.
    function leafHash(address account, address token, uint256 cumulativeAmount) external pure returns (bytes32);

    /// @notice EIP-712 digest that `account` must sign to authorize a `claimFor`.
    /// @param account Owner of the rewards.
    /// @param token ERC-20.
    /// @param cumulativeAmount Cumulative amount of the leaf.
    /// @param recipient Address that will receive the tokens.
    /// @param nonce Nonce to sign (the current one is `nonces(account)`).
    /// @param deadline Last valid timestamp.
    /// @return The digest.
    function hashClaimAuthorization(
        address account,
        address token,
        uint256 cumulativeAmount,
        address recipient,
        uint256 nonce,
        uint256 deadline
    ) external view returns (bytes32);

    /// @notice EIP-712 domain separator for the current chain (recomputed if the chain id changed since deployment).
    /// @return The domain separator.
    // slither-disable-next-line naming-convention
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}
