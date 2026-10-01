// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {AccessManaged} from "@openzeppelin-contracts/access/manager/AccessManaged.sol";
import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin-contracts/utils/ReentrancyGuardTransient.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";

import {
    FillInstruction,
    GaslessCrossChainOrder,
    IOriginSettler,
    OnchainCrossChainOrder,
    Output,
    ResolvedCrossChainOrder
} from "./erc7683/IERC7683.sol";
import {Escrow, IEscrowSettler, OrderStatus} from "./interfaces/IEscrowSettler.sol";
import {ISettlementModule} from "./interfaces/ISettlementModule.sol";
import {Intent, IntentLib, IntentOrderData} from "./libraries/IntentLib.sol";

/// @title OriginSettler
/// @notice ERC-7683 (v1) origin settler. Escrows the user's input, gaslessly through a Permit2 witness transfer or
/// directly through `open`, and releases it exactly once: to the filler when the order's settlement module attests a
/// fill, or back to the user after `fillDeadline + REFUND_GRACE`.
/// @dev Privileged surface: only `setSettlementModule` (AccessManager admin). The admin cannot touch existing escrows:
///      the module that can release an escrow is fixed when the order is opened.
contract OriginSettler is IOriginSettler, IEscrowSettler, AccessManaged, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @notice `openDeadline` reported for on-chain orders, which have no open deadline.
    uint32 public constant ONCHAIN_OPEN_DEADLINE = type(uint32).max;

    /// @notice Canonical Permit2 used for gasless opens.
    ISignatureTransfer public immutable PERMIT2;

    /// @notice Seconds after `fillDeadline` during which only settlement can close an order. Gives fillers time to
    /// relay the proof of a fill made at the deadline before the user can take a refund.
    uint256 public immutable REFUND_GRACE;

    /// @notice Escrow records by order id.
    mapping(bytes32 orderId => Escrow) internal _escrows;

    /// @notice Settlement modules that new orders may select.
    mapping(address module => bool enabled) public isSettlementModule;

    /// @notice Next nonce of each user's on-chain (`open`) orders.
    mapping(address user => uint256 nonce) public onchainNonce;

    /// @notice Emitted when a settlement module is enabled or disabled for new orders.
    /// @param module The module.
    /// @param enabled Whether new orders may select it.
    event SettlementModuleSet(address indexed module, bool enabled);

    /// @notice Emitted when an escrow is released to a filler.
    /// @param orderId The order id.
    /// @param module The settlement module that attested the fill.
    /// @param filler Receiver of the escrow.
    /// @param token Escrowed token.
    /// @param amount Escrowed amount.
    event OrderSettled(
        bytes32 indexed orderId, address indexed module, address indexed filler, address token, uint256 amount
    );

    /// @notice Emitted when an escrow is returned to the user.
    /// @param orderId The order id.
    /// @param user Receiver of the refund.
    /// @param token Escrowed token.
    /// @param amount Escrowed amount.
    event OrderRefunded(bytes32 indexed orderId, address indexed user, address token, uint256 amount);

    /// @notice The Permit2 address is zero.
    error ZeroPermit2();
    /// @notice The order names another origin settler.
    /// @param expected This contract.
    /// @param actual The settler named by the order.
    error WrongOriginSettler(address expected, address actual);
    /// @notice The order names another origin chain.
    /// @param expected The current chain id.
    /// @param actual The chain id named by the order.
    error WrongOriginChain(uint256 expected, uint256 actual);
    /// @notice The gasless order can no longer be opened.
    /// @param openDeadline The order's open deadline.
    /// @param timestamp The current timestamp.
    error OpenDeadlinePassed(uint32 openDeadline, uint256 timestamp);
    /// @notice The order's fill deadline is not in the future.
    /// @param fillDeadline The order's fill deadline.
    /// @param timestamp The current timestamp.
    error FillDeadlinePassed(uint32 fillDeadline, uint256 timestamp);
    /// @notice `orderDataType` is not the IntentOrderData typehash.
    /// @param orderDataType The type provided.
    error UnsupportedOrderDataType(bytes32 orderDataType);
    /// @notice A required address field of the order data is zero.
    /// @param field Name of the field.
    error MissingOrderAddress(string field);
    /// @notice The amounts are zero, out of range, or the output curve increases.
    /// @param inputAmount Escrowed amount.
    /// @param outputStartAmount Output at the top of the auction.
    /// @param outputEndAmount Output floor.
    error InvalidAmounts(uint256 inputAmount, uint256 outputStartAmount, uint256 outputEndAmount);
    /// @notice The destination chain is zero, this chain, or does not fit 64 bits.
    /// @param destinationChainId The chain id provided.
    error InvalidDestinationChain(uint256 destinationChainId);
    /// @notice The exclusivity window ends after the fill deadline.
    /// @param exclusivityDeadline End of the exclusivity window.
    /// @param fillDeadline Fill deadline.
    error InvalidExclusivityDeadline(uint32 exclusivityDeadline, uint32 fillDeadline);
    /// @notice The settlement module is not enabled.
    /// @param module The module provided.
    error UnknownSettlementModule(address module);
    /// @notice The module cannot attest fills of this destination settler on this chain.
    /// @param module The selected module.
    /// @param destinationChainId The destination chain.
    /// @param supportedSettler The settler the module attests on that chain (0 if none).
    /// @param requestedSettler The settler named by the order.
    error UnsupportedDestination(
        address module, uint256 destinationChainId, address supportedSettler, address requestedSettler
    );
    /// @notice An identical order already exists.
    /// @param orderId The order id.
    error OrderAlreadyExists(bytes32 orderId);
    /// @notice The escrow did not receive exactly the input amount (fee-on-transfer or rebasing token).
    /// @param expected The input amount.
    /// @param received The balance increase observed.
    error UnexpectedReceivedAmount(uint256 expected, uint256 received);
    /// @notice The order is not open.
    /// @param orderId The order id.
    /// @param status Its current status.
    error OrderNotOpen(bytes32 orderId, OrderStatus status);
    /// @notice The caller is not the order's settlement module.
    /// @param orderId The order id.
    /// @param caller The caller.
    /// @param module The order's module.
    error UnauthorizedModule(bytes32 orderId, address caller, address module);
    /// @notice The fill was observed on another chain than the order's destination.
    /// @param orderId The order id.
    /// @param expected The order's destination chain.
    /// @param actual The chain reported by the module.
    error DestinationChainMismatch(bytes32 orderId, uint256 expected, uint256 actual);
    /// @notice `fillHash` does not hash to `orderId`: the fill paid for a different payload.
    /// @param orderId The order id.
    /// @param fillHash The fill hash reported by the module.
    error FillHashMismatch(bytes32 orderId, bytes32 fillHash);
    /// @notice The repayment address is zero.
    error ZeroFiller();
    /// @notice The refund window has not opened yet.
    /// @param orderId The order id.
    /// @param availableAfter Refunds are possible strictly after this timestamp.
    error RefundNotYetAvailable(bytes32 orderId, uint256 availableAfter);
    /// @notice A repayment claim is being resolved; the refund must wait for its outcome.
    /// @param orderId The order id.
    error RepaymentClaimPending(bytes32 orderId);
    /// @notice The module address has no code.
    /// @param module The module provided.
    error ModuleNotContract(address module);

    /// @param permit2 Canonical Permit2 deployment.
    /// @param refundGrace Seconds after the fill deadline before a refund is possible.
    /// @param authority AccessManager governing `setSettlementModule`.
    constructor(ISignatureTransfer permit2, uint256 refundGrace, address authority) AccessManaged(authority) {
        require(address(permit2) != address(0), ZeroPermit2());
        PERMIT2 = permit2;
        REFUND_GRACE = refundGrace;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Administration
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Enables or disables a settlement module for new orders. Existing orders keep their module.
    /// @param module The module.
    /// @param enabled Whether new orders may select it.
    function setSettlementModule(address module, bool enabled) external restricted {
        require(!enabled || module.code.length != 0, ModuleNotContract(module));
        isSettlementModule[module] = enabled;
        // The only prior external call is AccessManager.canCall, made by the `restricted` modifier.
        // forge-lint: disable-next-line(reentrancy-events)
        emit SettlementModuleSet(module, enabled);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // ERC-7683 origin interface
    // ---------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IOriginSettler
    /// @dev `originFillerData` is unused: this protocol has no filler-specific origin parameters.
    function openFor(GaslessCrossChainOrder calldata order, bytes calldata signature, bytes calldata)
        external
        nonReentrant
    {
        (Intent memory intent, IntentOrderData memory data) = _intentFromGasless(order);
        require(block.timestamp <= order.openDeadline, OpenDeadlinePassed(order.openDeadline, block.timestamp));
        (bytes32 orderId, bytes memory originData) = _register(intent);
        emit Open(orderId, _resolved(intent, orderId, originData));
        _pullWithWitness(order, data, signature);
    }

    /// @inheritdoc IOriginSettler
    /// @dev The user must have approved this contract for `inputAmount` of `inputToken`.
    function open(OnchainCrossChainOrder calldata order) external nonReentrant {
        Intent memory intent = _intentFromOnchain(order, msg.sender);
        unchecked {
            // A per-user counter starting at 0 cannot realistically reach 2^256.
            onchainNonce[msg.sender] = intent.nonce + 1;
        }
        (bytes32 orderId, bytes memory originData) = _register(intent);
        emit Open(orderId, _resolved(intent, orderId, originData));

        IERC20 token = IERC20(intent.data.inputToken);
        uint256 balanceBefore = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), intent.data.inputAmount);
        _checkReceived(token, balanceBefore, intent.data.inputAmount);
    }

    /// @inheritdoc IOriginSettler
    function resolveFor(GaslessCrossChainOrder calldata order, bytes calldata)
        external
        view
        returns (ResolvedCrossChainOrder memory)
    {
        (Intent memory intent,) = _intentFromGasless(order);
        _validate(intent);
        bytes memory originData = IntentLib.encodeOriginData(intent);
        return _resolved(intent, IntentLib.orderId(block.chainid, address(this), keccak256(originData)), originData);
    }

    /// @inheritdoc IOriginSettler
    /// @dev Resolves for `msg.sender` as the user, with the nonce the next `open` from that account would use.
    function resolve(OnchainCrossChainOrder calldata order) external view returns (ResolvedCrossChainOrder memory) {
        Intent memory intent = _intentFromOnchain(order, msg.sender);
        _validate(intent);
        bytes memory originData = IntentLib.encodeOriginData(intent);
        return _resolved(intent, IntentLib.orderId(block.chainid, address(this), keccak256(originData)), originData);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Settlement and refunds
    // ---------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IEscrowSettler
    function settle(bytes32 orderId, uint256 destinationChainId, address filler, bytes32 fillHash)
        external
        nonReentrant
    {
        Escrow storage escrow = _escrows[orderId];
        OrderStatus status = escrow.status;
        require(status == OrderStatus.Open, OrderNotOpen(orderId, status));
        address module = escrow.settlementModule;
        require(msg.sender == module, UnauthorizedModule(orderId, msg.sender, module));
        uint256 expectedChainId = escrow.destinationChainId;
        require(
            destinationChainId == expectedChainId,
            DestinationChainMismatch(orderId, expectedChainId, destinationChainId)
        );
        require(
            IntentLib.orderId(block.chainid, address(this), fillHash) == orderId, FillHashMismatch(orderId, fillHash)
        );
        require(filler != address(0), ZeroFiller());

        escrow.status = OrderStatus.Repaid;
        address token = escrow.inputToken;
        uint256 amount = escrow.inputAmount;
        emit OrderSettled(orderId, module, filler, token, amount);
        IERC20(token).safeTransfer(filler, amount);
    }

    /// @notice Returns the escrow of an unfilled order to its user. Callable by anyone after
    /// `fillDeadline + REFUND_GRACE`, unless the order's module is resolving a repayment claim.
    /// @param orderId The order id.
    function refund(bytes32 orderId) external nonReentrant {
        Escrow storage escrow = _escrows[orderId];
        OrderStatus status = escrow.status;
        require(status == OrderStatus.Open, OrderNotOpen(orderId, status));
        uint256 availableAfter = uint256(escrow.fillDeadline) + REFUND_GRACE;
        require(block.timestamp > availableAfter, RefundNotYetAvailable(orderId, availableAfter));
        require(!ISettlementModule(escrow.settlementModule).hasPendingClaim(orderId), RepaymentClaimPending(orderId));

        escrow.status = OrderStatus.Refunded;
        address user = escrow.user;
        address token = escrow.inputToken;
        uint256 amount = escrow.inputAmount;
        emit OrderRefunded(orderId, user, token, amount);
        IERC20(token).safeTransfer(user, amount);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IEscrowSettler
    function escrowOf(bytes32 orderId) external view returns (Escrow memory) {
        return _escrows[orderId];
    }

    /// @notice Order id of `intent` if opened on this settler (no validation).
    /// @param intent The normalized order.
    /// @return The order id.
    function orderIdOf(Intent calldata intent) external view returns (bytes32) {
        return IntentLib.orderId(block.chainid, address(this), keccak256(abi.encode(intent)));
    }

    /// @notice EIP-712 witness hash a user signs (inside a Permit2 PermitWitnessTransferFrom) for `order`.
    /// @param order The gasless order; `orderData` must decode to IntentOrderData.
    /// @return The witness hash.
    function witnessHash(GaslessCrossChainOrder calldata order) external pure returns (bytes32) {
        return IntentLib.hashGaslessOrder(order, abi.decode(order.orderData, (IntentOrderData)));
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Checks the ERC-7683 envelope of a gasless order and normalizes it.
    function _intentFromGasless(GaslessCrossChainOrder calldata order)
        internal
        view
        returns (Intent memory intent, IntentOrderData memory data)
    {
        require(order.originSettler == address(this), WrongOriginSettler(address(this), order.originSettler));
        require(order.originChainId == block.chainid, WrongOriginChain(block.chainid, order.originChainId));
        require(
            order.orderDataType == IntentLib.INTENT_ORDER_DATA_TYPEHASH, UnsupportedOrderDataType(order.orderDataType)
        );
        data = abi.decode(order.orderData, (IntentOrderData));
        intent = Intent({
            originSettler: address(this),
            user: order.user,
            nonce: order.nonce,
            originChainId: block.chainid,
            openDeadline: order.openDeadline,
            fillDeadline: order.fillDeadline,
            data: data
        });
    }

    /// @dev Normalizes an on-chain order opened by `user` with that user's next on-chain nonce.
    function _intentFromOnchain(OnchainCrossChainOrder calldata order, address user)
        internal
        view
        returns (Intent memory)
    {
        require(
            order.orderDataType == IntentLib.INTENT_ORDER_DATA_TYPEHASH, UnsupportedOrderDataType(order.orderDataType)
        );
        return Intent({
            originSettler: address(this),
            user: user,
            nonce: onchainNonce[user],
            originChainId: block.chainid,
            openDeadline: ONCHAIN_OPEN_DEADLINE,
            fillDeadline: order.fillDeadline,
            data: abi.decode(order.orderData, (IntentOrderData))
        });
    }

    /// @dev Validates `intent` and records its escrow (before any token is pulled).
    function _register(Intent memory intent) internal returns (bytes32 orderId, bytes memory originData) {
        _validate(intent);
        originData = IntentLib.encodeOriginData(intent);
        orderId = IntentLib.orderId(block.chainid, address(this), keccak256(originData));
        require(_escrows[orderId].status == OrderStatus.None, OrderAlreadyExists(orderId));
        IntentOrderData memory data = intent.data;
        _escrows[orderId] = Escrow({
            user: intent.user,
            fillDeadline: intent.fillDeadline,
            status: OrderStatus.Open,
            inputToken: data.inputToken,
            // Both casts are range-checked in `_validate`.
            // forge-lint: disable-next-line(unsafe-typecast)
            inputAmount: uint96(data.inputAmount),
            settlementModule: data.settlementModule,
            // forge-lint: disable-next-line(unsafe-typecast)
            destinationChainId: uint64(data.destinationChainId)
        });
    }

    /// @dev Order-data checks shared by open, openFor, resolve and resolveFor.
    function _validate(Intent memory intent) internal view {
        IntentOrderData memory data = intent.data;
        // `if/revert` for the string-carrying errors: `require(cond, Error(args))` materializes its arguments
        // even when the condition holds.
        if (data.inputToken == address(0)) revert MissingOrderAddress("inputToken");
        if (data.outputToken == address(0)) revert MissingOrderAddress("outputToken");
        if (data.recipient == address(0)) revert MissingOrderAddress("recipient");
        if (data.destinationSettler == address(0)) revert MissingOrderAddress("destinationSettler");
        require(
            data.inputAmount != 0 && data.inputAmount <= type(uint96).max && data.outputEndAmount != 0
                && data.outputEndAmount <= data.outputStartAmount,
            InvalidAmounts(data.inputAmount, data.outputStartAmount, data.outputEndAmount)
        );
        require(
            data.destinationChainId != 0 && data.destinationChainId != block.chainid
                && data.destinationChainId <= type(uint64).max,
            InvalidDestinationChain(data.destinationChainId)
        );
        require(block.timestamp < intent.fillDeadline, FillDeadlinePassed(intent.fillDeadline, block.timestamp));
        require(
            data.exclusivityDeadline <= intent.fillDeadline,
            InvalidExclusivityDeadline(data.exclusivityDeadline, intent.fillDeadline)
        );
        require(isSettlementModule[data.settlementModule], UnknownSettlementModule(data.settlementModule));
        address supported = ISettlementModule(data.settlementModule).destinationSettler(data.destinationChainId);
        require(
            supported == data.destinationSettler,
            UnsupportedDestination(data.settlementModule, data.destinationChainId, supported, data.destinationSettler)
        );
    }

    /// @dev Pulls the input through Permit2. The user's single signature covers both the token permission and the
    ///      full order (the witness), so the input can only ever be escrowed for this exact order.
    function _pullWithWitness(
        GaslessCrossChainOrder calldata order,
        IntentOrderData memory data,
        bytes calldata signature
    ) internal {
        IERC20 token = IERC20(data.inputToken);
        uint256 balanceBefore = token.balanceOf(address(this));
        PERMIT2.permitWitnessTransferFrom(
            ISignatureTransfer.PermitTransferFrom({
                permitted: ISignatureTransfer.TokenPermissions({token: data.inputToken, amount: data.inputAmount}),
                nonce: order.nonce,
                deadline: order.openDeadline
            }),
            ISignatureTransfer.SignatureTransferDetails({to: address(this), requestedAmount: data.inputAmount}),
            order.user,
            IntentLib.hashGaslessOrder(order, data),
            IntentLib.PERMIT2_WITNESS_TYPE_STRING,
            signature
        );
        _checkReceived(token, balanceBefore, data.inputAmount);
    }

    /// @dev Reverts unless the escrow balance grew by exactly `amount`.
    function _checkReceived(IERC20 token, uint256 balanceBefore, uint256 amount) internal view {
        uint256 received = token.balanceOf(address(this)) - balanceBefore;
        // Strict on purpose: more or less than `amount` means a token whose transfers do not move exactly the
        // requested value, which would break escrow accounting.
        // slither-disable-next-line incorrect-equality
        require(received == amount, UnexpectedReceivedAmount(amount, received));
    }

    /// @dev Builds the ERC-7683 view of an order.
    function _resolved(Intent memory intent, bytes32 orderId, bytes memory originData)
        internal
        view
        returns (ResolvedCrossChainOrder memory resolved)
    {
        IntentOrderData memory data = intent.data;
        Output[] memory maxSpent = new Output[](1);
        maxSpent[0] = Output({
            token: bytes32(uint256(uint160(data.outputToken))),
            amount: data.outputStartAmount,
            recipient: bytes32(uint256(uint160(data.recipient))),
            chainId: data.destinationChainId
        });
        Output[] memory minReceived = new Output[](1);
        minReceived[0] = Output({
            token: bytes32(uint256(uint160(data.inputToken))),
            amount: data.inputAmount,
            recipient: bytes32(0), // the filler, unknown until the fill
            chainId: block.chainid
        });
        FillInstruction[] memory fillInstructions = new FillInstruction[](1);
        fillInstructions[0] = FillInstruction({
            destinationChainId: data.destinationChainId,
            destinationSettler: bytes32(uint256(uint160(data.destinationSettler))),
            originData: originData
        });
        resolved = ResolvedCrossChainOrder({
            user: intent.user,
            originChainId: intent.originChainId,
            openDeadline: intent.openDeadline,
            fillDeadline: intent.fillDeadline,
            orderId: orderId,
            maxSpent: maxSpent,
            minReceived: minReceived,
            fillInstructions: fillInstructions
        });
    }
}
