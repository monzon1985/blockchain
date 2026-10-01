// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ISettlementLog} from "../interfaces/ISettlementLog.sol";
import {ITransferAuthorizationToken} from "../interfaces/ITransferAuthorizationToken.sol";
import {ResourceBinding} from "../settlement/ResourceBinding.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title PaymentEscrow
/// @notice Escrow for x402 calls with delayed fulfilment. The payer's EIP-3009 `ReceiveWithAuthorization` moves the
///         payment into this contract; the payee releases it by posting a delivery hash before the deadline, which
///         also records a settlement receipt. If the deadline passes without delivery, anyone can refund the payer.
/// @dev Front-running safe: `receiveWithAuthorization` can only be executed by its `to` (this contract), and the
///      nonce commits to (payee, resource, deadline), so the relayer cannot redirect the escrow or change its terms.
///      A delivery hash is a commitment by the payee, not a proof of correct work; disputes are out of scope and are
///      handled by reputation (a released escrow yields a receipt that backs feedback) and by the validation
///      registry.
contract PaymentEscrow is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @notice Lifecycle of an escrow. `Released` and `Refunded` are terminal.
    enum Status {
        None,
        Open,
        Released,
        Refunded
    }

    /// @notice Stored escrow. Packed into four slots.
    /// @param payer Account that funded the escrow.
    /// @param deadline Last timestamp at which the payee may deliver.
    /// @param status Lifecycle state.
    /// @param payee Account paid on delivery.
    /// @param amount Escrowed amount.
    /// @param resourceHash Resource the payment is bound to.
    /// @param deliveryHash Commitment to the delivered result (zero until delivery).
    struct Escrow {
        address payer;
        uint64 deadline;
        Status status;
        address payee;
        uint96 amount;
        bytes32 resourceHash;
        bytes32 deliveryHash;
    }

    /// @notice Parameters of {open}: the EIP-3009 authorization plus the committed escrow terms.
    /// @param from Payer.
    /// @param value Amount (the authorization's `to` is this contract).
    /// @param validAfter Authorization valid strictly after this timestamp.
    /// @param validBefore Authorization valid strictly before this timestamp.
    /// @param nonce Terms-bound nonce, see {ResourceBinding-escrowNonce}.
    /// @param payee Final recipient on delivery.
    /// @param resourceHash keccak256 of the canonical resource string.
    /// @param deliveryDeadline Delivery deadline (inclusive).
    /// @param salt Salt that opens the nonce commitment.
    struct OpenRequest {
        address from;
        uint256 value;
        uint256 validAfter;
        uint256 validBefore;
        bytes32 nonce;
        address payee;
        bytes32 resourceHash;
        uint64 deliveryDeadline;
        bytes32 salt;
    }

    /// @notice Longest delivery window accepted at opening.
    uint64 public constant MAX_DELIVERY_WINDOW = 30 days;

    /// @notice Settlement token.
    ITransferAuthorizationToken public immutable ASSET;

    /// @notice Receipt registry (this contract must be an allowed recorder there).
    ISettlementLog public immutable SETTLEMENT_LOG;

    /// @dev Escrows by id.
    mapping(bytes32 escrowId => Escrow) private _escrows;

    /// @notice Sum of the amounts of all `Open` escrows. Equals this contract's asset balance absent donations.
    uint256 public totalEscrowed;

    /// @notice Emitted when an escrow is funded.
    /// @param escrowId Escrow id.
    /// @param payer Payer.
    /// @param payee Payee.
    /// @param amount Amount held.
    /// @param resourceHash Resource the payment is bound to.
    /// @param deadline Delivery deadline.
    event EscrowOpened(
        bytes32 indexed escrowId,
        address indexed payer,
        address indexed payee,
        uint256 amount,
        bytes32 resourceHash,
        uint64 deadline
    );

    /// @notice Emitted when the payee delivers and is paid.
    /// @param escrowId Escrow id.
    /// @param deliveryHash Commitment to the delivered result.
    /// @param receiptId Receipt recorded in the settlement log.
    event EscrowReleased(bytes32 indexed escrowId, bytes32 deliveryHash, bytes32 indexed receiptId);

    /// @notice Emitted when the payer is refunded after the deadline.
    /// @param escrowId Escrow id.
    /// @param payer Refunded payer.
    /// @param amount Refunded amount.
    event EscrowRefunded(bytes32 indexed escrowId, address indexed payer, uint256 amount);

    /// @notice The nonce does not commit to the supplied terms.
    /// @param nonce Nonce in the authorization.
    /// @param expected Nonce derived from the terms.
    error TermsBindingMismatch(bytes32 nonce, bytes32 expected);

    /// @notice Payee is zero or equal to the payer.
    /// @param payee The payee.
    error InvalidPayee(address payee);

    /// @notice Amount is zero.
    error ZeroAmount();

    /// @notice Deadline not in `(now, now + MAX_DELIVERY_WINDOW]`.
    /// @param deadline Requested deadline.
    /// @param nowTs Current timestamp.
    error InvalidDeadline(uint64 deadline, uint256 nowTs);

    /// @notice Escrow is not in the `Open` state.
    /// @param escrowId Escrow id.
    /// @param status Current status.
    error NotOpen(bytes32 escrowId, Status status);

    /// @notice Only the payee may deliver.
    /// @param caller The caller.
    error NotPayee(address caller);

    /// @notice Delivery attempted after the deadline.
    /// @param deadline The deadline.
    /// @param nowTs Current timestamp.
    error DeliveryDeadlinePassed(uint64 deadline, uint256 nowTs);

    /// @notice Refund attempted before the deadline passed.
    /// @param deadline The deadline.
    /// @param nowTs Current timestamp.
    error RefundNotYetAvailable(uint64 deadline, uint256 nowTs);

    /// @notice Delivery hash must be non-zero.
    error EmptyDeliveryHash();

    /// @notice This contract did not receive exactly the authorized amount.
    /// @param expected Authorized amount.
    /// @param received Observed balance delta.
    error FundingMismatch(uint256 expected, uint256 received);

    /// @param settlementLog_ Receipt registry; its asset becomes the escrow asset.
    constructor(ISettlementLog settlementLog_) {
        SETTLEMENT_LOG = settlementLog_;
        ASSET = ITransferAuthorizationToken(settlementLog_.asset());
    }

    /// @notice Funds an escrow from the payer's `ReceiveWithAuthorization` signature. Callable by anyone.
    /// @param r Authorization fields and committed terms.
    /// @param signature Payer's signature over `ReceiveWithAuthorization(from, this, value, ..., nonce)`.
    /// @return escrowId The new escrow id.
    // slither-disable-start reentrancy-balance,incorrect-equality
    // Triage: same exact-delta pattern as SettlementLog.settleExact (fixed asset, nonReentrant).
    function open(OpenRequest calldata r, bytes calldata signature) external nonReentrant returns (bytes32 escrowId) {
        bytes32 expected = ResourceBinding.escrowNonce(r.payee, r.resourceHash, r.deliveryDeadline, r.salt);
        require(r.nonce == expected, TermsBindingMismatch(r.nonce, expected));
        require(r.value != 0, ZeroAmount());
        require(r.payee != address(0) && r.payee != r.from, InvalidPayee(r.payee));
        require(
            r.deliveryDeadline > block.timestamp && r.deliveryDeadline <= block.timestamp + MAX_DELIVERY_WINDOW,
            InvalidDeadline(r.deliveryDeadline, block.timestamp)
        );

        // The token consumes (from, nonce) exactly once, so the id cannot collide with an existing escrow.
        escrowId = escrowIdFor(r.from, r.nonce);
        _escrows[escrowId] = Escrow({
            payer: r.from,
            deadline: r.deliveryDeadline,
            status: Status.Open,
            payee: r.payee,
            amount: SafeCast.toUint96(r.value),
            resourceHash: r.resourceHash,
            deliveryHash: bytes32(0)
        });
        totalEscrowed += r.value;
        emit EscrowOpened(escrowId, r.from, r.payee, r.value, r.resourceHash, r.deliveryDeadline);

        uint256 balanceBefore = ASSET.balanceOf(address(this));
        ASSET.receiveWithAuthorization(r.from, address(this), r.value, r.validAfter, r.validBefore, r.nonce, signature);
        uint256 received = ASSET.balanceOf(address(this)) - balanceBefore;
        require(received == r.value, FundingMismatch(r.value, received));
    }

    // slither-disable-end reentrancy-balance,incorrect-equality

    /// @notice Payee posts the delivery commitment and is paid; records a settlement receipt.
    /// @param escrowId Escrow id.
    /// @param deliveryHash keccak256 of the delivered result bytes.
    /// @return receiptId Receipt recorded in the settlement log.
    function deliver(bytes32 escrowId, bytes32 deliveryHash) external nonReentrant returns (bytes32 receiptId) {
        Escrow storage e = _escrows[escrowId];
        require(e.status == Status.Open, NotOpen(escrowId, e.status));
        require(msg.sender == e.payee, NotPayee(msg.sender));
        require(block.timestamp <= e.deadline, DeliveryDeadlinePassed(e.deadline, block.timestamp));
        require(deliveryHash != bytes32(0), EmptyDeliveryHash());

        e.status = Status.Released;
        e.deliveryHash = deliveryHash;
        uint256 amount = e.amount;
        totalEscrowed -= amount;

        receiptId = SETTLEMENT_LOG.recordReceipt(
            ISettlementLog.Scheme.Escrow, e.payer, e.payee, amount, e.resourceHash, escrowId
        );
        emit EscrowReleased(escrowId, deliveryHash, receiptId);
        IERC20(address(ASSET)).safeTransfer(e.payee, amount);
    }

    /// @notice Returns the funds to the payer once the deadline has passed without delivery. Callable by anyone.
    /// @param escrowId Escrow id.
    function refund(bytes32 escrowId) external nonReentrant {
        Escrow storage e = _escrows[escrowId];
        require(e.status == Status.Open, NotOpen(escrowId, e.status));
        require(block.timestamp > e.deadline, RefundNotYetAvailable(e.deadline, block.timestamp));

        e.status = Status.Refunded;
        uint256 amount = e.amount;
        totalEscrowed -= amount;
        emit EscrowRefunded(escrowId, e.payer, amount);
        IERC20(address(ASSET)).safeTransfer(e.payer, amount);
    }

    /// @notice Reads an escrow.
    /// @param escrowId Escrow id.
    /// @return The stored escrow (status `None` if unknown).
    function escrowOf(bytes32 escrowId) external view returns (Escrow memory) {
        return _escrows[escrowId];
    }

    /// @notice Escrow id of the payment authorized by `payer` with `nonce`.
    /// @param payer Payer.
    /// @param nonce EIP-3009 nonce.
    /// @return The escrow id.
    function escrowIdFor(address payer, bytes32 nonce) public pure returns (bytes32) {
        return keccak256(abi.encode(payer, nonce));
    }

    /// @notice The nonce a payer must sign to open an escrow with these terms.
    /// @param payee Final recipient.
    /// @param resourceHash keccak256 of the canonical resource string.
    /// @param deliveryDeadline Delivery deadline.
    /// @param salt Payer-chosen salt.
    /// @return The terms-bound nonce.
    function escrowNonce(address payee, bytes32 resourceHash, uint64 deliveryDeadline, bytes32 salt)
        external
        pure
        returns (bytes32)
    {
        return ResourceBinding.escrowNonce(payee, resourceHash, deliveryDeadline, salt);
    }
}
