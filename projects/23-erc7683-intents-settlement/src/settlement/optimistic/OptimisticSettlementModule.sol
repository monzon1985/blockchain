// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin-contracts/utils/ReentrancyGuardTransient.sol";

import {Escrow, IEscrowSettler, OrderStatus} from "../../interfaces/IEscrowSettler.sol";
import {ISettlementModule} from "../../interfaces/ISettlementModule.sol";
import {FillProofLib} from "../../libraries/FillProofLib.sol";
import {IntentLib} from "../../libraries/IntentLib.sol";
import {DestinationRegistry} from "../proof/DestinationRegistry.sol";
import {HeaderStore} from "../proof/HeaderStore.sol";

/// @title OptimisticSettlementModule
/// @notice Settlement mode 2. Anyone may assert "order X was filled by F at time T" by posting a bond. The assertion
/// pays F after a challenge window unless someone proves it false first, in which case the challenger takes the bond.
/// @dev A challenge is a fraud proof against a relayed destination header: at any destination block with a
///      timestamp after the claimed fill time, the order's FillRecord slot must hold exactly (F, T). Fill records
///      are write-once and fills stop at the fill deadline, so a mismatch there is conclusive, whether the slot is
///      empty (not filled: exclusion proof), the settler account does not exist yet (a header from before its
///      deployment: account exclusion proof), or the slot holds another filler or time (inclusion proof).
///
///      Claims are keyed by (orderId, filler, filledAt), not by order: any number of different assertions about the
///      same order can be pending at once. A false claim therefore cannot occupy the slot of the true one, so a user
///      who keeps posting false claims about its own order cannot stop the real filler's claim from landing and
///      finalizing before a refund. Two claims with the same key assert the same thing and would pay the same
///      filler, so only one of them may be pending. While any claim of an order is pending the order cannot be
///      refunded; once one claim has repaid the escrow, the others can still be challenged, and a surviving one is
///      voided (bond returned, nothing paid).
///
///      Trust model: the header relayer, plus at least one honest, live watcher per challenge window. The happy path
///      costs one bonded transaction and no proof.
contract OptimisticSettlementModule is DestinationRegistry, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @notice An unresolved repayment claim (two slots). Its filler and fill time are part of its key.
    /// @param claimant Poster of the bond; gets it back on finalization.
    /// @param challengeDeadline Last timestamp at which the claim can be challenged.
    /// @param fillHash Claimed fill hash; hashes to the order id.
    struct Claim {
        address claimant;
        uint64 challengeDeadline;
        bytes32 fillHash;
    }

    /// @notice OriginSettler whose escrows this module releases.
    IEscrowSettler public immutable ORIGIN_SETTLER;

    /// @notice Source of trusted destination state roots for fraud proofs.
    HeaderStore public immutable HEADERS;

    /// @notice Token in which bonds are posted.
    IERC20 public immutable BOND_TOKEN;

    /// @notice Bond per claim.
    uint256 public immutable BOND;

    /// @notice Seconds during which a claim can be challenged.
    uint256 public immutable CHALLENGE_WINDOW;

    /// @dev Pending claims by claim id (see `claimIdOf`).
    mapping(bytes32 claimId => Claim) internal _claims;

    /// @notice Number of pending claims per order; the order cannot be refunded while it is not zero.
    mapping(bytes32 orderId => uint256 count) public pendingClaims;

    /// @notice Emitted when a claim is posted.
    /// @param orderId The order id.
    /// @param claimant Poster of the bond.
    /// @param filler Claimed repayment address.
    /// @param filledAt Claimed fill timestamp.
    /// @param challengeDeadline End of the challenge window.
    event Claimed(
        bytes32 indexed orderId,
        address indexed claimant,
        address indexed filler,
        uint64 filledAt,
        uint64 challengeDeadline
    );

    /// @notice Emitted when a claim is disproven.
    /// @param orderId The order id.
    /// @param challenger Receiver of the bond.
    /// @param claimant Loser of the bond.
    /// @param claimedFiller Repayment address the claim asserted.
    /// @param claimedFilledAt Fill timestamp the claim asserted.
    /// @param provenFiller Repayment address actually recorded (0 if unfilled).
    /// @param provenFilledAt Fill timestamp actually recorded (0 if unfilled).
    event ClaimChallenged(
        bytes32 indexed orderId,
        address indexed challenger,
        address indexed claimant,
        address claimedFiller,
        uint64 claimedFilledAt,
        address provenFiller,
        uint64 provenFilledAt
    );

    /// @notice Emitted when a claim survives its window and the escrow is released.
    /// @param orderId The order id.
    /// @param filler Receiver of the escrow.
    /// @param claimant Receiver of the returned bond.
    /// @param filledAt Fill timestamp the claim asserted.
    event ClaimFinalized(bytes32 indexed orderId, address indexed filler, address indexed claimant, uint64 filledAt);

    /// @notice Emitted when a claim survives its window after another claim already repaid the escrow: the bond is
    /// returned and nothing is paid.
    /// @param orderId The order id.
    /// @param filler Repayment address the claim asserted.
    /// @param claimant Receiver of the returned bond.
    /// @param filledAt Fill timestamp the claim asserted.
    event ClaimVoided(bytes32 indexed orderId, address indexed filler, address indexed claimant, uint64 filledAt);

    /// @notice Constructor arguments are inconsistent.
    error InvalidConfiguration();
    /// @notice The same assertion (order, filler, fill time) is already pending.
    /// @param orderId The order id.
    /// @param filler The claimed filler.
    /// @param filledAt The claimed fill time.
    error ClaimAlreadyPending(bytes32 orderId, address filler, uint64 filledAt);
    /// @notice The order is not open or does not use this module.
    /// @param orderId The order id.
    error OrderNotClaimable(bytes32 orderId);
    /// @notice `fillHash` does not hash to the order id.
    /// @param orderId The order id.
    /// @param fillHash The claimed fill hash.
    error FillHashMismatch(bytes32 orderId, bytes32 fillHash);
    /// @notice The claimed filler is zero.
    error ZeroFiller();
    /// @notice The claimed fill time is in the future or after the fill deadline.
    /// @param filledAt The claimed fill time.
    /// @param latest The latest acceptable fill time.
    error InvalidFillTime(uint64 filledAt, uint256 latest);
    /// @notice No such claim is pending.
    /// @param orderId The order id.
    /// @param filler The claimed filler.
    /// @param filledAt The claimed fill time.
    error NoPendingClaim(bytes32 orderId, address filler, uint64 filledAt);
    /// @notice The challenge window has closed.
    /// @param challengeDeadline End of the window.
    error ChallengeWindowClosed(uint64 challengeDeadline);
    /// @notice The challenge window is still open.
    /// @param challengeDeadline End of the window.
    error ChallengeWindowOpen(uint64 challengeDeadline);
    /// @notice The header used for the fraud proof is not after the claimed fill time.
    /// @param headerTimestamp Timestamp of the header.
    /// @param filledAt Claimed fill time.
    error HeaderNotAfterFill(uint64 headerTimestamp, uint64 filledAt);
    /// @notice The proof shows exactly the claimed record: the claim is honest.
    /// @param orderId The order id.
    error ClaimNotFraudulent(bytes32 orderId);

    /// @param originSettler OriginSettler whose escrows this module releases.
    /// @param headers HeaderStore of destination headers.
    /// @param bondToken Token in which bonds are posted.
    /// @param bond Bond per claim (non-zero).
    /// @param challengeWindow Seconds during which a claim can be challenged (non-zero).
    /// @param authority AccessManager governing `setDestinationSettler`.
    constructor(
        IEscrowSettler originSettler,
        HeaderStore headers,
        IERC20 bondToken,
        uint256 bond,
        uint256 challengeWindow,
        address authority
    ) DestinationRegistry(authority) {
        require(
            address(originSettler) != address(0) && address(headers) != address(0) && address(bondToken) != address(0)
                && bond != 0 && challengeWindow != 0 && challengeWindow <= type(uint32).max,
            InvalidConfiguration()
        );
        ORIGIN_SETTLER = originSettler;
        HEADERS = headers;
        BOND_TOKEN = bondToken;
        BOND = bond;
        CHALLENGE_WINDOW = challengeWindow;
    }

    /// @notice Asserts that `orderId` was filled by `filler` at `filledAt`, posting `BOND` of `BOND_TOKEN` (approve
    /// this module first). Other assertions about the same order may be pending at the same time.
    /// @param orderId The order id.
    /// @param filler Repayment address recorded by the fill.
    /// @param filledAt Fill timestamp on the destination chain.
    /// @param fillHash keccak256 of the filled originData.
    /// @return claimId Key of the new claim, `claimIdOf(orderId, filler, filledAt)`.
    function claim(bytes32 orderId, address filler, uint64 filledAt, bytes32 fillHash)
        external
        nonReentrant
        returns (bytes32 claimId)
    {
        claimId = claimIdOf(orderId, filler, filledAt);
        require(_claims[claimId].claimant == address(0), ClaimAlreadyPending(orderId, filler, filledAt));
        Escrow memory escrow = ORIGIN_SETTLER.escrowOf(orderId);
        require(
            escrow.status == OrderStatus.Open && escrow.settlementModule == address(this), OrderNotClaimable(orderId)
        );
        require(
            IntentLib.orderId(block.chainid, address(ORIGIN_SETTLER), fillHash) == orderId,
            FillHashMismatch(orderId, fillHash)
        );
        require(filler != address(0), ZeroFiller());
        uint256 latest = block.timestamp < escrow.fillDeadline ? block.timestamp : escrow.fillDeadline;
        require(filledAt <= latest, InvalidFillTime(filledAt, latest));

        // block.timestamp + a window below 2^32 fits 64 bits for the next ~584 billion years.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 challengeDeadline = uint64(block.timestamp + CHALLENGE_WINDOW);
        _claims[claimId] = Claim({claimant: msg.sender, challengeDeadline: challengeDeadline, fillHash: fillHash});
        unchecked {
            // Every pending claim holds a bond, so the count is bounded by BOND_TOKEN's supply divided by BOND.
            ++pendingClaims[orderId];
        }
        emit Claimed(orderId, msg.sender, filler, filledAt, challengeDeadline);
        BOND_TOKEN.safeTransferFrom(msg.sender, address(this), BOND);
    }

    /// @notice Disproves the pending claim (`orderId`, `filler`, `filledAt`) and takes its bond.
    /// @param orderId The order id.
    /// @param filler The claimed filler.
    /// @param filledAt The claimed fill time.
    /// @param blockNumber A stored destination header whose timestamp is after the claimed fill time.
    /// @param accountProof eth_getProof(destinationSettler, [slot], blockNumber).accountProof: inclusion of the
    ///        settler, or its exclusion (a block before the settler was deployed, where nothing can be filled).
    /// @param slotProof eth_getProof(...).storageProof[0].proof for `FillProofLib.fillerSlot(orderId)`, proving
    ///        absence or a different value; for a settler not deployed yet, the empty-trie proof eth_getProof returns.
    function challenge(
        bytes32 orderId,
        address filler,
        uint64 filledAt,
        uint256 blockNumber,
        bytes[] calldata accountProof,
        bytes[] calldata slotProof
    ) external nonReentrant {
        bytes32 claimId = claimIdOf(orderId, filler, filledAt);
        Claim memory pending = _claims[claimId];
        require(pending.claimant != address(0), NoPendingClaim(orderId, filler, filledAt));
        require(block.timestamp <= pending.challengeDeadline, ChallengeWindowClosed(pending.challengeDeadline));
        uint256 recorded = _recordAfter(orderId, filledAt, blockNumber, accountProof, slotProof);
        require(recorded != FillProofLib.pack(filler, filledAt), ClaimNotFraudulent(orderId));

        delete _claims[claimId];
        unchecked {
            // The claim was pending, so the count is at least one.
            --pendingClaims[orderId];
        }
        (address provenFiller, uint64 provenFilledAt) = FillProofLib.unpack(recorded);
        // Prior external calls are view calls to immutable protocol contracts; the function is nonReentrant.
        // forge-lint: disable-next-line(reentrancy-events)
        emit ClaimChallenged(orderId, msg.sender, pending.claimant, filler, filledAt, provenFiller, provenFilledAt);
        BOND_TOKEN.safeTransfer(msg.sender, BOND);
    }

    /// @notice Resolves the claim (`orderId`, `filler`, `filledAt`) once its challenge window has passed: releases
    /// the escrow to `filler` if the order is still open, or voids the claim if another claim already repaid it.
    /// Either way the bond goes back to the claimant. Callable by anyone.
    /// @param orderId The order id.
    /// @param filler The claimed filler.
    /// @param filledAt The claimed fill time.
    function finalize(bytes32 orderId, address filler, uint64 filledAt) external nonReentrant {
        bytes32 claimId = claimIdOf(orderId, filler, filledAt);
        Claim memory pending = _claims[claimId];
        require(pending.claimant != address(0), NoPendingClaim(orderId, filler, filledAt));
        require(block.timestamp > pending.challengeDeadline, ChallengeWindowOpen(pending.challengeDeadline));
        Escrow memory escrow = ORIGIN_SETTLER.escrowOf(orderId);

        delete _claims[claimId];
        unchecked {
            // The claim was pending, so the count is at least one.
            --pendingClaims[orderId];
        }
        // A pending claim blocks refunds, so an order that is no longer open was repaid through another claim.
        if (escrow.status == OrderStatus.Open) {
            emit ClaimFinalized(orderId, filler, pending.claimant, filledAt);
            ORIGIN_SETTLER.settle(orderId, escrow.destinationChainId, filler, pending.fillHash);
        } else {
            emit ClaimVoided(orderId, filler, pending.claimant, filledAt);
        }
        BOND_TOKEN.safeTransfer(pending.claimant, BOND);
    }

    /// @dev Proven value of `orderId`'s FillRecord slot (0 if absent) at the stored header `blockNumber`, which must
    ///      be later than `filledAt`. An account exclusion proof of the settler counts as an empty slot. For an account
    ///      that does not exist, eth_getProof returns the storage proof of an empty trie (no node, or the single empty
    ///      node 0x80, depending on the client), so the account proof is only tried as an exclusion proof then; a
    ///      forged "exclusion" still has to hash-link to the header's state root, and otherwise the inclusion path runs
    ///      and the empty-trie slot proof must be backed by an empty storage root.
    function _recordAfter(
        bytes32 orderId,
        uint64 filledAt,
        uint256 blockNumber,
        bytes[] calldata accountProof,
        bytes[] calldata slotProof
    ) internal view returns (uint256) {
        uint256 chainId = ORIGIN_SETTLER.escrowOf(orderId).destinationChainId;
        (bytes32 stateRoot, uint64 headerTimestamp) = HEADERS.stateRootAt(chainId, blockNumber);
        require(headerTimestamp > filledAt, HeaderNotAfterFill(headerTimestamp, filledAt));
        address settler = _settlerOf(chainId);
        bytes32 storageRoot = FillProofLib.isEmptyTrieProof(slotProof)
            ? FillProofLib.storageRootOrEmpty(stateRoot, settler, accountProof)
            : FillProofLib.storageRoot(stateRoot, settler, accountProof);
        return FillProofLib.slotValue(storageRoot, FillProofLib.fillerSlot(orderId), slotProof);
    }

    /// @notice Key of the claim asserting that `orderId` was filled by `filler` at `filledAt`.
    /// @param orderId The order id.
    /// @param filler The claimed filler.
    /// @param filledAt The claimed fill time.
    /// @return The claim id.
    function claimIdOf(bytes32 orderId, address filler, uint64 filledAt) public pure returns (bytes32) {
        return keccak256(abi.encode(orderId, filler, filledAt));
    }

    /// @notice Pending claim (`orderId`, `filler`, `filledAt`), all zero if none.
    /// @param orderId The order id.
    /// @param filler The claimed filler.
    /// @param filledAt The claimed fill time.
    /// @return The claim.
    function claimOf(bytes32 orderId, address filler, uint64 filledAt) external view returns (Claim memory) {
        return _claims[claimIdOf(orderId, filler, filledAt)];
    }

    /// @inheritdoc ISettlementModule
    function hasPendingClaim(bytes32 orderId) external view returns (bool) {
        return pendingClaims[orderId] != 0;
    }
}
