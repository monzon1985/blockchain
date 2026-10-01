// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {AccessManaged} from "@openzeppelin-contracts/access/manager/AccessManaged.sol";
import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {MerkleProof} from "@openzeppelin-contracts/utils/cryptography/MerkleProof.sol";
import {SafeCast} from "@openzeppelin-contracts/utils/math/SafeCast.sol";
import {ReentrancyGuardTransient} from "@openzeppelin-contracts/utils/ReentrancyGuardTransient.sol";
import {IFundShareToken} from "../interfaces/IFundShareToken.sol";

/// @title DividendDistributor
/// @notice Record-date cash distributions to share holders. The fund administrator funds a distribution and
///         posts the Merkle root of `(account, amount)` entitlements computed off-chain from balances at the
///         record date (see `scripts/build-dividend-tree.mjs`). Leaves follow OpenZeppelin's
///         `StandardMerkleTree` encoding: `keccak256(bytes.concat(keccak256(abi.encode(account, amount))))`.
/// @dev Claims are permissionless and always pay the account's current wallet (following lost-wallet
///      recoveries). A payout is compliance-gated: the payee must pass the share's `canReceive`, and if the
///      payee has any frozen shares the entitlement is escrowed instead of paid, until the freeze is lifted.
///      The root is trusted (fund administrator), but a root whose leaves sum above the funded amount can
///      never pay out more than was funded.
contract DividendDistributor is AccessManaged, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    /// @notice A funded distribution.
    /// @param merkleRoot Root of the entitlement tree.
    /// @param totalAmount Funded amount.
    /// @param claimedAmount Amount already claimed (paid or escrowed).
    /// @param recordDate Record date the entitlements were computed at.
    /// @param createdAt Creation time.
    struct Distribution {
        bytes32 merkleRoot;
        uint128 totalAmount;
        uint128 claimedAmount;
        uint64 recordDate;
        uint64 createdAt;
    }

    /// @notice Token distributions are paid in.
    IERC20 public immutable payoutToken;
    /// @notice Fund share whose holders are entitled.
    IFundShareToken public immutable shareToken;

    /// @notice Escrowed entitlements per wallet (frozen at claim time).
    mapping(address wallet => uint256 amount) public escrowed;
    /// @notice Sum of all escrowed entitlements.
    uint256 public totalEscrowed;
    /// @notice Whether `account` claimed distribution `id`.
    mapping(uint256 id => mapping(address account => bool)) public claimed;

    /// @dev All distributions, id = index.
    Distribution[] private _distributions;

    /// @notice Emitted when a distribution is funded.
    /// @param id Distribution id.
    /// @param merkleRoot Entitlement root.
    /// @param totalAmount Funded amount.
    /// @param recordDate Record date.
    event DistributionCreated(uint256 indexed id, bytes32 merkleRoot, uint256 totalAmount, uint64 recordDate);
    /// @notice Emitted when an entitlement is paid.
    /// @param id Distribution id.
    /// @param account Entitled account (leaf).
    /// @param payee Wallet paid.
    /// @param amount Amount.
    event DividendClaimed(uint256 indexed id, address indexed account, address indexed payee, uint256 amount);
    /// @notice Emitted when an entitlement is escrowed because the payee is frozen.
    /// @param id Distribution id.
    /// @param account Entitled account (leaf).
    /// @param payee Frozen wallet the escrow is attributed to.
    /// @param amount Amount.
    event DividendEscrowed(uint256 indexed id, address indexed account, address indexed payee, uint256 amount);
    /// @notice Emitted when an escrow is released.
    /// @param wallet Wallet the escrow was attributed to.
    /// @param payee Wallet paid (its current wallet).
    /// @param amount Amount.
    event EscrowReleased(address indexed wallet, address indexed payee, uint256 amount);

    /// @notice Zero root, zero amount, or record date in the future.
    error InvalidDistribution(bytes32 merkleRoot, uint256 totalAmount, uint64 recordDate);
    /// @notice Unknown distribution id.
    error UnknownDistribution(uint256 id);
    /// @notice Already claimed.
    error AlreadyClaimed(uint256 id, address account);
    /// @notice The proof does not match the root.
    error InvalidProof(uint256 id, address account, uint256 amount);
    /// @notice Claims would exceed the funded amount (inconsistent root).
    error DistributionOverclaimed(uint256 id, uint256 claimedAmount, uint256 totalAmount);
    /// @notice The payee fails the share's eligibility check.
    error PayeeNotEligible(address payee);
    /// @notice Nothing escrowed for the wallet.
    error NothingEscrowed(address wallet);
    /// @notice The payee still has frozen shares.
    error PayeeFrozen(address payee, uint256 frozen);

    /// @param initialAuthority AccessManager.
    /// @param payoutToken_ Payout token.
    /// @param shareToken_ Fund share.
    constructor(address initialAuthority, IERC20 payoutToken_, IFundShareToken shareToken_)
        AccessManaged(initialAuthority)
    {
        payoutToken = payoutToken_;
        shareToken = shareToken_;
    }

    /// @notice Funds a distribution from the caller and publishes its entitlement root.
    /// @param merkleRoot Root of `(account, amount)` leaves.
    /// @param totalAmount Amount pulled from the caller.
    /// @param recordDate Record date (not in the future).
    /// @return id Distribution id.
    function createDistribution(bytes32 merkleRoot, uint256 totalAmount, uint64 recordDate)
        external
        nonReentrant
        restricted
        returns (uint256 id)
    {
        require(
            merkleRoot != bytes32(0) && totalAmount != 0 && recordDate <= block.timestamp,
            InvalidDistribution(merkleRoot, totalAmount, recordDate)
        );
        id = _distributions.length;
        _distributions.push(
            Distribution({
                merkleRoot: merkleRoot,
                totalAmount: totalAmount.toUint128(),
                claimedAmount: 0,
                recordDate: recordDate,
                createdAt: SafeCast.toUint64(block.timestamp)
            })
        );
        payoutToken.safeTransferFrom(msg.sender, address(this), totalAmount);
        emit DistributionCreated(id, merkleRoot, totalAmount, recordDate);
    }

    /// @notice Claims `account`'s entitlement in distribution `id` (anyone may call).
    /// @param id Distribution id.
    /// @param account Entitled account (as in the leaf).
    /// @param amount Entitled amount (as in the leaf).
    /// @param proof Merkle proof.
    /// @return payee Wallet paid or credited in escrow.
    /// @return wasEscrowed True if the payee was frozen and the amount went to escrow.
    function claim(uint256 id, address account, uint256 amount, bytes32[] calldata proof)
        external
        nonReentrant
        returns (address payee, bool wasEscrowed)
    {
        require(id < _distributions.length, UnknownDistribution(id));
        require(!claimed[id][account], AlreadyClaimed(id, account));
        Distribution storage dist = _distributions[id];
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(account, amount))));
        require(MerkleProof.verifyCalldata(proof, dist.merkleRoot, leaf), InvalidProof(id, account, amount));
        uint256 newClaimed = dist.claimedAmount + amount;
        require(newClaimed <= dist.totalAmount, DistributionOverclaimed(id, newClaimed, dist.totalAmount));

        claimed[id][account] = true;
        dist.claimedAmount = newClaimed.toUint128();

        payee = shareToken.currentWalletOf(account);
        wasEscrowed = shareToken.getFrozenTokens(payee) != 0;
        if (wasEscrowed) {
            escrowed[payee] += amount;
            totalEscrowed += amount;
            emit DividendEscrowed(id, account, payee, amount);
            return (payee, wasEscrowed);
        }
        require(shareToken.canReceive(payee), PayeeNotEligible(payee));
        payoutToken.safeTransfer(payee, amount);
        emit DividendClaimed(id, account, payee, amount);
    }

    /// @notice Pays out the escrow of `wallet` to its current wallet once that wallet is unfrozen and eligible.
    /// @param wallet Wallet the escrow is attributed to.
    /// @return payee Wallet paid.
    /// @return amount Amount paid.
    function releaseEscrow(address wallet) external nonReentrant returns (address payee, uint256 amount) {
        amount = escrowed[wallet];
        require(amount != 0, NothingEscrowed(wallet));
        payee = shareToken.currentWalletOf(wallet);
        uint256 frozen = shareToken.getFrozenTokens(payee);
        require(frozen == 0, PayeeFrozen(payee, frozen));
        require(shareToken.canReceive(payee), PayeeNotEligible(payee));

        escrowed[wallet] = 0;
        totalEscrowed -= amount;
        payoutToken.safeTransfer(payee, amount);
        emit EscrowReleased(wallet, payee, amount);
    }

    /// @notice Distribution `id`.
    /// @param id Distribution id.
    /// @return The distribution.
    function getDistribution(uint256 id) external view returns (Distribution memory) {
        require(id < _distributions.length, UnknownDistribution(id));
        return _distributions[id];
    }

    /// @notice Number of distributions.
    /// @return Count.
    function distributionCount() external view returns (uint256) {
        return _distributions.length;
    }

    /// @notice Funded amount not yet claimed, summed over all distributions, plus escrow: what the
    ///         distributor must hold.
    /// @return Liability.
    function outstandingLiability() external view returns (uint256) {
        uint256 length = _distributions.length;
        uint256 liability = totalEscrowed;
        for (uint256 i; i < length; ++i) {
            Distribution storage dist = _distributions[i];
            liability += dist.totalAmount - dist.claimedAmount;
        }
        return liability;
    }
}
