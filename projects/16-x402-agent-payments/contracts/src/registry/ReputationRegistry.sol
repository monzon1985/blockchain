// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ISettlementLog} from "../interfaces/ISettlementLog.sol";
import {IdentityRegistry} from "./IdentityRegistry.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

/// @title ReputationRegistry
/// @notice ERC-8004-style reputation registry in which every piece of feedback must be backed by a settled payment.
///         `giveFeedback` takes a {SettlementLog} receipt id and accepts the feedback only if the receipt shows the
///         feedback author paid this agent's `agentWallet`, as it stood when the payment settled. Each receipt backs
///         at most one feedback, and the agent's owner, its approved operators and its own wallet can never rate it.
///         {getSummary} weights every entry by the amount of its receipt, so a review counts in proportion to what
///         its author paid the agent: a dust payment buys a dust-weight review.
/// @dev Deviations from the ERC-8004 draft: feedback carries a mandatory `receiptId` (the draft's optional off-chain
///      `proofOfPayment`, made mandatory and verified on-chain), and inputs are grouped in a struct. Values live on a
///      fixed scale: normalized to 18 decimals they must lie in [-100, 100] ({MAX_NORMALIZED_VALUE}); the draft allows
///      any `int128` metric. The summary is the receipt-amount-weighted mean of the normalized values.
contract ReputationRegistry is EIP712, Nonces {
    /// @notice Feedback input.
    /// @param agentId Rated agent.
    /// @param value Signed score (e.g. 0..100 with 0 decimals).
    /// @param valueDecimals Decimals of `value` (0..18).
    /// @param tag1 Optional tag used for filtering.
    /// @param tag2 Optional tag used for filtering.
    /// @param endpoint Optional endpoint the feedback refers to.
    /// @param feedbackURI Optional off-chain feedback document.
    /// @param feedbackHash Optional hash of that document.
    /// @param receiptId Settlement receipt proving the author paid the agent.
    struct FeedbackInput {
        uint256 agentId;
        int128 value;
        uint8 valueDecimals;
        string tag1;
        string tag2;
        string endpoint;
        string feedbackURI;
        bytes32 feedbackHash;
        bytes32 receiptId;
    }

    /// @notice Stored feedback.
    /// @param value Signed score.
    /// @param valueDecimals Decimals of `value`.
    /// @param isRevoked Whether the author revoked it.
    /// @param weight Amount of the backing receipt (its weight in {getSummary}).
    /// @param receiptId Backing receipt.
    /// @param tag1 First tag.
    /// @param tag2 Second tag.
    struct FeedbackRecord {
        int128 value;
        uint8 valueDecimals;
        bool isRevoked;
        uint96 weight;
        bytes32 receiptId;
        string tag1;
        string tag2;
    }

    /// @dev Tag filter used by {getSummary}.
    struct TagFilter {
        bytes32 tag1Hash;
        bytes32 tag2Hash;
        bool useTag1;
        bool useTag2;
    }

    /// @notice EIP-712 type hash for relayed feedback.
    bytes32 public constant FEEDBACK_TYPEHASH = keccak256(
        "Feedback(uint256 agentId,int128 value,uint8 valueDecimals,string tag1,string tag2,string endpoint,string feedbackURI,bytes32 feedbackHash,bytes32 receiptId,address client,uint256 nonce,uint256 deadline)"
    );

    /// @notice Maximum `valueDecimals`.
    uint8 public constant MAX_DECIMALS = 18;

    /// @notice Largest magnitude of a value normalized to 18 decimals: scores live in [-100, 100].
    int256 public constant MAX_NORMALIZED_VALUE = 100e18;

    /// @notice Identity registry holding agent ownership and wallets.
    IdentityRegistry public immutable IDENTITY;

    /// @notice Receipt source.
    ISettlementLog public immutable SETTLEMENT_LOG;

    /// @dev Feedback lists; index `i` (1-based, as in ERC-8004) lives at position `i - 1`.
    mapping(uint256 agentId => mapping(address client => FeedbackRecord[])) private _feedback;

    /// @dev Clients that ever rated an agent, in first-feedback order.
    mapping(uint256 agentId => address[]) private _clients;

    /// @dev Membership flag for `_clients`.
    mapping(uint256 agentId => mapping(address client => bool)) private _isClient;

    /// @dev Response counters per feedback.
    mapping(uint256 agentId => mapping(address client => mapping(uint64 index => uint64 count))) private _responses;

    /// @notice Receipts already used to back feedback.
    mapping(bytes32 receiptId => bool used) public receiptUsed;

    /// @notice Emitted for new feedback.
    /// @param agentId Rated agent.
    /// @param clientAddress Author.
    /// @param feedbackIndex 1-based index for this (agent, client) pair.
    /// @param value Score.
    /// @param valueDecimals Score decimals.
    /// @param indexedTag1 Indexed copy of `tag1`.
    /// @param tag1 First tag.
    /// @param tag2 Second tag.
    /// @param endpoint Endpoint rated.
    /// @param feedbackURI Off-chain document.
    /// @param feedbackHash Document hash.
    event NewFeedback(
        uint256 indexed agentId,
        address indexed clientAddress,
        uint64 feedbackIndex,
        int128 value,
        uint8 valueDecimals,
        string indexed indexedTag1,
        string tag1,
        string tag2,
        string endpoint,
        string feedbackURI,
        bytes32 feedbackHash
    );

    /// @notice Emitted alongside {NewFeedback}: which receipt backs it.
    /// @param agentId Rated agent.
    /// @param clientAddress Author.
    /// @param feedbackIndex 1-based index.
    /// @param receiptId Backing receipt.
    event FeedbackReceipt(
        uint256 indexed agentId, address indexed clientAddress, uint64 feedbackIndex, bytes32 indexed receiptId
    );

    /// @notice Emitted when an author revokes feedback.
    /// @param agentId Rated agent.
    /// @param clientAddress Author.
    /// @param feedbackIndex 1-based index.
    event FeedbackRevoked(uint256 indexed agentId, address indexed clientAddress, uint64 indexed feedbackIndex);

    /// @notice Emitted when anyone (typically the agent) responds to feedback.
    /// @param agentId Rated agent.
    /// @param clientAddress Author of the feedback.
    /// @param feedbackIndex 1-based index.
    /// @param responder Caller.
    /// @param responseURI Response document.
    /// @param responseHash Response hash.
    event ResponseAppended(
        uint256 indexed agentId,
        address indexed clientAddress,
        uint64 feedbackIndex,
        address indexed responder,
        string responseURI,
        bytes32 responseHash
    );

    /// @notice The author is the agent's owner, an approved operator, or its own wallet.
    /// @param agentId Agent id.
    /// @param client The author.
    error SelfFeedback(uint256 agentId, address client);

    /// @notice `valueDecimals` above {MAX_DECIMALS}.
    /// @param valueDecimals The value given.
    error InvalidDecimals(uint8 valueDecimals);

    /// @notice Normalized value outside [-100, 100].
    /// @param value The value given.
    /// @param valueDecimals Its decimals.
    error ValueOutOfRange(int128 value, uint8 valueDecimals);

    /// @notice No such receipt in the settlement log.
    /// @param receiptId The id given.
    error UnknownReceipt(bytes32 receiptId);

    /// @notice The receipt's payer is not the feedback author.
    /// @param payer Receipt payer.
    /// @param client Feedback author.
    error ReceiptPayerMismatch(address payer, address client);

    /// @notice The receipt's payee was not the agent's wallet when the payment settled.
    /// @param payee Receipt payee.
    /// @param agentWallet Agent wallet at the receipt's `settledAt`.
    error ReceiptPayeeMismatch(address payee, address agentWallet);

    /// @notice The receipt already backs a feedback.
    /// @param receiptId The receipt.
    error ReceiptAlreadyUsed(bytes32 receiptId);

    /// @notice No feedback at this index.
    /// @param agentId Agent id.
    /// @param client Author.
    /// @param feedbackIndex Index.
    error FeedbackNotFound(uint256 agentId, address client, uint64 feedbackIndex);

    /// @notice Feedback already revoked.
    /// @param feedbackIndex Index.
    error AlreadyRevoked(uint64 feedbackIndex);

    /// @notice Relayed-feedback signature expired.
    /// @param deadline Signature deadline.
    error SignatureExpired(uint256 deadline);

    /// @notice Relayed-feedback signature invalid.
    /// @param client Claimed author.
    error InvalidFeedbackSignature(address client);

    /// @notice {getSummary} requires a non-empty client filter (ERC-8004 anti-sybil rule).
    error ClientFilterRequired();

    /// @param identity Identity registry.
    /// @param settlementLog Receipt source.
    constructor(IdentityRegistry identity, ISettlementLog settlementLog) EIP712("ReputationRegistry", "1") {
        IDENTITY = identity;
        SETTLEMENT_LOG = settlementLog;
    }

    /// @notice Leaves receipt-backed feedback as `msg.sender`.
    /// @param f Feedback input.
    /// @return feedbackIndex 1-based index of the new feedback.
    function giveFeedback(FeedbackInput calldata f) external returns (uint64 feedbackIndex) {
        return _giveFeedback(f, msg.sender);
    }

    /// @notice Leaves receipt-backed feedback on behalf of `client`, authorized by its EIP-712 (EOA) or ERC-1271
    ///         (smart account) signature. Lets gasless payers and agent smart accounts rate agents via a relayer.
    /// @param f Feedback input.
    /// @param client The author (must be the receipt payer).
    /// @param deadline Signature expiry (inclusive).
    /// @param signature `client`'s signature over {FEEDBACK_TYPEHASH}.
    /// @return feedbackIndex 1-based index of the new feedback.
    function giveFeedbackBySig(FeedbackInput calldata f, address client, uint256 deadline, bytes calldata signature)
        external
        returns (uint64 feedbackIndex)
    {
        require(block.timestamp <= deadline, SignatureExpired(deadline));
        bytes32 digest = _hashTypedDataV4(_feedbackStructHash(f, client, _useNonce(client), deadline));
        require(SignatureChecker.isValidSignatureNow(client, digest, signature), InvalidFeedbackSignature(client));
        return _giveFeedback(f, client);
    }

    /// @notice Revokes one's own feedback. The backing receipt stays consumed.
    /// @param agentId Agent id.
    /// @param feedbackIndex 1-based index.
    function revokeFeedback(uint256 agentId, uint64 feedbackIndex) external {
        FeedbackRecord storage record = _record(agentId, msg.sender, feedbackIndex);
        require(!record.isRevoked, AlreadyRevoked(feedbackIndex));
        record.isRevoked = true;
        emit FeedbackRevoked(agentId, msg.sender, feedbackIndex);
    }

    /// @notice Appends a response (e.g. the agent's rebuttal or a refund proof) to existing feedback.
    /// @param agentId Agent id.
    /// @param clientAddress Feedback author.
    /// @param feedbackIndex 1-based index.
    /// @param responseURI Response document.
    /// @param responseHash Response hash.
    function appendResponse(
        uint256 agentId,
        address clientAddress,
        uint64 feedbackIndex,
        string calldata responseURI,
        bytes32 responseHash
    ) external {
        _record(agentId, clientAddress, feedbackIndex);
        unchecked {
            // A uint64 counter incremented by one per transaction cannot overflow in practice.
            ++_responses[agentId][clientAddress][feedbackIndex];
        }
        emit ResponseAppended(agentId, clientAddress, feedbackIndex, msg.sender, responseURI, responseHash);
    }

    /// @notice Receipt-amount-weighted average of the non-revoked feedback of the given clients, normalized to 18
    ///         decimals: `sum(value_i * amount_i) / sum(amount_i)`.
    /// @param agentId Agent id.
    /// @param clientAddresses Clients to include (must be non-empty; ERC-8004 anti-sybil rule).
    /// @param tag1 Filter on `tag1` (empty = any).
    /// @param tag2 Filter on `tag2` (empty = any).
    /// @return count Number of feedback entries included.
    /// @return summaryValue Weighted average with 18 decimals (0 when `count == 0`).
    /// @return summaryValueDecimals Always 18 (0 when `count == 0`).
    function getSummary(uint256 agentId, address[] calldata clientAddresses, string calldata tag1, string calldata tag2)
        external
        view
        returns (uint64 count, int128 summaryValue, uint8 summaryValueDecimals)
    {
        require(clientAddresses.length != 0, ClientFilterRequired());
        int256 weightedSum;
        uint256 totalWeight;
        (count, weightedSum, totalWeight) = _summarize(agentId, clientAddresses, _tagFilter(tag1, tag2));
        if (count == 0) return (0, 0, 0);
        // Every weight is a receipt amount (>= 1), so `totalWeight > 0`; it is a sum of uint96 values over at most a
        // few million entries (gas-bounded), far below 2^255. A weighted mean of values in [-100e18, 100e18] stays in
        // that range, which fits in int128.
        // forge-lint: disable-next-item(unsafe-typecast)
        summaryValue = int128(weightedSum / int256(totalWeight));
        summaryValueDecimals = MAX_DECIMALS;
    }

    /// @notice Reads one feedback entry.
    /// @param agentId Agent id.
    /// @param clientAddress Author.
    /// @param feedbackIndex 1-based index.
    /// @return value Score.
    /// @return valueDecimals Score decimals.
    /// @return tag1 First tag.
    /// @return tag2 Second tag.
    /// @return isRevoked Revocation flag.
    function readFeedback(uint256 agentId, address clientAddress, uint64 feedbackIndex)
        external
        view
        returns (int128 value, uint8 valueDecimals, string memory tag1, string memory tag2, bool isRevoked)
    {
        FeedbackRecord storage r = _record(agentId, clientAddress, feedbackIndex);
        return (r.value, r.valueDecimals, r.tag1, r.tag2, r.isRevoked);
    }

    /// @notice Receipt backing one feedback entry.
    /// @param agentId Agent id.
    /// @param clientAddress Author.
    /// @param feedbackIndex 1-based index.
    /// @return The receipt id.
    function feedbackReceipt(uint256 agentId, address clientAddress, uint64 feedbackIndex)
        external
        view
        returns (bytes32)
    {
        return _record(agentId, clientAddress, feedbackIndex).receiptId;
    }

    /// @notice Weight of one feedback entry in {getSummary}: the amount of its backing receipt.
    /// @param agentId Agent id.
    /// @param clientAddress Author.
    /// @param feedbackIndex 1-based index.
    /// @return The weight, in settlement-asset base units.
    function feedbackWeight(uint256 agentId, address clientAddress, uint64 feedbackIndex)
        external
        view
        returns (uint96)
    {
        return _record(agentId, clientAddress, feedbackIndex).weight;
    }

    /// @notice All clients that ever rated `agentId`.
    /// @param agentId Agent id.
    /// @return The client list.
    function getClients(uint256 agentId) external view returns (address[] memory) {
        return _clients[agentId];
    }

    /// @notice Last feedback index of a client for an agent (0 if none).
    /// @param agentId Agent id.
    /// @param clientAddress Author.
    /// @return The last index.
    function getLastIndex(uint256 agentId, address clientAddress) external view returns (uint64) {
        // A list grows by one entry per transaction, so its length cannot reach 2^64.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint64(_feedback[agentId][clientAddress].length);
    }

    /// @notice Number of responses appended to a feedback entry.
    /// @param agentId Agent id.
    /// @param clientAddress Author.
    /// @param feedbackIndex 1-based index.
    /// @return The response count.
    function getResponseCount(uint256 agentId, address clientAddress, uint64 feedbackIndex)
        external
        view
        returns (uint64)
    {
        return _responses[agentId][clientAddress][feedbackIndex];
    }

    /// @notice EIP-712 digest `client` signs for relayed feedback, at its current nonce.
    /// @param f Feedback input.
    /// @param client Author.
    /// @param deadline Signature expiry.
    /// @return The digest.
    function feedbackDigest(FeedbackInput calldata f, address client, uint256 deadline)
        external
        view
        returns (bytes32)
    {
        return _hashTypedDataV4(_feedbackStructHash(f, client, nonces(client), deadline));
    }

    function _giveFeedback(FeedbackInput calldata f, address client) private returns (uint64 feedbackIndex) {
        address owner = IDENTITY.ownerOf(f.agentId);
        address agentWallet = IDENTITY.getAgentWallet(f.agentId);
        require(
            client != owner && client != agentWallet && !IDENTITY.isOwnerOrOperator(f.agentId, client),
            SelfFeedback(f.agentId, client)
        );
        require(f.valueDecimals <= MAX_DECIMALS, InvalidDecimals(f.valueDecimals));
        require(_inScale(f.value, f.valueDecimals), ValueOutOfRange(f.value, f.valueDecimals));

        ISettlementLog.Receipt memory receipt = SETTLEMENT_LOG.receiptOf(f.receiptId);
        require(receipt.payer != address(0), UnknownReceipt(f.receiptId));
        require(receipt.payer == client, ReceiptPayerMismatch(receipt.payer, client));
        // The wallet in force when the payment settled, not the current one: rotating or clearing the wallet later
        // cannot void a receipt. A wallet serves one agent at a time, so this also binds the receipt to this agent.
        if (!IDENTITY.wasAgentWalletAt(f.agentId, receipt.payee, receipt.settledAt)) {
            revert ReceiptPayeeMismatch(receipt.payee, IDENTITY.getAgentWalletAt(f.agentId, receipt.settledAt));
        }
        require(!receiptUsed[f.receiptId], ReceiptAlreadyUsed(f.receiptId));

        receiptUsed[f.receiptId] = true;
        if (!_isClient[f.agentId][client]) {
            _isClient[f.agentId][client] = true;
            _clients[f.agentId].push(client);
        }
        FeedbackRecord[] storage list = _feedback[f.agentId][client];
        list.push(
            FeedbackRecord({
                value: f.value,
                valueDecimals: f.valueDecimals,
                isRevoked: false,
                weight: receipt.amount,
                receiptId: f.receiptId,
                tag1: f.tag1,
                tag2: f.tag2
            })
        );
        // Same bound as {getLastIndex}: one entry per transaction.
        // forge-lint: disable-next-line(unsafe-typecast)
        feedbackIndex = uint64(list.length);
        _emitNewFeedback(f, client, feedbackIndex);
        emit FeedbackReceipt(f.agentId, client, feedbackIndex, f.receiptId);
    }

    /// @dev Emits the ERC-8004 `NewFeedback` event from a memory copy of the input, so the 11-field event fits the
    ///      legacy code generator's stack.
    function _emitNewFeedback(FeedbackInput memory f, address client, uint64 feedbackIndex) private {
        emit NewFeedback(
            f.agentId,
            client,
            feedbackIndex,
            f.value,
            f.valueDecimals,
            f.tag1,
            f.tag1,
            f.tag2,
            f.endpoint,
            f.feedbackURI,
            f.feedbackHash
        );
    }

    /// @dev Count, weighted sum and total weight over all listed clients.
    function _summarize(uint256 agentId, address[] calldata clientAddresses, TagFilter memory filter)
        private
        view
        returns (uint64 count, int256 weightedSum, uint256 totalWeight)
    {
        for (uint256 c = 0; c < clientAddresses.length; ++c) {
            (int256 clientSum, uint256 clientWeight, uint64 clientCount) =
                _sumClient(_feedback[agentId][clientAddresses[c]], filter);
            weightedSum += clientSum;
            totalWeight += clientWeight;
            count += clientCount;
        }
    }

    function _tagFilter(string calldata tag1, string calldata tag2) private pure returns (TagFilter memory) {
        return TagFilter({
            tag1Hash: keccak256(bytes(tag1)),
            tag2Hash: keccak256(bytes(tag2)),
            useTag1: bytes(tag1).length != 0,
            useTag2: bytes(tag2).length != 0
        });
    }

    /// @dev Weighted sum, total weight and count of the non-revoked, tag-matching entries of one client. Each term is
    ///      at most 100e18 * (2^96 - 1) < 2^163 in magnitude, so the sums cannot overflow within any gas limit.
    function _sumClient(FeedbackRecord[] storage list, TagFilter memory filter)
        private
        view
        returns (int256 weightedSum, uint256 totalWeight, uint64 count)
    {
        for (uint256 i = 0; i < list.length; ++i) {
            FeedbackRecord storage r = list[i];
            if (r.isRevoked) continue;
            if (filter.useTag1 && keccak256(bytes(r.tag1)) != filter.tag1Hash) continue;
            if (filter.useTag2 && keccak256(bytes(r.tag2)) != filter.tag2Hash) continue;
            weightedSum += _normalize(r.value, r.valueDecimals) * int256(uint256(r.weight));
            totalWeight += r.weight;
            ++count;
        }
    }

    function _record(uint256 agentId, address client, uint64 feedbackIndex)
        private
        view
        returns (FeedbackRecord storage)
    {
        FeedbackRecord[] storage list = _feedback[agentId][client];
        require(feedbackIndex != 0 && feedbackIndex <= list.length, FeedbackNotFound(agentId, client, feedbackIndex));
        return list[feedbackIndex - 1];
    }

    function _feedbackStructHash(FeedbackInput calldata f, address client, uint256 nonce, uint256 deadline)
        private
        pure
        returns (bytes32)
    {
        bytes memory head = abi.encode(
            FEEDBACK_TYPEHASH,
            f.agentId,
            f.value,
            f.valueDecimals,
            keccak256(bytes(f.tag1)),
            keccak256(bytes(f.tag2)),
            keccak256(bytes(f.endpoint)),
            keccak256(bytes(f.feedbackURI))
        );
        return keccak256(bytes.concat(head, abi.encode(f.feedbackHash, f.receiptId, client, nonce, deadline)));
    }

    /// @dev `value * 10^(18 - decimals)`, computed in int256 (cannot overflow: |value| < 2^127, factor <= 10^18).
    function _normalize(int128 value, uint8 valueDecimals) private pure returns (int256) {
        return int256(value) * int256(10 ** uint256(MAX_DECIMALS - valueDecimals));
    }

    /// @dev Whether the normalized value lies in [-{MAX_NORMALIZED_VALUE}, {MAX_NORMALIZED_VALUE}].
    function _inScale(int128 value, uint8 valueDecimals) private pure returns (bool) {
        int256 normalized = _normalize(value, valueDecimals);
        return normalized >= -MAX_NORMALIZED_VALUE && normalized <= MAX_NORMALIZED_VALUE;
    }
}
