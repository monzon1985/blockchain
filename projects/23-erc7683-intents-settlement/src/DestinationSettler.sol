// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin-contracts/utils/ReentrancyGuardTransient.sol";

import {IDestinationSettler} from "./erc7683/IERC7683.sol";
import {DutchDecay} from "./libraries/DutchDecay.sol";
import {Intent, IntentLib} from "./libraries/IntentLib.sol";

/// @title DestinationSettler
/// @notice ERC-7683 (v1) destination settler. Delivers the user's output from the filler, priced by an exclusivity
/// window and then a linear Dutch decay, and writes a write-once FillRecord that every settlement mode reads.
/// @dev Storage layout is part of the protocol: settlement mode 3 proves `_fills[orderId]` with eth_getProof.
///      `_fills` is the first and only state variable, so it lives at slot 0 (FILLS_SLOT) and the record of
///      `orderId` starts at keccak256(abi.encode(orderId, 0)):
///        slot + 0: filledAt (uint64, bits 160..223) | filler (address, bits 0..159)
///        slot + 1: fillHash
///      `ReentrancyGuardTransient` uses transient storage only. test/unit/DestinationSettler.t.sol pins this layout.
///      The contract has no owner and no privileged function.
contract DestinationSettler is IDestinationSettler, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @notice A recorded fill.
    /// @param filler Origin-chain address the filler asked to be repaid to.
    /// @param filledAt Timestamp of the fill on this chain.
    /// @param fillHash keccak256 of the filled `originData`.
    struct FillRecord {
        address filler;
        uint64 filledAt;
        bytes32 fillHash;
    }

    /// @notice Storage slot of the `_fills` mapping.
    uint256 public constant FILLS_SLOT = 0;

    /// @dev Fill records by order id. MUST remain the first state variable (see FILLS_SLOT).
    mapping(bytes32 orderId => FillRecord) internal _fills;

    /// @notice Emitted when an order is filled.
    /// @param orderId The order id.
    /// @param filler The account that paid the output (msg.sender).
    /// @param repaymentRecipient Origin-chain address recorded for repayment.
    /// @param recipient Receiver of the output.
    /// @param outputToken Output token.
    /// @param amount Output delivered.
    /// @param fillHash keccak256 of the filled `originData`.
    event OrderFilled(
        bytes32 indexed orderId,
        address indexed filler,
        address indexed repaymentRecipient,
        address recipient,
        address outputToken,
        uint256 amount,
        bytes32 fillHash
    );

    /// @notice `originData` does not hash to `orderId`.
    /// @param orderId The order id provided.
    /// @param computed The id derived from `originData`.
    error OrderIdMismatch(bytes32 orderId, bytes32 computed);
    /// @notice The order targets another destination chain.
    /// @param expected The current chain id.
    /// @param actual The chain named by the order.
    error WrongDestinationChain(uint256 expected, uint256 actual);
    /// @notice The order targets another destination settler.
    /// @param expected This contract.
    /// @param actual The settler named by the order.
    error WrongDestinationSettler(address expected, address actual);
    /// @notice The fill deadline has passed.
    /// @param fillDeadline The order's fill deadline.
    /// @param timestamp The current timestamp.
    error FillDeadlinePassed(uint32 fillDeadline, uint256 timestamp);
    /// @notice The order was already filled.
    /// @param orderId The order id.
    /// @param filler The recorded repayment address.
    error AlreadyFilled(bytes32 orderId, address filler);
    /// @notice The exclusivity window is active and the caller is not the exclusive filler.
    /// @param exclusiveFiller The exclusive filler.
    /// @param exclusivityDeadline End of the exclusivity window.
    error NotExclusiveFiller(address exclusiveFiller, uint32 exclusivityDeadline);
    /// @notice `fillerData` is neither empty nor a 32-byte ABI-encoded non-zero address.
    /// @param fillerData The data provided.
    error InvalidFillerData(bytes fillerData);

    /// @inheritdoc IDestinationSettler
    /// @dev `fillerData` is empty (repay msg.sender) or `abi.encode(address repaymentRecipient)`.
    function fill(bytes32 orderId, bytes calldata originData, bytes calldata fillerData) external nonReentrant {
        address repaymentRecipient = msg.sender;
        if (fillerData.length != 0) {
            // `if/revert` rather than `require(cond, Error(args))`: the latter evaluates (here: copies) its
            // arguments even when the condition holds.
            if (fillerData.length != 32) revert InvalidFillerData(fillerData);
            repaymentRecipient = abi.decode(fillerData, (address));
            if (repaymentRecipient == address(0)) revert InvalidFillerData(fillerData);
        }
        _fill(orderId, originData, repaymentRecipient);
    }

    /// @notice Typed variant of `fill` used by the resolver adapter, whose instruction set cannot build `fillerData`.
    /// @param orderId The order id.
    /// @param originData The order's `originData`.
    /// @param repaymentRecipient Origin-chain address to repay; must be non-zero.
    function fillWithRepayment(bytes32 orderId, bytes calldata originData, address repaymentRecipient)
        external
        nonReentrant
    {
        if (repaymentRecipient == address(0)) revert InvalidFillerData(abi.encode(repaymentRecipient));
        _fill(orderId, originData, repaymentRecipient);
    }

    /// @notice Fill record of `orderId` (all zero if unfilled).
    /// @param orderId The order id.
    /// @return The record.
    function fillRecord(bytes32 orderId) external view returns (FillRecord memory) {
        return _fills[orderId];
    }

    /// @notice Storage slot holding `filledAt | filler` for `orderId`; the one settlement mode 3 proves.
    /// @param orderId The order id.
    /// @return The slot.
    function fillRecordSlot(bytes32 orderId) external pure returns (bytes32) {
        return keccak256(abi.encode(orderId, FILLS_SLOT));
    }

    /// @notice Output owed for `originData` if filled at `timestamp` (ignores deadline and exclusivity checks).
    /// @param originData The order's `originData`.
    /// @param timestamp The fill timestamp to price.
    /// @return The output amount.
    function outputAt(bytes calldata originData, uint256 timestamp) external pure returns (uint256) {
        Intent memory intent = abi.decode(originData, (Intent));
        return _outputAt(intent, timestamp);
    }

    /// @dev Checks, records and pays a fill. Effects happen before the token transfer.
    function _fill(bytes32 orderId, bytes calldata originData, address repaymentRecipient) internal {
        bytes32 fillHash = keccak256(originData);
        Intent memory intent = abi.decode(originData, (Intent));
        bytes32 computed = IntentLib.orderId(intent.originChainId, intent.originSettler, fillHash);
        require(computed == orderId, OrderIdMismatch(orderId, computed));
        require(
            intent.data.destinationChainId == block.chainid,
            WrongDestinationChain(block.chainid, intent.data.destinationChainId)
        );
        require(
            intent.data.destinationSettler == address(this),
            WrongDestinationSettler(address(this), intent.data.destinationSettler)
        );
        require(block.timestamp <= intent.fillDeadline, FillDeadlinePassed(intent.fillDeadline, block.timestamp));
        FillRecord storage record = _fills[orderId];
        address previous = record.filler;
        require(previous == address(0), AlreadyFilled(orderId, previous));
        address exclusiveFiller = intent.data.exclusiveFiller;
        uint32 exclusivityDeadline = intent.data.exclusivityDeadline;
        require(
            exclusiveFiller == address(0) || block.timestamp > exclusivityDeadline || msg.sender == exclusiveFiller,
            NotExclusiveFiller(exclusiveFiller, exclusivityDeadline)
        );

        uint256 amount = _outputAt(intent, block.timestamp);
        record.filler = repaymentRecipient;
        // Timestamps fit 64 bits for the next ~584 billion years.
        // forge-lint: disable-next-line(unsafe-typecast)
        record.filledAt = uint64(block.timestamp);
        record.fillHash = fillHash;

        // False positive: the only external call in this function is the transfer below, after the event.
        // forge-lint: disable-start(reentrancy-events)
        emit OrderFilled(
            orderId, msg.sender, repaymentRecipient, intent.data.recipient, intent.data.outputToken, amount, fillHash
        );
        // forge-lint: disable-end(reentrancy-events)
        IERC20(intent.data.outputToken).safeTransferFrom(msg.sender, intent.data.recipient, amount);
    }

    /// @dev Exclusivity window at the start amount, then linear decay to the end amount at the fill deadline.
    function _outputAt(Intent memory intent, uint256 timestamp) internal pure returns (uint256) {
        return DutchDecay.amountAt(
            intent.data.outputStartAmount,
            intent.data.outputEndAmount,
            intent.data.exclusivityDeadline,
            intent.fillDeadline,
            timestamp
        );
    }
}
