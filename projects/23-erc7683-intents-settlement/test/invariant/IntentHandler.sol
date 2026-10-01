// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {Vm} from "forge-std/Vm.sol";

import {DestinationSettler} from "../../src/DestinationSettler.sol";
import {OriginSettler} from "../../src/OriginSettler.sol";
import {GaslessCrossChainOrder, OnchainCrossChainOrder} from "../../src/erc7683/IERC7683.sol";
import {Escrow, OrderStatus} from "../../src/interfaces/IEscrowSettler.sol";
import {IMailbox} from "../../src/interfaces/IMailbox.sol";
import {FillProofLib} from "../../src/libraries/FillProofLib.sol";
import {Intent, IntentLib, IntentOrderData} from "../../src/libraries/IntentLib.sol";
import {MailboxFillReporter} from "../../src/settlement/mailbox/MailboxFillReporter.sol";
import {MailboxSettlementModule} from "../../src/settlement/mailbox/MailboxSettlementModule.sol";
import {MockMailbox} from "../../src/settlement/mailbox/MockMailbox.sol";
import {OptimisticSettlementModule} from "../../src/settlement/optimistic/OptimisticSettlementModule.sol";
import {HeaderStore} from "../../src/settlement/proof/HeaderStore.sol";
import {StorageProofSettlementModule} from "../../src/settlement/proof/StorageProofSettlementModule.sol";
import {DestStateProofs} from "../utils/DestStateProofs.sol";
import {MockERC20} from "../utils/TestTokens.sol";

/// @notice Contracts the handler drives, deployed by the invariant suite on chains 1001 and 1002 of one EVM.
struct Deployment {
    OriginSettler origin;
    DestinationSettler dest;
    MockMailbox originMailbox;
    MockMailbox destMailbox;
    MailboxFillReporter reporter;
    MailboxSettlementModule mailboxModule;
    OptimisticSettlementModule optimistic;
    StorageProofSettlementModule proofModule;
    HeaderStore headers;
    MockERC20 inputToken;
    MockERC20 outputToken;
    MockERC20 bondToken;
    address permit2;
    address headerRelayer;
    address mailboxRelayer;
}

/// @title IntentHandler
/// @notice Stateful fuzzing handler for the two-chain intent system. Actors: three users (on-chain and gasless
/// opens), three honest solvers, one attacker (fraudulent and squatting claims, forged mailbox reports, forged storage
/// proofs, double fills), one honest watcher that is always online (the optimistic mode's trust assumption, modelled
/// by scanning pending claims before every time step), and honest mailbox / header relayers.
/// @dev Where escrowed tokens went is OBSERVED, not assumed: every action runs inside `observed`, which snapshots
///      the input-token balance of every address the system knows (all actors, all contracts) before the action and
///      compares after it. An escrow that changed status must have moved exactly its amount from the OriginSettler to
///      exactly one address, and nothing else may have moved; the observed payee is what the invariants compare with
///      the destination fill record. Attacks that unexpectedly succeed increment `violations`.
contract IntentHandler is CommonBase, StdCheats, StdUtils {
    uint256 internal constant ORIGIN = 1001;
    uint256 internal constant DEST = 1002;
    uint256 internal constant MAX_ORDERS = 12;
    uint256 internal constant MAX_CLAIMS = 24;
    bytes32 internal constant TOKEN_PERMISSIONS_TYPEHASH = keccak256("TokenPermissions(address token,uint256 amount)");
    /// @dev Recorded as the payee when escrowed tokens left the OriginSettler to an address outside the known set.
    address internal constant UNKNOWN_PAYEE = address(1);

    Deployment internal d;

    /// @notice Everything the invariants need to know about an order.
    struct OrderInfo {
        bytes32 id;
        bytes originData;
        address module;
        address user;
        uint256 inputAmount;
        uint256 outputEnd;
        uint32 fillDeadline;
        address exclusiveFiller;
        uint32 exclusivityDeadline;
    }

    /// @notice A pending optimistic claim, by its key.
    struct ClaimRef {
        bytes32 orderId;
        address filler;
        uint64 filledAt;
    }

    OrderInfo[] internal _orders;
    bytes32[] internal _orderIds;
    ClaimRef[] internal _claims;
    bytes[] internal _pendingMessages;
    uint256 internal _destBlock = 1_000;
    uint256 internal _gaslessNonce = 1;

    address[3] internal users;
    uint256[3] internal userKeys;
    address[3] internal solvers;
    address[3] internal repayTo;
    address internal attacker = makeAddr("attacker");
    address internal watcher = makeAddr("watcher");
    address internal recipient = makeAddr("recipient");
    /// @dev Every address whose input-token balance `observed` tracks (the OriginSettler is tracked separately).
    address[] internal _known;

    // ghosts, all written by `observed` from balance changes
    mapping(bytes32 orderId => address) public ghostRepaidTo;
    mapping(bytes32 orderId => uint256) public ghostRepaidAmount;
    mapping(bytes32 orderId => address) public ghostRefundedTo;
    mapping(bytes32 orderId => uint256) public ghostRefundedAmount;
    mapping(bytes32 orderId => uint256) public ghostDelivered;
    mapping(bytes32 orderId => uint256) public ghostFirstRecord;
    mapping(bytes32 orderId => bool) public ghostHonestlyClaimed;
    uint256 public ghostEscrowed;
    uint256 public ghostRepaidSum;
    uint256 public ghostRefundedSum;
    /// @notice Input-token movements no status change explains (tokens leaving the escrow unaccounted, or moving
    /// between other addresses during an action).
    uint256 public unexplainedMovements;
    uint256 public violations;

    // call statistics, printed by the suite
    mapping(bytes32 action => uint256) public calls;

    // `observed` scratch state
    uint256[] internal _balancesBefore;
    uint8[] internal _statusBefore;
    uint256 internal _originBefore;
    uint256 internal _ordersBefore;

    constructor(Deployment memory deployment) {
        d = deployment;
        for (uint256 i = 0; i < 3; ++i) {
            (users[i], userKeys[i]) = makeAddrAndKey(string.concat("user", vm.toString(i)));
            solvers[i] = makeAddr(string.concat("solver", vm.toString(i)));
            repayTo[i] = makeAddr(string.concat("repay", vm.toString(i)));
            vm.startPrank(users[i]);
            d.inputToken.approve(address(d.origin), type(uint256).max);
            d.inputToken.approve(d.permit2, type(uint256).max);
            d.bondToken.approve(address(d.optimistic), type(uint256).max);
            vm.stopPrank();
            vm.prank(solvers[i]);
            d.outputToken.approve(address(d.dest), type(uint256).max);
            vm.prank(solvers[i]);
            d.bondToken.approve(address(d.optimistic), type(uint256).max);
            _known.push(users[i]);
            _known.push(solvers[i]);
            _known.push(repayTo[i]);
        }
        vm.prank(attacker);
        d.bondToken.approve(address(d.optimistic), type(uint256).max);
        vm.prank(attacker);
        d.outputToken.approve(address(d.dest), type(uint256).max);
        _known.push(attacker);
        _known.push(watcher);
        _known.push(recipient);
        _known.push(address(this));
        _known.push(address(d.dest));
        _known.push(address(d.originMailbox));
        _known.push(address(d.destMailbox));
        _known.push(address(d.reporter));
        _known.push(address(d.mailboxModule));
        _known.push(address(d.optimistic));
        _known.push(address(d.proofModule));
        _known.push(address(d.headers));
        _known.push(d.permit2);
        _known.push(d.headerRelayer);
        _known.push(d.mailboxRelayer);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Views for the invariant suite
    // ------------------------------------------------------------------------------------------------------------

    function orderCount() external view returns (uint256) {
        return _orders.length;
    }

    function orderAt(uint256 i) external view returns (OrderInfo memory) {
        return _orders[i];
    }

    function claimCount() external view returns (uint256) {
        return _claims.length;
    }

    // ------------------------------------------------------------------------------------------------------------
    // Observation of escrow releases
    // ------------------------------------------------------------------------------------------------------------

    /// @dev Snapshots balances and escrow statuses, runs the action, then attributes every escrow release to the
    ///      address that actually received the tokens.
    modifier observed() {
        _snapshot();
        _;
        _attribute();
    }

    function _snapshot() internal {
        delete _balancesBefore;
        for (uint256 i = 0; i < _known.length; ++i) {
            _balancesBefore.push(d.inputToken.balanceOf(_known[i]));
        }
        delete _statusBefore;
        for (uint256 i = 0; i < _orders.length; ++i) {
            _statusBefore.push(uint8(d.origin.escrowOf(_orders[i].id).status));
        }
        _originBefore = d.inputToken.balanceOf(address(d.origin));
        _ordersBefore = _orders.length;
    }

    function _attribute() internal {
        // Orders opened by this action added exactly their amount to the escrow.
        uint256 opened = 0;
        for (uint256 i = _ordersBefore; i < _orders.length; ++i) {
            opened += _orders[i].inputAmount;
        }
        // At most one escrow closes per action; find it.
        uint256 released = 0;
        bytes32 closedId;
        OrderStatus closedStatus = OrderStatus.None;
        for (uint256 i = 0; i < _ordersBefore; ++i) {
            OrderStatus status = d.origin.escrowOf(_orders[i].id).status;
            if (uint8(status) == _statusBefore[i]) continue;
            if (closedId != bytes32(0) || _statusBefore[i] != uint8(OrderStatus.Open)) {
                unexplainedMovements++;
                continue;
            }
            closedId = _orders[i].id;
            closedStatus = status;
            released = _orders[i].inputAmount;
        }
        uint256 originNow = d.inputToken.balanceOf(address(d.origin));
        if (originNow + released != _originBefore + opened) unexplainedMovements++;

        // Exactly one known address may have gained exactly `released`; no other known balance may change.
        address payee = released == 0 ? address(0) : UNKNOWN_PAYEE;
        for (uint256 i = 0; i < _known.length; ++i) {
            uint256 nowBalance = d.inputToken.balanceOf(_known[i]);
            if (nowBalance == _balancesBefore[i]) continue;
            if (payee == UNKNOWN_PAYEE && nowBalance == _balancesBefore[i] + released) {
                payee = _known[i];
            } else {
                unexplainedMovements++;
            }
        }
        if (closedId == bytes32(0)) return;
        if (closedStatus == OrderStatus.Repaid) {
            if (ghostRepaidTo[closedId] != address(0)) violations++; // paid twice
            ghostRepaidTo[closedId] = payee;
            ghostRepaidAmount[closedId] = released;
            ghostRepaidSum += released;
        } else if (closedStatus == OrderStatus.Refunded) {
            ghostRefundedTo[closedId] = payee;
            ghostRefundedAmount[closedId] = released;
            ghostRefundedSum += released;
        } else {
            unexplainedMovements++;
        }
    }

    // ------------------------------------------------------------------------------------------------------------
    // Actions
    // ------------------------------------------------------------------------------------------------------------

    function open(
        uint256 userSeed,
        uint256 moduleSeed,
        bool gasless,
        uint256 amountSeed,
        uint256 exclSeed,
        uint256 window
    ) external observed {
        if (_orders.length >= MAX_ORDERS) return;
        calls["open"]++;
        vm.chainId(ORIGIN);
        uint256 u = userSeed % 3;
        address module = moduleSeed % 3 == 0
            ? address(d.mailboxModule)
            : moduleSeed % 3 == 1 ? address(d.optimistic) : address(d.proofModule);
        uint256 inputAmount = bound(amountSeed, 1e6, 1e24);
        uint32 exclusivityDeadline = uint32(block.timestamp + bound(exclSeed >> 8, 0, 120));
        IntentOrderData memory data = IntentOrderData({
            inputToken: address(d.inputToken),
            inputAmount: inputAmount,
            outputToken: address(d.outputToken),
            outputStartAmount: inputAmount * 99 / 100,
            outputEndAmount: inputAmount * 97 / 100,
            recipient: recipient,
            destinationChainId: DEST,
            destinationSettler: address(d.dest),
            exclusiveFiller: exclSeed % 2 == 0 ? solvers[exclSeed % 3] : address(0),
            exclusivityDeadline: exclusivityDeadline,
            settlementModule: module
        });
        uint32 fillDeadline = uint32(uint256(exclusivityDeadline) + bound(window, 1, 3600));
        d.inputToken.mint(users[u], inputAmount);

        Intent memory intent;
        if (gasless) {
            GaslessCrossChainOrder memory order = GaslessCrossChainOrder({
                originSettler: address(d.origin),
                user: users[u],
                nonce: _gaslessNonce++,
                originChainId: ORIGIN,
                openDeadline: uint32(block.timestamp + 60),
                fillDeadline: fillDeadline,
                orderDataType: IntentLib.INTENT_ORDER_DATA_TYPEHASH,
                orderData: abi.encode(data)
            });
            bytes memory signature = _sign(order, data, userKeys[u]);
            vm.prank(solvers[0]);
            d.origin.openFor(order, signature, "");
            intent = Intent(address(d.origin), users[u], order.nonce, ORIGIN, order.openDeadline, fillDeadline, data);
        } else {
            uint256 nonce = d.origin.onchainNonce(users[u]);
            vm.prank(users[u]);
            d.origin.open(OnchainCrossChainOrder(fillDeadline, IntentLib.INTENT_ORDER_DATA_TYPEHASH, abi.encode(data)));
            intent = Intent(address(d.origin), users[u], nonce, ORIGIN, type(uint32).max, fillDeadline, data);
        }
        bytes memory originData = abi.encode(intent);
        bytes32 id = IntentLib.orderId(ORIGIN, address(d.origin), keccak256(originData));
        _orders.push(
            OrderInfo(
                id,
                originData,
                module,
                users[u],
                inputAmount,
                data.outputEndAmount,
                fillDeadline,
                data.exclusiveFiller,
                exclusivityDeadline
            )
        );
        _orderIds.push(id);
        ghostEscrowed += inputAmount;
    }

    function fill(uint256 idx, uint256 solverSeed, uint256 wait) external observed {
        if (_orders.length == 0) return;
        _advance(bound(wait, 0, 120));
        (bool found, OrderInfo memory o) = _find(idx, Want.Fillable);
        if (!found) return;
        calls["fill"]++;
        vm.chainId(DEST);
        uint256 s = solverSeed % 3;
        if (o.exclusiveFiller != address(0) && block.timestamp <= o.exclusivityDeadline) {
            for (uint256 i = 0; i < 3; ++i) {
                if (solvers[i] == o.exclusiveFiller) s = i;
            }
        }
        uint256 amount = d.dest.outputAt(o.originData, block.timestamp);
        d.outputToken.mint(solvers[s], amount);
        uint256 before = d.outputToken.balanceOf(recipient);
        vm.prank(solvers[s]);
        d.dest.fill(o.id, o.originData, abi.encode(repayTo[s]));
        ghostDelivered[o.id] = d.outputToken.balanceOf(recipient) - before;
        ghostFirstRecord[o.id] = uint256(vm.load(address(d.dest), FillProofLib.fillerSlot(o.id)));
    }

    /// @dev Attacker: second fill of a filled order, or a late fill. Must always revert.
    function attackFill(uint256 idx) external observed {
        if (_orders.length == 0) return;
        calls["attackFill"]++;
        OrderInfo memory o = _orders[idx % _orders.length];
        vm.chainId(DEST);
        bool filled = d.dest.fillRecord(o.id).filler != address(0);
        if (!filled && block.timestamp <= o.fillDeadline) return; // that would be a legitimate fill
        d.outputToken.mint(attacker, d.dest.outputAt(o.originData, block.timestamp));
        vm.prank(attacker);
        try d.dest.fill(o.id, o.originData, "") {
            violations++;
        } catch {}
    }

    function report(uint256 idx) external observed {
        (bool found, OrderInfo memory o) = _find(idx, Want.Reportable);
        if (!found) return;
        calls["report"]++;
        vm.chainId(DEST);
        vm.recordLogs();
        d.reporter.report(o.id, ORIGIN);
        _pendingMessages.push(_lastDispatch());
    }

    function relay(uint256 seed) external observed {
        if (_pendingMessages.length == 0) return;
        calls["relay"]++;
        uint256 i = seed % _pendingMessages.length;
        bytes memory message = _pendingMessages[i];
        _pendingMessages[i] = _pendingMessages[_pendingMessages.length - 1];
        _pendingMessages.pop();
        vm.chainId(ORIGIN);
        vm.prank(d.mailboxRelayer);
        // A second report of an order that is already closed is rejected (OrderNotOpen); that is expected.
        try d.originMailbox.process(message) {} catch {}
    }

    /// @dev Attacker dispatches a report for any order (filled or not) from a contract that is not the reporter.
    function forgeReport(uint256 idx) external observed {
        if (_orders.length == 0) return;
        calls["forgeReport"]++;
        OrderInfo memory o = _orders[idx % _orders.length];
        vm.chainId(DEST);
        vm.recordLogs();
        vm.prank(attacker);
        IMailbox(address(d.destMailbox))
            .dispatch(
                ORIGIN,
                address(d.mailboxModule),
                abi.encode(o.id, attacker, keccak256(o.originData), uint64(block.timestamp))
            );
        bytes memory message = _lastDispatch();
        vm.chainId(ORIGIN);
        vm.prank(d.mailboxRelayer);
        try d.originMailbox.process(message) {
            violations++;
        } catch {}
    }

    function claimHonest(uint256 idx, uint256 solverSeed) external observed {
        (bool found, OrderInfo memory o) = _find(idx, Want.HonestlyClaimable);
        if (!found) return;
        calls["claimHonest"]++;
        vm.chainId(DEST);
        DestinationSettler.FillRecord memory record = d.dest.fillRecord(o.id);
        vm.chainId(ORIGIN);
        address claimant = solvers[solverSeed % 3];
        d.bondToken.mint(claimant, d.optimistic.BOND());
        vm.prank(claimant);
        d.optimistic.claim(o.id, record.filler, record.filledAt, keccak256(o.originData));
        _claims.push(ClaimRef(o.id, record.filler, record.filledAt));
        ghostHonestlyClaimed[o.id] = true;
    }

    /// @dev A false claim: the attacker claims an order it did not fill or misstates who filled it or when, or the
    ///      order's own user squats its order with a false claim (then tries to refund). Several false claims of one
    ///      order can be pending next to the honest one.
    function claimFraud(uint256 idx, uint256 kind) external observed {
        (bool found, OrderInfo memory o) = _find(idx, Want.Claimable);
        if (!found || _claims.length >= MAX_CLAIMS) return;
        vm.chainId(DEST);
        DestinationSettler.FillRecord memory record = d.dest.fillRecord(o.id);
        vm.chainId(ORIGIN);
        uint256 latest = block.timestamp < o.fillDeadline ? block.timestamp : o.fillDeadline;
        address claimant = kind % 3 == 2 ? o.user : attacker;
        address filler = claimant;
        uint64 filledAt = uint64(latest - (kind >> 8) % (latest + 1));
        if (record.filler != address(0) && kind % 3 == 1) {
            filler = record.filler; // right filler, wrong time
            filledAt = record.filledAt == latest ? record.filledAt - 1 : uint64(latest);
        }
        if (d.optimistic.claimOf(o.id, filler, filledAt).claimant != address(0)) return; // same assertion pending
        calls["claimFraud"]++;
        d.bondToken.mint(claimant, d.optimistic.BOND());
        vm.prank(claimant);
        d.optimistic.claim(o.id, filler, filledAt, keccak256(o.originData));
        _claims.push(ClaimRef(o.id, filler, filledAt));
        // The honest watcher challenges it at its next pass, which always happens before time moves on.
        if (claimant == o.user) {
            vm.prank(o.user);
            try d.origin.refund(o.id) {} catch {} // the squatter's refund attempt; observed like any other action
        }
    }

    function finalize(uint256 seed) external observed {
        if (_claims.length == 0) return;
        vm.chainId(ORIGIN);
        uint256 n = _claims.length;
        for (uint256 k = 0; k < n; ++k) {
            uint256 i = (seed % n + k) % n;
            ClaimRef memory c = _claims[i];
            OptimisticSettlementModule.Claim memory pending = d.optimistic.claimOf(c.orderId, c.filler, c.filledAt);
            if (block.timestamp <= pending.challengeDeadline) continue;
            calls["finalize"]++;
            d.optimistic.finalize(c.orderId, c.filler, c.filledAt);
            _removeClaim(i);
            return;
        }
    }

    function prove(uint256 idx) external observed {
        (bool found, OrderInfo memory o) = _find(idx, Want.Provable);
        if (!found) return;
        calls["prove"]++;
        (uint256 blockNumber, DestStateProofs.Snapshot memory snap) = _relay(o.id);
        d.proofModule.proveFill(o.id, blockNumber, keccak256(o.originData), snap.accountProof, snap.slotProof);
    }

    /// @dev Attacker submits a proof for an order using another order's record, or a tampered proof.
    function forgeProof(uint256 idx, uint256 otherIdx, uint256 flip) external observed {
        if (_orders.length < 2) return;
        OrderInfo memory o = _orders[idx % _orders.length];
        if (o.module != address(d.proofModule)) return;
        calls["forgeProof"]++;
        OrderInfo memory other = _orders[otherIdx % _orders.length];
        vm.chainId(DEST);
        bool filled = d.dest.fillRecord(o.id).filler != address(0);
        (uint256 blockNumber, DestStateProofs.Snapshot memory snap) = _relay(other.id);
        bool forged = other.id != o.id;
        if (!forged && snap.slotProof.length > 0) {
            // Same order: tamper with one byte instead.
            bytes memory node = snap.slotProof[flip % snap.slotProof.length];
            node[(flip >> 64) % node.length] ^= bytes1(uint8(1 + (flip >> 128) % 255));
            forged = true;
        }
        if (!forged || filled) return;
        vm.prank(attacker);
        try d.proofModule.proveFill(o.id, blockNumber, keccak256(o.originData), snap.accountProof, snap.slotProof) {
            violations++;
        } catch {}
    }

    function refund(uint256 idx) external observed {
        (bool found, OrderInfo memory o) = _find(idx, Want.Refundable);
        if (!found) return;
        calls["refund"]++;
        vm.chainId(ORIGIN);
        try d.origin.refund(o.id) {} catch {}
    }

    function advance(uint256 dt) external observed {
        calls["advance"]++;
        _advance(bound(dt, 1, 70 minutes));
    }

    // ------------------------------------------------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------------------------------------------------

    /// @dev What an action needs from an order. `_find` scans from a fuzzed index for the first match so that
    ///      actions rarely degenerate into no-ops.
    enum Want {
        Fillable,
        Reportable,
        HonestlyClaimable,
        Claimable,
        Provable,
        Refundable
    }

    function _find(uint256 idx, Want want) internal returns (bool, OrderInfo memory o) {
        uint256 n = _orders.length;
        for (uint256 k = 0; k < n; ++k) {
            o = _orders[(idx % n + k) % n];
            if (_matches(o, want)) return (true, o);
        }
        return (false, o);
    }

    function _matches(OrderInfo memory o, Want want) internal returns (bool) {
        vm.chainId(DEST);
        DestinationSettler.FillRecord memory record = d.dest.fillRecord(o.id);
        bool filled = record.filler != address(0);
        vm.chainId(ORIGIN);
        bool isOpen = d.origin.escrowOf(o.id).status == OrderStatus.Open;
        if (want == Want.Fillable) return !filled && block.timestamp <= o.fillDeadline;
        if (want == Want.Reportable) return filled && o.module == address(d.mailboxModule);
        if (want == Want.Provable) return filled && isOpen && o.module == address(d.proofModule);
        if (want == Want.Refundable) {
            return isOpen && block.timestamp > uint256(o.fillDeadline) + d.origin.REFUND_GRACE();
        }
        bool claimable = o.module == address(d.optimistic) && isOpen;
        if (want == Want.HonestlyClaimable) {
            return claimable && filled && _claims.length < MAX_CLAIMS
                && d.optimistic.claimOf(o.id, record.filler, record.filledAt).claimant == address(0);
        }
        return claimable; // Want.Claimable
    }

    /// @dev The honest watcher runs before time moves: every pending claim that disagrees with the destination
    ///      record is challenged with a fresh proof, and dropped from the list.
    function _advance(uint256 dt) internal {
        _watch();
        vm.warp(block.timestamp + dt);
    }

    function _watch() internal {
        uint256 i = 0;
        while (i < _claims.length) {
            ClaimRef memory c = _claims[i];
            vm.chainId(ORIGIN);
            uint256 actual = uint256(vm.load(address(d.dest), FillProofLib.fillerSlot(c.orderId)));
            if (actual == FillProofLib.pack(c.filler, c.filledAt)) {
                ++i;
                continue;
            }
            if (block.timestamp <= c.filledAt) vm.warp(uint256(c.filledAt) + 1);
            (uint256 blockNumber, DestStateProofs.Snapshot memory snap) = _relay(c.orderId);
            vm.prank(watcher);
            d.optimistic.challenge(c.orderId, c.filler, c.filledAt, blockNumber, snap.accountProof, snap.slotProof);
            calls["challenge"]++;
            _removeClaim(i);
        }
    }

    function _removeClaim(uint256 i) internal {
        _claims[i] = _claims[_claims.length - 1];
        _claims.pop();
    }

    function _relay(bytes32 target) internal returns (uint256 blockNumber, DestStateProofs.Snapshot memory snap) {
        blockNumber = ++_destBlock;
        snap = DestStateProofs.snapshot(address(d.dest), _orderIds, target, blockNumber, block.timestamp);
        vm.chainId(ORIGIN);
        vm.prank(d.headerRelayer);
        d.headers.submitHeader(DEST, snap.header);
    }

    function _lastDispatch() internal view returns (bytes memory) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = logs.length; i > 0; --i) {
            if (logs[i - 1].topics[0] == MockMailbox.Dispatch.selector) return abi.decode(logs[i - 1].data, (bytes));
        }
        revert("no Dispatch");
    }

    function _sign(GaslessCrossChainOrder memory order, IntentOrderData memory data, uint256 key)
        internal
        view
        returns (bytes memory)
    {
        bytes32 typeHash = keccak256(
            abi.encodePacked(
                "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,",
                IntentLib.PERMIT2_WITNESS_TYPE_STRING
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                typeHash,
                keccak256(abi.encode(TOKEN_PERMISSIONS_TYPEHASH, data.inputToken, data.inputAmount)),
                address(d.origin),
                order.nonce,
                uint256(order.openDeadline),
                d.origin.witnessHash(order)
            )
        );
        (, bytes memory ret) = d.permit2.staticcall(abi.encodeWithSignature("DOMAIN_SEPARATOR()"));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", abi.decode(ret, (bytes32)), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }
}
