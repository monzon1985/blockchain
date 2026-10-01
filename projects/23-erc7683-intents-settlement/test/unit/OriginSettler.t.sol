// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Vm} from "forge-std/Test.sol";
import {IAccessManaged} from "@openzeppelin-contracts/access/manager/IAccessManaged.sol";
import {IERC1271} from "@openzeppelin-contracts/interfaces/IERC1271.sol";
import {ECDSA} from "@openzeppelin-contracts/utils/cryptography/ECDSA.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";

import {OriginSettler} from "../../src/OriginSettler.sol";
import {
    GaslessCrossChainOrder,
    IOriginSettler,
    OnchainCrossChainOrder,
    ResolvedCrossChainOrder
} from "../../src/erc7683/IERC7683.sol";
import {Escrow, OrderStatus} from "../../src/interfaces/IEscrowSettler.sol";
import {Intent, IntentLib, IntentOrderData} from "../../src/libraries/IntentLib.sol";
import {IntentTestBase} from "../utils/IntentTestBase.sol";
import {FeeOnTransferToken} from "../utils/TestTokens.sol";

/// @notice ERC-1271 wallet that accepts signatures of its owner key.
contract SmartWallet is IERC1271 {
    address internal immutable OWNER;

    constructor(address owner_) {
        OWNER = owner_;
    }

    function approve(address token, address spender) external {
        (bool ok,) = token.call(abi.encodeWithSignature("approve(address,uint256)", spender, type(uint256).max));
        require(ok, "approve");
    }

    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        return ECDSA.recover(hash, signature) == OWNER ? IERC1271.isValidSignature.selector : bytes4(0xffffffff);
    }
}

contract OriginSettlerTest is IntentTestBase {
    bytes4 internal constant PERMIT2_INVALID_SIGNER = bytes4(keccak256("InvalidSigner()"));
    bytes4 internal constant PERMIT2_INVALID_NONCE = bytes4(keccak256("InvalidNonce()"));
    bytes4 internal constant PERMIT2_INVALID_CONTRACT_SIGNATURE = bytes4(keccak256("InvalidContractSignature()"));

    // ------------------------------------------------------------------------------------------------------------
    // open (on-chain)
    // ------------------------------------------------------------------------------------------------------------

    function test_open_escrowsInputAndRecordsOrder() public {
        OrderParams memory p = _params(address(mailboxModule));
        (bytes32 orderId,) = _openOnchain(p);

        assertEq(inputToken.balanceOf(address(origin)), p.inputAmount);
        assertEq(inputToken.balanceOf(user), 0);
        Escrow memory escrow = origin.escrowOf(orderId);
        assertEq(escrow.user, user);
        assertEq(escrow.fillDeadline, p.fillDeadline);
        assertEq(uint8(escrow.status), uint8(OrderStatus.Open));
        assertEq(escrow.inputToken, address(inputToken));
        assertEq(escrow.inputAmount, p.inputAmount);
        assertEq(escrow.settlementModule, address(mailboxModule));
        assertEq(escrow.destinationChainId, DEST);
        assertEq(origin.onchainNonce(user), 1);
    }

    function test_open_emitsOpenEqualToResolve() public {
        OrderParams memory p = _params(address(optimistic));
        OnchainCrossChainOrder memory order = _onchainOrder(p);
        vm.prank(user);
        ResolvedCrossChainOrder memory expected = origin.resolve(order);

        inputToken.mint(user, p.inputAmount);
        vm.startPrank(user);
        inputToken.approve(address(origin), p.inputAmount);
        vm.recordLogs();
        origin.open(order);
        vm.stopPrank();

        ResolvedCrossChainOrder memory emitted = _decodeOpen(vm.getRecordedLogs(), expected.orderId);
        assertEq(keccak256(abi.encode(emitted)), keccak256(abi.encode(expected)));

        (bytes32 orderId, bytes memory originData) = _ids(_onchainIntent(p, user, 0));
        assertEq(expected.orderId, orderId);
        assertEq(expected.user, user);
        assertEq(expected.originChainId, ORIGIN);
        assertEq(expected.openDeadline, type(uint32).max);
        assertEq(expected.fillDeadline, p.fillDeadline);
        assertEq(expected.maxSpent.length, 1);
        assertEq(expected.maxSpent[0].token, bytes32(uint256(uint160(address(outputToken)))));
        assertEq(expected.maxSpent[0].amount, p.outputStart);
        assertEq(expected.maxSpent[0].recipient, bytes32(uint256(uint160(recipient))));
        assertEq(expected.maxSpent[0].chainId, DEST);
        assertEq(expected.minReceived[0].token, bytes32(uint256(uint160(address(inputToken)))));
        assertEq(expected.minReceived[0].amount, p.inputAmount);
        assertEq(expected.minReceived[0].recipient, bytes32(0));
        assertEq(expected.minReceived[0].chainId, ORIGIN);
        assertEq(expected.fillInstructions[0].destinationChainId, DEST);
        assertEq(expected.fillInstructions[0].destinationSettler, bytes32(uint256(uint160(address(dest)))));
        assertEq(expected.fillInstructions[0].originData, originData);
    }

    function test_open_sameOrderTwiceGetsDistinctIds() public {
        OrderParams memory p = _params(address(mailboxModule));
        (bytes32 first,) = _openOnchain(p);
        (bytes32 second,) = _openOnchain(p);
        assertTrue(first != second);
        assertEq(origin.onchainNonce(user), 2);
    }

    function test_orderIdOf_matchesDerivation() public view {
        OrderParams memory p = _params(address(mailboxModule));
        Intent memory intent = _onchainIntent(p, user, 7);
        (bytes32 orderId,) = _ids(intent);
        assertEq(origin.orderIdOf(intent), orderId);
    }

    function test_open_revertsOnFeeOnTransferToken() public {
        FeeOnTransferToken fot = new FeeOnTransferToken();
        OrderParams memory p = _params(address(mailboxModule));
        IntentOrderData memory data = _orderData(p);
        data.inputToken = address(fot);
        fot.mint(user, p.inputAmount);
        vm.startPrank(user);
        fot.approve(address(origin), p.inputAmount);
        vm.expectRevert(
            abi.encodeWithSelector(
                OriginSettler.UnexpectedReceivedAmount.selector, p.inputAmount, p.inputAmount * 99 / 100
            )
        );
        origin.open(OnchainCrossChainOrder(p.fillDeadline, IntentLib.INTENT_ORDER_DATA_TYPEHASH, abi.encode(data)));
        vm.stopPrank();
    }

    // ------------------------------------------------------------------------------------------------------------
    // openFor (gasless, Permit2 witness)
    // ------------------------------------------------------------------------------------------------------------

    function test_openFor_pullsThroughPermit2WithWitness() public {
        OrderParams memory p = _params(address(proofModule));
        GaslessCrossChainOrder memory order = _gaslessOrder(p, 42);
        ResolvedCrossChainOrder memory expected = origin.resolveFor(order, "");

        inputToken.mint(user, p.inputAmount);
        vm.prank(user);
        inputToken.approve(PERMIT2_ADDRESS, type(uint256).max);
        bytes memory signature = _sign(order, userKey);
        vm.recordLogs();
        vm.prank(solver);
        origin.openFor(order, signature, "");

        ResolvedCrossChainOrder memory emitted = _decodeOpen(vm.getRecordedLogs(), expected.orderId);
        assertEq(keccak256(abi.encode(emitted)), keccak256(abi.encode(expected)));
        assertEq(inputToken.balanceOf(address(origin)), p.inputAmount);
        assertEq(uint8(origin.escrowOf(expected.orderId).status), uint8(OrderStatus.Open));
        // Permit2 nonce 42 is consumed: word 0, bit 42.
        (bool ok, bytes memory ret) =
            PERMIT2_ADDRESS.staticcall(abi.encodeWithSignature("nonceBitmap(address,uint256)", user, 0));
        assertTrue(ok);
        assertEq(abi.decode(ret, (uint256)), 1 << 42);
        (bytes32 orderId,) = _ids(_gaslessIntent(order));
        assertEq(expected.orderId, orderId);
    }

    function test_openFor_acceptsErc1271ContractWallet() public {
        SmartWallet wallet = new SmartWallet(user);
        OrderParams memory p = _params(address(mailboxModule));
        GaslessCrossChainOrder memory order = _gaslessOrder(p, 1);
        order.user = address(wallet);
        inputToken.mint(address(wallet), p.inputAmount);
        wallet.approve(address(inputToken), PERMIT2_ADDRESS);
        bytes memory signature = _sign(order, userKey);
        vm.prank(solver);
        origin.openFor(order, signature, "");
        assertEq(inputToken.balanceOf(address(origin)), p.inputAmount);
    }

    function test_openFor_revertsOnErc1271Rejection() public {
        SmartWallet wallet = new SmartWallet(user);
        OrderParams memory p = _params(address(mailboxModule));
        GaslessCrossChainOrder memory order = _gaslessOrder(p, 1);
        order.user = address(wallet);
        inputToken.mint(address(wallet), p.inputAmount);
        wallet.approve(address(inputToken), PERMIT2_ADDRESS);
        (, uint256 otherKey) = makeAddrAndKey("other");
        bytes memory signature = _sign(order, otherKey);
        vm.prank(solver);
        vm.expectRevert(PERMIT2_INVALID_CONTRACT_SIGNATURE);
        origin.openFor(order, signature, "");
    }

    function test_openFor_revertsOnWrongSigner() public {
        OrderParams memory p = _params(address(mailboxModule));
        GaslessCrossChainOrder memory order = _gaslessOrder(p, 1);
        inputToken.mint(user, p.inputAmount);
        vm.prank(user);
        inputToken.approve(PERMIT2_ADDRESS, type(uint256).max);
        (, uint256 otherKey) = makeAddrAndKey("other");
        bytes memory signature = _sign(order, otherKey);
        vm.prank(solver);
        vm.expectRevert(PERMIT2_INVALID_SIGNER);
        origin.openFor(order, signature, "");
    }

    function test_openFor_revertsWhenOrderDiffersFromWitness() public {
        OrderParams memory p = _params(address(mailboxModule));
        GaslessCrossChainOrder memory order = _gaslessOrder(p, 1);
        inputToken.mint(user, p.inputAmount);
        vm.prank(user);
        inputToken.approve(PERMIT2_ADDRESS, type(uint256).max);
        bytes memory signature = _sign(order, userKey);
        // The solver tries to lower the user's floor after the signature: the witness no longer matches.
        IntentOrderData memory data = abi.decode(order.orderData, (IntentOrderData));
        data.outputEndAmount = 1;
        order.orderData = abi.encode(data);
        vm.prank(solver);
        vm.expectRevert(PERMIT2_INVALID_SIGNER);
        origin.openFor(order, signature, "");
    }

    function test_openFor_revertsOnReplay() public {
        OrderParams memory p = _params(address(mailboxModule));
        GaslessCrossChainOrder memory order = _gaslessOrder(p, 9);
        inputToken.mint(user, 2 * p.inputAmount);
        vm.prank(user);
        inputToken.approve(PERMIT2_ADDRESS, type(uint256).max);
        bytes memory signature = _sign(order, userKey);
        vm.prank(solver);
        origin.openFor(order, signature, "");
        (bytes32 orderId,) = _ids(_gaslessIntent(order));
        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSelector(OriginSettler.OrderAlreadyExists.selector, orderId));
        origin.openFor(order, signature, "");
    }

    function test_openFor_revertsOnNonceReuseAcrossOrders() public {
        OrderParams memory p = _params(address(mailboxModule));
        GaslessCrossChainOrder memory first = _gaslessOrder(p, 5);
        p.outputEnd = 980e18;
        GaslessCrossChainOrder memory second = _gaslessOrder(p, 5);
        inputToken.mint(user, 2 * p.inputAmount);
        vm.prank(user);
        inputToken.approve(PERMIT2_ADDRESS, type(uint256).max);
        bytes memory sig1 = _sign(first, userKey);
        bytes memory sig2 = _sign(second, userKey);
        vm.startPrank(solver);
        origin.openFor(first, sig1, "");
        vm.expectRevert(PERMIT2_INVALID_NONCE);
        origin.openFor(second, sig2, "");
        vm.stopPrank();
    }

    function test_openFor_revertsOnWrongOriginSettler() public {
        GaslessCrossChainOrder memory order = _gaslessOrder(_params(address(mailboxModule)), 1);
        order.originSettler = address(0xBEEF);
        vm.expectRevert(
            abi.encodeWithSelector(OriginSettler.WrongOriginSettler.selector, address(origin), address(0xBEEF))
        );
        origin.openFor(order, "", "");
    }

    function test_openFor_revertsOnWrongOriginChain() public {
        GaslessCrossChainOrder memory order = _gaslessOrder(_params(address(mailboxModule)), 1);
        order.originChainId = 1;
        vm.expectRevert(abi.encodeWithSelector(OriginSettler.WrongOriginChain.selector, ORIGIN, 1));
        origin.openFor(order, "", "");
    }

    function test_openFor_revertsAfterOpenDeadline() public {
        GaslessCrossChainOrder memory order = _gaslessOrder(_params(address(mailboxModule)), 1);
        vm.warp(uint256(order.openDeadline) + 1);
        vm.expectRevert(
            abi.encodeWithSelector(OriginSettler.OpenDeadlinePassed.selector, order.openDeadline, block.timestamp)
        );
        origin.openFor(order, "", "");
    }

    function test_openFor_revertsOnUnsupportedOrderDataType() public {
        GaslessCrossChainOrder memory order = _gaslessOrder(_params(address(mailboxModule)), 1);
        order.orderDataType = keccak256("Other()");
        vm.expectRevert(abi.encodeWithSelector(OriginSettler.UnsupportedOrderDataType.selector, keccak256("Other()")));
        origin.openFor(order, "", "");
    }

    function test_open_revertsOnUnsupportedOrderDataType() public {
        OnchainCrossChainOrder memory order = _onchainOrder(_params(address(mailboxModule)));
        order.orderDataType = bytes32(0);
        vm.expectRevert(abi.encodeWithSelector(OriginSettler.UnsupportedOrderDataType.selector, bytes32(0)));
        vm.prank(user);
        origin.open(order);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Order-data validation (shared by open, openFor, resolve, resolveFor)
    // ------------------------------------------------------------------------------------------------------------

    function _expectInvalid(IntentOrderData memory data, uint32 fillDeadline, bytes memory reason) internal {
        OnchainCrossChainOrder memory order =
            OnchainCrossChainOrder(fillDeadline, IntentLib.INTENT_ORDER_DATA_TYPEHASH, abi.encode(data));
        vm.startPrank(user);
        vm.expectRevert(reason);
        origin.resolve(order);
        vm.expectRevert(reason);
        origin.open(order);
        vm.stopPrank();
    }

    function test_validate_missingAddresses() public {
        OrderParams memory p = _params(address(mailboxModule));
        IntentOrderData memory data = _orderData(p);
        data.inputToken = address(0);
        _expectInvalid(
            data, p.fillDeadline, abi.encodeWithSelector(OriginSettler.MissingOrderAddress.selector, "inputToken")
        );
        data = _orderData(p);
        data.outputToken = address(0);
        _expectInvalid(
            data, p.fillDeadline, abi.encodeWithSelector(OriginSettler.MissingOrderAddress.selector, "outputToken")
        );
        data = _orderData(p);
        data.recipient = address(0);
        _expectInvalid(
            data, p.fillDeadline, abi.encodeWithSelector(OriginSettler.MissingOrderAddress.selector, "recipient")
        );
        data = _orderData(p);
        data.destinationSettler = address(0);
        _expectInvalid(
            data,
            p.fillDeadline,
            abi.encodeWithSelector(OriginSettler.MissingOrderAddress.selector, "destinationSettler")
        );
    }

    function test_validate_amounts() public {
        OrderParams memory p = _params(address(mailboxModule));
        uint256[4][4] memory cases = [
            [uint256(0), p.outputStart, p.outputEnd, 0],
            [uint256(type(uint96).max) + 1, p.outputStart, p.outputEnd, 0],
            [p.inputAmount, p.outputStart, 0, 0],
            [p.inputAmount, p.outputEnd - 1, p.outputEnd, 0]
        ];
        for (uint256 i = 0; i < cases.length; ++i) {
            IntentOrderData memory data = _orderData(p);
            data.inputAmount = cases[i][0];
            data.outputStartAmount = cases[i][1];
            data.outputEndAmount = cases[i][2];
            _expectInvalid(
                data,
                p.fillDeadline,
                abi.encodeWithSelector(OriginSettler.InvalidAmounts.selector, cases[i][0], cases[i][1], cases[i][2])
            );
        }
    }

    function test_validate_destinationChain() public {
        OrderParams memory p = _params(address(mailboxModule));
        uint256[3] memory chains = [uint256(0), ORIGIN, uint256(type(uint64).max) + 1];
        for (uint256 i = 0; i < chains.length; ++i) {
            IntentOrderData memory data = _orderData(p);
            data.destinationChainId = chains[i];
            _expectInvalid(
                data, p.fillDeadline, abi.encodeWithSelector(OriginSettler.InvalidDestinationChain.selector, chains[i])
            );
        }
    }

    function test_validate_fillDeadlineMustBeInTheFuture() public {
        OrderParams memory p = _params(address(mailboxModule));
        uint32 deadline = uint32(block.timestamp);
        IntentOrderData memory data = _orderData(p);
        data.exclusivityDeadline = deadline;
        _expectInvalid(
            data, deadline, abi.encodeWithSelector(OriginSettler.FillDeadlinePassed.selector, deadline, block.timestamp)
        );
    }

    function test_validate_exclusivityWithinFillWindow() public {
        OrderParams memory p = _params(address(mailboxModule));
        IntentOrderData memory data = _orderData(p);
        data.exclusivityDeadline = p.fillDeadline + 1;
        _expectInvalid(
            data,
            p.fillDeadline,
            abi.encodeWithSelector(
                OriginSettler.InvalidExclusivityDeadline.selector, p.fillDeadline + 1, p.fillDeadline
            )
        );
    }

    function test_validate_settlementModuleMustBeEnabled() public {
        OrderParams memory p = _params(address(0xDEAD));
        _expectInvalid(
            _orderData(p),
            p.fillDeadline,
            abi.encodeWithSelector(OriginSettler.UnknownSettlementModule.selector, address(0xDEAD))
        );
    }

    function test_validate_moduleMustSupportDestination() public {
        OrderParams memory p = _params(address(mailboxModule));
        IntentOrderData memory data = _orderData(p);
        data.destinationSettler = address(0xD5);
        _expectInvalid(
            data,
            p.fillDeadline,
            abi.encodeWithSelector(
                OriginSettler.UnsupportedDestination.selector,
                address(mailboxModule),
                DEST,
                address(dest),
                address(0xD5)
            )
        );
        data = _orderData(p);
        data.destinationChainId = 77;
        _expectInvalid(
            data,
            p.fillDeadline,
            abi.encodeWithSelector(
                OriginSettler.UnsupportedDestination.selector, address(mailboxModule), 77, address(0), address(dest)
            )
        );
    }

    // ------------------------------------------------------------------------------------------------------------
    // Administration
    // ------------------------------------------------------------------------------------------------------------

    function test_constructor_rejectsZeroPermit2() public {
        vm.expectRevert(OriginSettler.ZeroPermit2.selector);
        new OriginSettler(ISignatureTransfer(address(0)), REFUND_GRACE, address(originManager));
    }

    function test_setSettlementModule_isRestricted() public {
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, address(this)));
        origin.setSettlementModule(address(mailboxModule), false);
    }

    function test_setSettlementModule_rejectsEoa() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(OriginSettler.ModuleNotContract.selector, address(0xE0A)));
        origin.setSettlementModule(address(0xE0A), true);
    }

    function test_setSettlementModule_disablingKeepsExistingOrdersSettleable() public {
        (bytes32 orderId, bytes memory originData) = _openOnchain(_params(address(mailboxModule)));
        vm.expectEmit(address(origin));
        emit OriginSettler.SettlementModuleSet(address(mailboxModule), false);
        vm.prank(admin);
        origin.setSettlementModule(address(mailboxModule), false);
        assertFalse(origin.isSettlementModule(address(mailboxModule)));

        _fill(orderId, originData, solver, solverRepayment);
        _reportAndRelay(orderId);
        assertEq(uint8(origin.escrowOf(orderId).status), uint8(OrderStatus.Repaid));
        assertEq(inputToken.balanceOf(solverRepayment), 1000e18);
    }

    // ------------------------------------------------------------------------------------------------------------
    // settle
    // ------------------------------------------------------------------------------------------------------------

    function test_settle_paysFillerOnce() public {
        OrderParams memory p = _params(address(mailboxModule));
        (bytes32 orderId, bytes memory originData) = _openOnchain(p);
        vm.expectEmit(address(origin));
        emit OriginSettler.OrderSettled(
            orderId, address(mailboxModule), solverRepayment, address(inputToken), p.inputAmount
        );
        vm.prank(address(mailboxModule));
        origin.settle(orderId, DEST, solverRepayment, keccak256(originData));
        assertEq(inputToken.balanceOf(solverRepayment), p.inputAmount);
        assertEq(uint8(origin.escrowOf(orderId).status), uint8(OrderStatus.Repaid));

        vm.prank(address(mailboxModule));
        vm.expectRevert(abi.encodeWithSelector(OriginSettler.OrderNotOpen.selector, orderId, OrderStatus.Repaid));
        origin.settle(orderId, DEST, solverRepayment, keccak256(originData));
    }

    function test_settle_revertsForUnknownOrder() public {
        vm.prank(address(mailboxModule));
        vm.expectRevert(
            abi.encodeWithSelector(OriginSettler.OrderNotOpen.selector, bytes32(uint256(1)), OrderStatus.None)
        );
        origin.settle(bytes32(uint256(1)), DEST, solver, bytes32(0));
    }

    function test_settle_onlyTheOrdersModule() public {
        (bytes32 orderId, bytes memory originData) = _openOnchain(_params(address(mailboxModule)));
        vm.prank(address(optimistic));
        vm.expectRevert(
            abi.encodeWithSelector(
                OriginSettler.UnauthorizedModule.selector, orderId, address(optimistic), address(mailboxModule)
            )
        );
        origin.settle(orderId, DEST, solver, keccak256(originData));
    }

    function test_settle_rejectsOtherDestinationChain() public {
        (bytes32 orderId, bytes memory originData) = _openOnchain(_params(address(mailboxModule)));
        vm.prank(address(mailboxModule));
        vm.expectRevert(abi.encodeWithSelector(OriginSettler.DestinationChainMismatch.selector, orderId, DEST, 5));
        origin.settle(orderId, 5, solver, keccak256(originData));
    }

    function test_settle_rejectsFillOfAnotherPayload() public {
        (bytes32 orderId,) = _openOnchain(_params(address(mailboxModule)));
        vm.prank(address(mailboxModule));
        vm.expectRevert(abi.encodeWithSelector(OriginSettler.FillHashMismatch.selector, orderId, bytes32(uint256(7))));
        origin.settle(orderId, DEST, solver, bytes32(uint256(7)));
    }

    function test_settle_rejectsZeroFiller() public {
        (bytes32 orderId, bytes memory originData) = _openOnchain(_params(address(mailboxModule)));
        vm.prank(address(mailboxModule));
        vm.expectRevert(OriginSettler.ZeroFiller.selector);
        origin.settle(orderId, DEST, address(0), keccak256(originData));
    }

    // ------------------------------------------------------------------------------------------------------------
    // refund
    // ------------------------------------------------------------------------------------------------------------

    function test_refund_afterDeadlinePlusGrace() public {
        OrderParams memory p = _params(address(proofModule));
        (bytes32 orderId,) = _openOnchain(p);
        uint256 availableAfter = uint256(p.fillDeadline) + REFUND_GRACE;
        vm.warp(availableAfter);
        vm.expectRevert(abi.encodeWithSelector(OriginSettler.RefundNotYetAvailable.selector, orderId, availableAfter));
        origin.refund(orderId);

        vm.warp(availableAfter + 1);
        vm.expectEmit(address(origin));
        emit OriginSettler.OrderRefunded(orderId, user, address(inputToken), p.inputAmount);
        vm.prank(rival); // anyone can trigger it; the funds go to the user
        origin.refund(orderId);
        assertEq(inputToken.balanceOf(user), p.inputAmount);
        assertEq(uint8(origin.escrowOf(orderId).status), uint8(OrderStatus.Refunded));

        vm.expectRevert(abi.encodeWithSelector(OriginSettler.OrderNotOpen.selector, orderId, OrderStatus.Refunded));
        origin.refund(orderId);
    }

    function test_refund_thenSettleIsImpossible() public {
        OrderParams memory p = _params(address(mailboxModule));
        (bytes32 orderId, bytes memory originData) = _openOnchain(p);
        _fill(orderId, originData, solver, solverRepayment);
        vm.warp(uint256(p.fillDeadline) + REFUND_GRACE + 1);
        vm.chainId(ORIGIN);
        origin.refund(orderId);
        // The late report cannot pay the solver any more: refund and repayment are mutually exclusive.
        vm.chainId(DEST);
        vm.recordLogs();
        reporter.report(orderId, ORIGIN);
        bytes memory message = _lastDispatch();
        vm.chainId(ORIGIN);
        vm.prank(mailboxRelayer);
        vm.expectRevert(abi.encodeWithSelector(OriginSettler.OrderNotOpen.selector, orderId, OrderStatus.Refunded));
        originMailbox.process(message);
    }

    function test_refund_blockedWhileClaimPending() public {
        OrderParams memory p = _params(address(optimistic));
        (bytes32 orderId, bytes memory originData) = _openOnchain(p);
        uint64 filledAt = uint64(block.timestamp);
        bondToken.mint(solver, BOND);
        vm.startPrank(solver);
        bondToken.approve(address(optimistic), BOND);
        optimistic.claim(orderId, solverRepayment, filledAt, keccak256(originData));
        vm.stopPrank();

        vm.warp(uint256(p.fillDeadline) + REFUND_GRACE + 1);
        vm.expectRevert(abi.encodeWithSelector(OriginSettler.RepaymentClaimPending.selector, orderId));
        origin.refund(orderId);
    }

    function test_refund_revertsForUnknownOrder() public {
        vm.expectRevert(abi.encodeWithSelector(OriginSettler.OrderNotOpen.selector, bytes32(0), OrderStatus.None));
        origin.refund(bytes32(0));
    }

    // ------------------------------------------------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------------------------------------------------

    function _decodeOpen(Vm.Log[] memory logs, bytes32 orderId) internal view returns (ResolvedCrossChainOrder memory) {
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter == address(origin) && logs[i].topics[0] == IOriginSettler.Open.selector) {
                assertEq(logs[i].topics[1], orderId);
                return abi.decode(logs[i].data, (ResolvedCrossChainOrder));
            }
        }
        revert("no Open");
    }
}
