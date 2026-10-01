// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ISettlementLog} from "../interfaces/ISettlementLog.sol";
import {ITransferAuthorizationToken} from "../interfaces/ITransferAuthorizationToken.sol";
import {ResourceBinding} from "./ResourceBinding.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title SettlementLog
/// @notice Settlement router and receipt registry for x402 payments in one asset.
///         - `exact` payments are settled here: the log submits the payer's EIP-3009 authorization and records a
///           receipt whose resource is proven by the nonce commitment (see {ResourceBinding}).
///         - `budget-exec` and escrow payments are executed by trusted recorder contracts, which report them here.
///         Receipts are the anchor for receipt-backed ERC-8004 reputation, so the set of recorders is frozen by
///         {seal}; from then on nobody (including the deployer) can add a receipt source.
/// @dev The caller of {settleExact} is untrusted (it is the facilitator). Every field of the receipt comes from the
///      payer's signature or its preimage, never from the caller.
contract SettlementLog is ISettlementLog, Ownable2Step, ReentrancyGuardTransient {
    /// @notice EIP-3009 authorization fields, as signed by the payer.
    /// @param from Payer.
    /// @param to Payee (x402 `payTo`).
    /// @param value Amount in base units.
    /// @param validAfter Valid strictly after this timestamp.
    /// @param validBefore Valid strictly before this timestamp.
    /// @param nonce Resource-bound nonce, see {ResourceBinding-exactNonce}.
    struct ExactAuthorization {
        address from;
        address to;
        uint256 value;
        uint256 validAfter;
        uint256 validBefore;
        bytes32 nonce;
    }

    /// @notice The EIP-3009 token every receipt is denominated in.
    ITransferAuthorizationToken private immutable _ASSET;

    /// @notice Receipts by id.
    mapping(bytes32 receiptId => Receipt) private _receipts;

    /// @notice Contracts allowed to call {recordReceipt}.
    mapping(address recorder => bool allowed) public isRecorder;

    /// @notice True once the recorder set is frozen (and ownership renounced).
    bool public isSealed;

    /// @notice Number of receipts ever recorded.
    uint256 public receiptCount;

    /// @notice Emitted for every new receipt.
    /// @param receiptId Deterministic id, see {receiptIdFor}.
    /// @param scheme Settlement path.
    /// @param payer Debited account.
    /// @param payee Credited account.
    /// @param amount Amount transferred.
    /// @param resourceHash Resource the payment was bound to.
    event ReceiptRecorded(
        bytes32 indexed receiptId,
        Scheme scheme,
        address indexed payer,
        address indexed payee,
        uint256 amount,
        bytes32 resourceHash
    );

    /// @notice Emitted when the owner adds or removes a recorder before sealing.
    /// @param recorder The recorder contract.
    /// @param allowed Whether it may record receipts.
    event RecorderSet(address indexed recorder, bool allowed);

    /// @notice Emitted once, when the recorder set is frozen and ownership is renounced.
    /// @param sealedBy The owner that sealed the log.
    event Sealed(address indexed sealedBy);

    /// @notice The nonce does not commit to the claimed resource.
    /// @param nonce Nonce in the authorization.
    /// @param expected Nonce derived from `resourceHash` and `resourceSalt`.
    error ResourceBindingMismatch(bytes32 nonce, bytes32 expected);

    /// @notice The payee's balance did not grow by exactly the authorized amount.
    /// @param expected Authorized amount.
    /// @param received Observed balance delta.
    error TransferAmountMismatch(uint256 expected, uint256 received);

    /// @notice Self-payments carry no economic signal and are refused.
    /// @param account The payer and payee.
    error SelfPayment(address account);

    /// @notice Zero-value payments are refused.
    error ZeroAmount();

    /// @notice Caller is not an allowed recorder.
    /// @param caller The caller.
    error NotRecorder(address caller);

    /// @notice A receipt with this id already exists.
    /// @param receiptId The duplicate id.
    error ReceiptAlreadyRecorded(bytes32 receiptId);

    /// @notice The recorder set is already sealed.
    error AlreadySealed();

    /// @notice Ownership can only be given up through {seal}.
    error RenounceDisabled();

    /// @notice Zero address supplied where a contract is required.
    error ZeroAddress();

    /// @param asset_ The EIP-3009 settlement token.
    /// @param initialOwner Deployer that wires recorders and then calls {seal}.
    constructor(address asset_, address initialOwner) Ownable(initialOwner) {
        require(asset_ != address(0), ZeroAddress());
        _ASSET = ITransferAuthorizationToken(asset_);
    }

    /// @notice Settles an x402 `exact` payment and records its receipt. Callable by anyone (the facilitator).
    /// @dev The token verifies the signature over (from, to, value, window, nonce); this function verifies that
    ///      the nonce commits to `resourceHash`. Together they bind amount, payee and resource to the payer.
    /// @param auth The EIP-3009 authorization fields.
    /// @param resourceHash keccak256 of the canonical resource string.
    /// @param resourceSalt Salt revealed by the payer to open the nonce commitment.
    /// @param signature The payer's signature (65-byte ECDSA or ERC-1271 payload).
    /// @return receiptId The id of the new receipt.
    // slither-disable-start reentrancy-balance,incorrect-equality
    // Triage: the balance is read before and after the call on purpose (exact-delta check against a fixed asset,
    // under nonReentrant); strict equality is the intended property, not a dangerous comparison.
    function settleExact(
        ExactAuthorization calldata auth,
        bytes32 resourceHash,
        bytes32 resourceSalt,
        bytes calldata signature
    ) external nonReentrant returns (bytes32 receiptId) {
        bytes32 expected = ResourceBinding.exactNonce(resourceHash, resourceSalt);
        require(auth.nonce == expected, ResourceBindingMismatch(auth.nonce, expected));
        require(auth.value != 0, ZeroAmount());
        require(auth.from != auth.to, SelfPayment(auth.from));

        // Effects first: the receipt id is derived from signed data only, so it can be written before the call.
        // If the transfer below reverts, the whole transaction (including this write) reverts with it.
        receiptId = _record(address(this), Scheme.Exact, auth.from, auth.to, auth.value, resourceHash, auth.nonce);

        uint256 balanceBefore = _ASSET.balanceOf(auth.to);
        _ASSET.transferWithAuthorization(
            auth.from, auth.to, auth.value, auth.validAfter, auth.validBefore, auth.nonce, signature
        );
        uint256 received = _ASSET.balanceOf(auth.to) - balanceBefore;
        require(received == auth.value, TransferAmountMismatch(auth.value, received));
    }

    // slither-disable-end reentrancy-balance,incorrect-equality

    /// @inheritdoc ISettlementLog
    function recordReceipt(
        Scheme scheme,
        address payer,
        address payee,
        uint256 amount,
        bytes32 resourceHash,
        bytes32 paymentKey
    ) external returns (bytes32 receiptId) {
        require(isRecorder[msg.sender], NotRecorder(msg.sender));
        require(amount != 0, ZeroAmount());
        require(payer != payee, SelfPayment(payer));
        return _record(msg.sender, scheme, payer, payee, amount, resourceHash, paymentKey);
    }

    /// @notice Allows or disallows a recorder contract. Only before {seal}.
    /// @param recorder The recorder contract (BudgetExecutor, PaymentEscrow).
    /// @param allowed Whether it may record receipts.
    function setRecorder(address recorder, bool allowed) external onlyOwner {
        require(!isSealed, AlreadySealed());
        require(recorder != address(0), ZeroAddress());
        isRecorder[recorder] = allowed;
        emit RecorderSet(recorder, allowed);
    }

    /// @notice Freezes the recorder set forever and renounces ownership. After this call the log has no
    ///         privileged role at all.
    function seal() external onlyOwner {
        isSealed = true;
        emit Sealed(msg.sender);
        _transferOwnership(address(0));
    }

    /// @notice Disabled: ownership can only be given up through {seal}, so the log never ends up unsealed and
    ///         ownerless.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    /// @inheritdoc ISettlementLog
    function receiptOf(bytes32 receiptId) external view returns (Receipt memory) {
        return _receipts[receiptId];
    }

    /// @inheritdoc ISettlementLog
    function asset() external view returns (address) {
        return address(_ASSET);
    }

    /// @notice Computes a receipt id.
    /// @param recorder Contract that executed the payment (this log for `exact`).
    /// @param scheme Settlement path.
    /// @param payer Debited account.
    /// @param paymentKey Recorder-unique key (EIP-3009 nonce, intent nonce, escrow id).
    /// @return The receipt id.
    function receiptIdFor(address recorder, Scheme scheme, address payer, bytes32 paymentKey)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(recorder, scheme, payer, paymentKey));
    }

    /// @notice The nonce an `exact` payer must sign for `resourceHash` and `salt`.
    /// @param resourceHash keccak256 of the canonical resource string.
    /// @param salt Payer-chosen random salt.
    /// @return The resource-bound EIP-3009 nonce.
    function exactNonce(bytes32 resourceHash, bytes32 salt) external pure returns (bytes32) {
        return ResourceBinding.exactNonce(resourceHash, salt);
    }

    /// @dev Writes a receipt. Reverts on duplicates, amounts above `uint96` and timestamps above `uint64`.
    function _record(
        address recorder,
        Scheme scheme,
        address payer,
        address payee,
        uint256 amount,
        bytes32 resourceHash,
        bytes32 paymentKey
    ) private returns (bytes32 receiptId) {
        receiptId = receiptIdFor(recorder, scheme, payer, paymentKey);
        require(_receipts[receiptId].payer == address(0), ReceiptAlreadyRecorded(receiptId));
        _receipts[receiptId] = Receipt({
            payer: payer,
            settledAt: SafeCast.toUint64(block.timestamp),
            scheme: scheme,
            payee: payee,
            amount: SafeCast.toUint96(amount),
            resourceHash: resourceHash
        });
        unchecked {
            // Cannot overflow: one increment per receipt, bounded by the number of transactions ever executed.
            ++receiptCount;
        }
        emit ReceiptRecorded(receiptId, scheme, payer, payee, amount, resourceHash);
    }
}
