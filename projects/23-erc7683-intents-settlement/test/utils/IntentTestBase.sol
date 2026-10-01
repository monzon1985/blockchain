// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test, Vm} from "forge-std/Test.sol";
import {AccessManager} from "@openzeppelin-contracts/access/manager/AccessManager.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";

import {DestinationSettler} from "../../src/DestinationSettler.sol";
import {OriginSettler} from "../../src/OriginSettler.sol";
import {ERC7683ResolverAdapter} from "../../src/adapters/ERC7683ResolverAdapter.sol";
import {GaslessCrossChainOrder, OnchainCrossChainOrder} from "../../src/erc7683/IERC7683.sol";
import {IEscrowSettler} from "../../src/interfaces/IEscrowSettler.sol";
import {IMailbox} from "../../src/interfaces/IMailbox.sol";
import {Intent, IntentLib, IntentOrderData} from "../../src/libraries/IntentLib.sol";
import {MailboxFillReporter} from "../../src/settlement/mailbox/MailboxFillReporter.sol";
import {MailboxSettlementModule} from "../../src/settlement/mailbox/MailboxSettlementModule.sol";
import {MockMailbox} from "../../src/settlement/mailbox/MockMailbox.sol";
import {OptimisticSettlementModule} from "../../src/settlement/optimistic/OptimisticSettlementModule.sol";
import {HeaderStore} from "../../src/settlement/proof/HeaderStore.sol";
import {StorageProofSettlementModule} from "../../src/settlement/proof/StorageProofSettlementModule.sol";
import {DestStateProofs} from "./DestStateProofs.sol";
import {MockERC20} from "./TestTokens.sol";

/// @notice Two chains in one EVM: origin contracts live on chain 1001, destination contracts on chain 1002, and every
/// helper switches `block.chainid` with vm.chainId before acting, so the chain-binding checks run for real.
abstract contract IntentTestBase is Test {
    uint256 internal constant ORIGIN = 1001;
    uint256 internal constant DEST = 1002;
    uint256 internal constant REFUND_GRACE = 1 hours;
    uint256 internal constant BOND = 50e18;
    uint256 internal constant CHALLENGE_WINDOW = 30 minutes;
    uint64 internal constant HEADER_RELAYER_ROLE = 1;
    uint64 internal constant MAILBOX_RELAYER_ROLE = 2;
    address internal constant PERMIT2_ADDRESS = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    bytes32 internal constant TOKEN_PERMISSIONS_TYPEHASH = keccak256("TokenPermissions(address token,uint256 amount)");
    string internal constant PERMIT_WITNESS_STUB =
        "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,";

    // actors
    address internal admin = makeAddr("admin");
    address internal headerRelayer = makeAddr("headerRelayer");
    address internal mailboxRelayer = makeAddr("mailboxRelayer");
    address internal user;
    uint256 internal userKey;
    address internal solver = makeAddr("solver");
    address internal solverRepayment = makeAddr("solverRepayment");
    address internal rival = makeAddr("rival");
    address internal challenger = makeAddr("challenger");
    address internal recipient = makeAddr("recipient");

    // origin chain
    ISignatureTransfer internal permit2;
    AccessManager internal originManager;
    OriginSettler internal origin;
    MockMailbox internal originMailbox;
    MailboxSettlementModule internal mailboxModule;
    HeaderStore internal headers;
    OptimisticSettlementModule internal optimistic;
    StorageProofSettlementModule internal proofModule;
    ERC7683ResolverAdapter internal adapter;
    MockERC20 internal inputToken;
    MockERC20 internal bondToken;

    // destination chain
    AccessManager internal destManager;
    DestinationSettler internal dest;
    MockMailbox internal destMailbox;
    MailboxFillReporter internal reporter;
    MockERC20 internal outputToken;

    /// @dev Order ids whose destination storage the synthetic state tries must reflect.
    bytes32[] internal trackedOrders;
    uint256 internal destBlockNumber = 100;

    struct OrderParams {
        address module;
        uint256 inputAmount;
        uint256 outputStart;
        uint256 outputEnd;
        address exclusiveFiller;
        uint32 exclusivityDeadline;
        uint32 fillDeadline;
    }

    function setUp() public virtual {
        (user, userKey) = makeAddrAndKey("user");
        vm.warp(1_750_000_000);
        _deployDestination();
        _deployOrigin();
        _wire();
    }

    // ------------------------------------------------------------------------------------------------------------
    // Deployment
    // ------------------------------------------------------------------------------------------------------------

    function _deployDestination() internal {
        vm.chainId(DEST);
        vm.startPrank(admin);
        destManager = new AccessManager(admin);
        dest = new DestinationSettler();
        destMailbox = new MockMailbox(address(destManager));
        reporter = new MailboxFillReporter(dest, IMailbox(address(destMailbox)), address(destManager));
        outputToken = new MockERC20("Output", "OUT");
        vm.stopPrank();
    }

    function _deployOrigin() internal {
        vm.chainId(ORIGIN);
        deployCodeTo("Permit2.sol:Permit2", PERMIT2_ADDRESS);
        permit2 = ISignatureTransfer(PERMIT2_ADDRESS);
        vm.startPrank(admin);
        originManager = new AccessManager(admin);
        origin = new OriginSettler(permit2, REFUND_GRACE, address(originManager));
        originMailbox = new MockMailbox(address(originManager));
        mailboxModule = new MailboxSettlementModule(
            IEscrowSettler(address(origin)), address(originMailbox), address(originManager)
        );
        headers = new HeaderStore(address(originManager));
        bondToken = new MockERC20("Bond", "BOND");
        optimistic = new OptimisticSettlementModule(
            IEscrowSettler(address(origin)), headers, bondToken, BOND, CHALLENGE_WINDOW, address(originManager)
        );
        proofModule = new StorageProofSettlementModule(IEscrowSettler(address(origin)), headers, address(originManager));
        adapter = new ERC7683ResolverAdapter(origin, mailboxModule, optimistic, proofModule, 5 minutes, 2 minutes);
        inputToken = new MockERC20("Input", "IN");
        vm.stopPrank();
    }

    function _wire() internal {
        vm.chainId(ORIGIN);
        vm.startPrank(admin);
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = HeaderStore.submitHeader.selector;
        originManager.setTargetFunctionRole(address(headers), selectors, HEADER_RELAYER_ROLE);
        originManager.grantRole(HEADER_RELAYER_ROLE, headerRelayer, 0);
        selectors[0] = MockMailbox.process.selector;
        originManager.setTargetFunctionRole(address(originMailbox), selectors, MAILBOX_RELAYER_ROLE);
        originManager.grantRole(MAILBOX_RELAYER_ROLE, mailboxRelayer, 0);
        mailboxModule.setRoute(DEST, address(reporter), address(dest));
        optimistic.setDestinationSettler(DEST, address(dest));
        proofModule.setDestinationSettler(DEST, address(dest));
        origin.setSettlementModule(address(mailboxModule), true);
        origin.setSettlementModule(address(optimistic), true);
        origin.setSettlementModule(address(proofModule), true);
        vm.stopPrank();

        vm.chainId(DEST);
        vm.startPrank(admin);
        selectors[0] = MockMailbox.process.selector;
        destManager.setTargetFunctionRole(address(destMailbox), selectors, MAILBOX_RELAYER_ROLE);
        destManager.grantRole(MAILBOX_RELAYER_ROLE, mailboxRelayer, 0);
        reporter.setOriginModule(ORIGIN, address(mailboxModule));
        vm.stopPrank();
        vm.chainId(ORIGIN);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Orders
    // ------------------------------------------------------------------------------------------------------------

    function _params(address module) internal view returns (OrderParams memory) {
        return OrderParams({
            module: module,
            inputAmount: 1000e18,
            outputStart: 999e18,
            outputEnd: 990e18,
            exclusiveFiller: address(0),
            exclusivityDeadline: uint32(block.timestamp + 60),
            fillDeadline: uint32(block.timestamp + 600)
        });
    }

    function _orderData(OrderParams memory p) internal view returns (IntentOrderData memory) {
        return IntentOrderData({
            inputToken: address(inputToken),
            inputAmount: p.inputAmount,
            outputToken: address(outputToken),
            outputStartAmount: p.outputStart,
            outputEndAmount: p.outputEnd,
            recipient: recipient,
            destinationChainId: DEST,
            destinationSettler: address(dest),
            exclusiveFiller: p.exclusiveFiller,
            exclusivityDeadline: p.exclusivityDeadline,
            settlementModule: p.module
        });
    }

    function _onchainOrder(OrderParams memory p) internal view returns (OnchainCrossChainOrder memory) {
        return OnchainCrossChainOrder({
            fillDeadline: p.fillDeadline,
            orderDataType: IntentLib.INTENT_ORDER_DATA_TYPEHASH,
            orderData: abi.encode(_orderData(p))
        });
    }

    function _gaslessOrder(OrderParams memory p, uint256 nonce) internal view returns (GaslessCrossChainOrder memory) {
        return GaslessCrossChainOrder({
            originSettler: address(origin),
            user: user,
            nonce: nonce,
            originChainId: ORIGIN,
            openDeadline: uint32(block.timestamp + 300),
            fillDeadline: p.fillDeadline,
            orderDataType: IntentLib.INTENT_ORDER_DATA_TYPEHASH,
            orderData: abi.encode(_orderData(p))
        });
    }

    /// @dev Intent of an order opened on-chain by `owner` with on-chain nonce `nonce`.
    function _onchainIntent(OrderParams memory p, address owner, uint256 nonce) internal view returns (Intent memory) {
        return Intent({
            originSettler: address(origin),
            user: owner,
            nonce: nonce,
            originChainId: ORIGIN,
            openDeadline: type(uint32).max,
            fillDeadline: p.fillDeadline,
            data: _orderData(p)
        });
    }

    function _gaslessIntent(GaslessCrossChainOrder memory order) internal pure returns (Intent memory) {
        return Intent({
            originSettler: order.originSettler,
            user: order.user,
            nonce: order.nonce,
            originChainId: order.originChainId,
            openDeadline: order.openDeadline,
            fillDeadline: order.fillDeadline,
            data: abi.decode(order.orderData, (IntentOrderData))
        });
    }

    function _ids(Intent memory intent) internal pure returns (bytes32 orderId, bytes memory originData) {
        originData = abi.encode(intent);
        orderId = IntentLib.orderId(intent.originChainId, intent.originSettler, keccak256(originData));
    }

    /// @dev User opens `p` on the origin chain with a direct approval.
    function _openOnchain(OrderParams memory p) internal returns (bytes32 orderId, bytes memory originData) {
        vm.chainId(ORIGIN);
        uint256 nonce = origin.onchainNonce(user);
        inputToken.mint(user, p.inputAmount);
        vm.startPrank(user);
        inputToken.approve(address(origin), p.inputAmount);
        origin.open(_onchainOrder(p));
        vm.stopPrank();
        (orderId, originData) = _ids(_onchainIntent(p, user, nonce));
        trackedOrders.push(orderId);
    }

    /// @dev Permit2 PermitWitnessTransferFrom digest of `order` with this origin settler as spender.
    function _permit2Digest(GaslessCrossChainOrder memory order) internal view returns (bytes32) {
        IntentOrderData memory data = abi.decode(order.orderData, (IntentOrderData));
        bytes32 typeHash = keccak256(abi.encodePacked(PERMIT_WITNESS_STUB, IntentLib.PERMIT2_WITNESS_TYPE_STRING));
        bytes32 structHash = keccak256(
            abi.encode(
                typeHash,
                keccak256(abi.encode(TOKEN_PERMISSIONS_TYPEHASH, data.inputToken, data.inputAmount)),
                address(origin),
                order.nonce,
                uint256(order.openDeadline),
                origin.witnessHash(order)
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
    }

    function _domainSeparator() internal view returns (bytes32 separator) {
        (bool ok, bytes memory ret) = PERMIT2_ADDRESS.staticcall(abi.encodeWithSignature("DOMAIN_SEPARATOR()"));
        require(ok, "domain separator");
        separator = abi.decode(ret, (bytes32));
    }

    function _sign(GaslessCrossChainOrder memory order, uint256 key) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, _permit2Digest(order));
        return abi.encodePacked(r, s, v);
    }

    /// @dev User signs `p` once and the solver opens it through Permit2.
    function _openGasless(OrderParams memory p, uint256 nonce)
        internal
        returns (bytes32 orderId, bytes memory originData)
    {
        vm.chainId(ORIGIN);
        GaslessCrossChainOrder memory order = _gaslessOrder(p, nonce);
        inputToken.mint(user, p.inputAmount);
        vm.prank(user);
        inputToken.approve(PERMIT2_ADDRESS, type(uint256).max);
        bytes memory signature = _sign(order, userKey);
        vm.prank(solver);
        origin.openFor(order, signature, "");
        (orderId, originData) = _ids(_gaslessIntent(order));
        trackedOrders.push(orderId);
    }

    /// @dev `filler` fills on the destination chain, asking to be repaid at `repayment`.
    function _fill(bytes32 orderId, bytes memory originData, address filler, address repayment)
        internal
        returns (uint256 amount)
    {
        vm.chainId(DEST);
        amount = dest.outputAt(originData, block.timestamp);
        outputToken.mint(filler, amount);
        vm.startPrank(filler);
        outputToken.approve(address(dest), amount);
        dest.fill(orderId, originData, abi.encode(repayment));
        vm.stopPrank();
    }

    // ------------------------------------------------------------------------------------------------------------
    // Settlement plumbing
    // ------------------------------------------------------------------------------------------------------------

    /// @dev Reports a fill on the destination chain and relays the mailbox message to the origin chain.
    function _reportAndRelay(bytes32 orderId) internal {
        vm.chainId(DEST);
        vm.recordLogs();
        reporter.report(orderId, ORIGIN);
        bytes memory message = _lastDispatch();
        vm.chainId(ORIGIN);
        vm.prank(mailboxRelayer);
        originMailbox.process(message);
    }

    function _lastDispatch() internal view returns (bytes memory message) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = logs.length; i > 0; --i) {
            if (logs[i - 1].topics[0] == MockMailbox.Dispatch.selector) return abi.decode(logs[i - 1].data, (bytes));
        }
        revert("no Dispatch");
    }

    /// @notice A relayed destination state and the proofs of one FillRecord slot against it.
    struct DestProof {
        uint256 blockNumber;
        bytes[] accountProof;
        bytes[] slotProof;
    }

    /// @dev Snapshots the destination settler's real storage (every tracked order), has the relayer store a header
    ///      over it on the origin chain at the current timestamp, and returns the proofs for `orderId`.
    function _relayDestState(bytes32 orderId) internal returns (DestProof memory proof) {
        proof.blockNumber = ++destBlockNumber;
        DestStateProofs.Snapshot memory snap =
            DestStateProofs.snapshot(address(dest), trackedOrders, orderId, proof.blockNumber, block.timestamp);
        vm.chainId(ORIGIN);
        vm.prank(headerRelayer);
        headers.submitHeader(DEST, snap.header);
        proof.accountProof = snap.accountProof;
        proof.slotProof = snap.slotProof;
    }

    /// @dev The header an attacker would pick: the relayer stores an honest header over the settler's real storage
    ///      (proofs of `orderId`), and ANYONE then imports its parent, a block from before the settler was deployed,
    ///      through the permissionless `submitAncestor`. Returns the ancestor, whose account proof is an exclusion
    ///      proof of the settler, and the child.
    function _relayWithPreDeploymentAncestor(bytes32 orderId, uint256 ancestorTimestamp)
        internal
        returns (DestProof memory ancestor, DestProof memory child)
    {
        ancestor.blockNumber = ++destBlockNumber;
        DestStateProofs.Snapshot memory before =
            DestStateProofs.snapshotBeforeDeployment(address(dest), ancestor.blockNumber, ancestorTimestamp);
        child.blockNumber = ++destBlockNumber;
        DestStateProofs.Snapshot memory snap = DestStateProofs.snapshotWithParent(
            address(dest), trackedOrders, orderId, child.blockNumber, block.timestamp, keccak256(before.header)
        );
        vm.chainId(ORIGIN);
        vm.prank(headerRelayer);
        headers.submitHeader(DEST, snap.header);
        vm.prank(makeAddr("anyone"));
        headers.submitAncestor(DEST, child.blockNumber, snap.header, before.header);
        ancestor.accountProof = before.accountProof;
        ancestor.slotProof = before.slotProof;
        child.accountProof = snap.accountProof;
        child.slotProof = snap.slotProof;
    }

    /// @dev Posts a bonded optimistic claim for `orderId` from `claimant` (bond minted and approved).
    function _claimAs(address claimant, bytes32 orderId, bytes memory originData, address filler, uint64 filledAt)
        internal
    {
        vm.chainId(ORIGIN);
        bondToken.mint(claimant, BOND);
        vm.startPrank(claimant);
        bondToken.approve(address(optimistic), BOND);
        optimistic.claim(orderId, filler, filledAt, keccak256(originData));
        vm.stopPrank();
    }

    function _fillHash(bytes memory originData) internal pure returns (bytes32) {
        return keccak256(originData);
    }
}
