// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {AccessManager} from "@openzeppelin-contracts/access/manager/AccessManager.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";

import {DestinationSettler} from "../../src/DestinationSettler.sol";
import {OriginSettler} from "../../src/OriginSettler.sol";
import {OnchainCrossChainOrder} from "../../src/erc7683/IERC7683.sol";
import {IEscrowSettler, OrderStatus} from "../../src/interfaces/IEscrowSettler.sol";
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

/// @title IntentMedusaHarness
/// @notice Medusa harness for the same cross-chain model as the Foundry invariant suite, written against the HEVM
/// cheatcodes Medusa implements (chainId, warp, prank, load). Medusa moves block timestamps between transactions on
/// its own (`blockTimestampDelayMax` in medusa.json), but every action first re-applies the harness clock
/// (`synced`), so time only moves through `advance`, which lets the honest watcher act first, as in the Foundry
/// suite. Gasless (Permit2) opens are covered by the Foundry suites; here orders are opened on-chain.
///
/// Three kinds of checks:
///   - `property_*`: the invariants INV-1 to INV-8, evaluated after every call.
///   - `assert` post-conditions inside the actions (assertion mode): every action runs inside `observed`, which
///     compares the input-token balance of every known address before and after it; an escrow release must move
///     exactly the escrowed amount to exactly the recorded filler (or to the user, for a refund), nothing else may
///     move, and attack actions (forged reports and proofs, double fills) must never change an escrow.
///   - `optimize_*`: counters of the interesting paths (challenges, finalizations, proofs, refunds, deliveries,
///     voided claims). They are off in medusa.json; `medusa fuzz --config medusa.reach.json` turns optimization mode
///     on (without shrinking, which would take longer than the campaign) and reports their maxima, which measures
///     how far the campaign reaches.
contract IntentMedusaHarness {
    Vm internal constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 internal constant ORIGIN = 1001;
    uint256 internal constant DEST = 1002;
    uint256 internal constant BOND = 50e18;
    uint256 internal constant GRACE = 1 hours;
    uint256 internal constant WINDOW = 30 minutes;
    uint256 internal constant MAX_ORDERS = 10;
    uint256 internal constant MAX_CLAIMS = 20;

    OriginSettler internal origin;
    DestinationSettler internal dest;
    MockMailbox internal originMailbox;
    MockMailbox internal destMailbox;
    MailboxFillReporter internal reporter;
    MailboxSettlementModule internal mailboxModule;
    OptimisticSettlementModule internal optimistic;
    StorageProofSettlementModule internal proofModule;
    HeaderStore internal headers;
    MockERC20 internal inputToken;
    MockERC20 internal outputToken;
    MockERC20 internal bondToken;

    address internal constant USER = address(0xA11CE);
    address internal constant RECIPIENT = address(0xBEEF);
    address internal constant ATTACKER = address(0xBAD);
    address internal constant WATCHER = address(0x3A7C8);
    address[3] internal solvers = [address(0x501), address(0x502), address(0x503)];
    address[3] internal repayTo = [address(0x601), address(0x602), address(0x603)];

    struct Order {
        bytes32 id;
        bytes originData;
        address module;
        uint256 inputAmount;
        uint256 outputEnd;
        uint32 fillDeadline;
    }

    struct ClaimRef {
        bytes32 orderId;
        address filler;
        uint64 filledAt;
    }

    Order[] internal orders;
    bytes32[] internal orderIds;
    ClaimRef[] internal claims;
    address[] internal known;
    uint256 internal destBlock = 1_000;
    /// @dev Harness clock: Medusa gives every transaction a fresh block, so a `warp` does not outlive its
    ///      transaction. Every action re-applies this clock first, and only `advance` moves it forward.
    uint256 internal clock = 1_750_000_000;

    mapping(bytes32 => address) internal repaidTo;
    mapping(bytes32 => uint256) internal repaidAmount;
    mapping(bytes32 => address) internal refundedTo;
    mapping(bytes32 => uint256) internal delivered;
    mapping(bytes32 => uint256) internal firstRecord;
    mapping(bytes32 => bool) internal honestlyClaimed;
    uint256 internal escrowedSum;
    uint256 internal repaidSum;
    uint256 internal refundedSum;
    uint256 internal violations;

    // reachability counters (optimize_*)
    uint256 internal challenges;
    uint256 internal finalizations;
    uint256 internal voided;
    uint256 internal proofs;
    uint256 internal refunds;
    uint256 internal deliveries;

    // `observed` scratch state
    uint256[] internal balancesBefore;
    uint8[] internal statusBefore;
    uint256 internal originBefore;
    uint256 internal ordersBefore;

    constructor() {
        VM.warp(clock);
        VM.chainId(DEST);
        AccessManager destManager = new AccessManager(address(this));
        dest = new DestinationSettler();
        destMailbox = new MockMailbox(address(destManager));
        reporter = new MailboxFillReporter(dest, IMailbox(address(destMailbox)), address(destManager));
        outputToken = new MockERC20("Output", "OUT");

        VM.chainId(ORIGIN);
        AccessManager originManager = new AccessManager(address(this));
        origin = new OriginSettler(ISignatureTransfer(address(0xFEED)), GRACE, address(originManager));
        originMailbox = new MockMailbox(address(originManager));
        mailboxModule = new MailboxSettlementModule(
            IEscrowSettler(address(origin)), address(originMailbox), address(originManager)
        );
        headers = new HeaderStore(address(originManager));
        bondToken = new MockERC20("Bond", "BOND");
        optimistic = new OptimisticSettlementModule(
            IEscrowSettler(address(origin)), headers, bondToken, BOND, WINDOW, address(originManager)
        );
        proofModule = new StorageProofSettlementModule(IEscrowSettler(address(origin)), headers, address(originManager));
        inputToken = new MockERC20("Input", "IN");

        // The harness is the admin and plays both relayers.
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = HeaderStore.submitHeader.selector;
        originManager.setTargetFunctionRole(address(headers), selectors, 1);
        originManager.grantRole(1, address(this), 0);
        selectors[0] = MockMailbox.process.selector;
        originManager.setTargetFunctionRole(address(originMailbox), selectors, 2);
        originManager.grantRole(2, address(this), 0);
        mailboxModule.setRoute(DEST, address(reporter), address(dest));
        optimistic.setDestinationSettler(DEST, address(dest));
        proofModule.setDestinationSettler(DEST, address(dest));
        origin.setSettlementModule(address(mailboxModule), true);
        origin.setSettlementModule(address(optimistic), true);
        origin.setSettlementModule(address(proofModule), true);
        VM.chainId(DEST);
        reporter.setOriginModule(ORIGIN, address(mailboxModule));

        VM.prank(USER);
        inputToken.approve(address(origin), type(uint256).max);
        VM.prank(USER);
        bondToken.approve(address(optimistic), type(uint256).max);
        for (uint256 i = 0; i < 3; ++i) {
            VM.prank(solvers[i]);
            outputToken.approve(address(dest), type(uint256).max);
            VM.prank(solvers[i]);
            bondToken.approve(address(optimistic), type(uint256).max);
            known.push(solvers[i]);
            known.push(repayTo[i]);
        }
        VM.prank(ATTACKER);
        bondToken.approve(address(optimistic), type(uint256).max);
        known.push(USER);
        known.push(RECIPIENT);
        known.push(ATTACKER);
        known.push(WATCHER);
        known.push(address(this));
        known.push(address(dest));
        known.push(address(originMailbox));
        known.push(address(destMailbox));
        known.push(address(reporter));
        known.push(address(mailboxModule));
        known.push(address(optimistic));
        known.push(address(proofModule));
        known.push(address(headers));
        known.push(address(0x10000));
        known.push(address(0x20000));
        known.push(address(0x30000));
    }

    // ------------------------------------------------------------------------------------------------------------
    // Observation (assertion mode)
    // ------------------------------------------------------------------------------------------------------------

    modifier synced() {
        VM.warp(clock);
        _;
    }

    /// @dev Snapshots, runs the action, and asserts that every token movement is explained by one escrow release
    ///      to the right party (see the contract comment).
    modifier observed() {
        _snapshot();
        _;
        _attributeAndAssert();
    }

    function _snapshot() internal {
        delete balancesBefore;
        for (uint256 i = 0; i < known.length; ++i) {
            balancesBefore.push(inputToken.balanceOf(known[i]));
        }
        delete statusBefore;
        for (uint256 i = 0; i < orders.length; ++i) {
            statusBefore.push(uint8(origin.escrowOf(orders[i].id).status));
        }
        originBefore = inputToken.balanceOf(address(origin));
        ordersBefore = orders.length;
    }

    function _attributeAndAssert() internal {
        uint256 opened = 0;
        for (uint256 i = ordersBefore; i < orders.length; ++i) {
            opened += orders[i].inputAmount;
        }
        uint256 released = 0;
        uint256 closedIndex = type(uint256).max;
        for (uint256 i = 0; i < ordersBefore; ++i) {
            if (uint8(origin.escrowOf(orders[i].id).status) == statusBefore[i]) continue;
            assert(closedIndex == type(uint256).max); // at most one escrow closes per action
            assert(statusBefore[i] == uint8(OrderStatus.Open)); // Repaid and Refunded are terminal
            closedIndex = i;
            released = orders[i].inputAmount;
        }
        assert(inputToken.balanceOf(address(origin)) + released == originBefore + opened);

        address payee = address(0);
        for (uint256 i = 0; i < known.length; ++i) {
            uint256 nowBalance = inputToken.balanceOf(known[i]);
            if (nowBalance == balancesBefore[i]) continue;
            // Exactly one known address gained exactly the released amount; nothing else moved.
            assert(payee == address(0) && released != 0 && nowBalance == balancesBefore[i] + released);
            payee = known[i];
        }
        if (closedIndex == type(uint256).max) return;
        assert(payee != address(0)); // the escrow did not leave to an address outside the system
        bytes32 id = orders[closedIndex].id;
        OrderStatus status = origin.escrowOf(id).status;
        if (status == OrderStatus.Repaid) {
            address recorded = dest.fillRecord(id).filler;
            assert(recorded != address(0) && payee == recorded); // INV-1, observed
            if (repaidTo[id] != address(0)) violations++;
            repaidTo[id] = payee;
            repaidAmount[id] = released;
            repaidSum += released;
        } else {
            assert(status == OrderStatus.Refunded && payee == USER); // INV-2, observed
            refundedTo[id] = payee;
            refundedSum += released;
            ++refunds;
        }
    }

    /// @dev For attack actions: no escrow may change at all.
    function _assertNoEscrowChanged() internal view {
        for (uint256 i = 0; i < ordersBefore; ++i) {
            assert(uint8(origin.escrowOf(orders[i].id).status) == statusBefore[i]);
        }
    }

    // ------------------------------------------------------------------------------------------------------------
    // Actions
    // ------------------------------------------------------------------------------------------------------------

    function open(uint8 moduleSeed, uint96 amountSeed, uint16 window) public synced observed {
        if (orders.length >= MAX_ORDERS) return;
        VM.chainId(ORIGIN);
        address module = moduleSeed % 3 == 0
            ? address(mailboxModule)
            : moduleSeed % 3 == 1 ? address(optimistic) : address(proofModule);
        uint256 amount = 1e6 + uint256(amountSeed) % 1e24;
        uint32 fillDeadline = uint32(block.timestamp + 60 + uint256(window) % 3600);
        IntentOrderData memory data = IntentOrderData({
            inputToken: address(inputToken),
            inputAmount: amount,
            outputToken: address(outputToken),
            outputStartAmount: amount * 99 / 100,
            outputEndAmount: amount * 97 / 100,
            recipient: RECIPIENT,
            destinationChainId: DEST,
            destinationSettler: address(dest),
            exclusiveFiller: address(0),
            exclusivityDeadline: uint32(block.timestamp + 30),
            settlementModule: module
        });
        inputToken.mint(USER, amount);
        uint256 nonce = origin.onchainNonce(USER);
        VM.prank(USER);
        origin.open(OnchainCrossChainOrder(fillDeadline, IntentLib.INTENT_ORDER_DATA_TYPEHASH, abi.encode(data)));
        bytes memory originData =
            abi.encode(Intent(address(origin), USER, nonce, ORIGIN, type(uint32).max, fillDeadline, data));
        bytes32 id = IntentLib.orderId(ORIGIN, address(origin), keccak256(originData));
        orders.push(Order(id, originData, module, amount, data.outputEndAmount, fillDeadline));
        orderIds.push(id);
        escrowedSum += amount;
    }

    function fill(uint8 idx, uint8 solverSeed) public synced observed {
        (bool found, Order memory o) = _find(idx, 0);
        if (!found) return;
        VM.chainId(DEST);
        uint256 s = solverSeed % 3;
        uint256 amount = dest.outputAt(o.originData, block.timestamp);
        outputToken.mint(solvers[s], amount);
        uint256 before = outputToken.balanceOf(RECIPIENT);
        VM.prank(solvers[s]);
        dest.fill(o.id, o.originData, abi.encode(repayTo[s]));
        delivered[o.id] = outputToken.balanceOf(RECIPIENT) - before;
        firstRecord[o.id] = uint256(VM.load(address(dest), FillProofLib.fillerSlot(o.id)));
        assert(delivered[o.id] >= o.outputEnd); // INV-4 at the moment of the fill
    }

    function doubleFill(uint8 idx) public synced observed {
        if (orders.length == 0) return;
        Order memory o = orders[idx % orders.length];
        VM.chainId(DEST);
        if (dest.fillRecord(o.id).filler == address(0) && block.timestamp <= o.fillDeadline) return;
        outputToken.mint(ATTACKER, o.inputAmount);
        VM.prank(ATTACKER);
        outputToken.approve(address(dest), type(uint256).max);
        uint256 recordBefore = uint256(VM.load(address(dest), FillProofLib.fillerSlot(o.id)));
        VM.prank(ATTACKER);
        try dest.fill(o.id, o.originData, "") {
            violations++;
            assert(false);
        } catch {}
        assert(uint256(VM.load(address(dest), FillProofLib.fillerSlot(o.id))) == recordBefore);
        _assertNoEscrowChanged();
    }

    function reportAndRelay(uint8 idx) public synced observed {
        (bool found, Order memory o) = _find(idx, 1);
        if (!found) return;
        VM.chainId(DEST);
        DestinationSettler.FillRecord memory record = dest.fillRecord(o.id);
        bytes memory message =
            _nextMessage(address(reporter), abi.encode(o.id, record.filler, record.fillHash, record.filledAt));
        reporter.report(o.id, ORIGIN);
        VM.chainId(ORIGIN);
        originMailbox.process(message); // the order is open (see _find), so the delivery must settle
        ++deliveries;
        assert(origin.escrowOf(o.id).status == OrderStatus.Repaid);
    }

    function forgeReport(uint8 idx, address filler) public synced observed {
        if (orders.length == 0) return;
        Order memory o = orders[idx % orders.length];
        VM.chainId(DEST);
        bytes memory body = abi.encode(o.id, filler, keccak256(o.originData), uint64(block.timestamp));
        bytes memory message = _nextMessage(ATTACKER, body);
        VM.prank(ATTACKER);
        IMailbox(address(destMailbox)).dispatch(ORIGIN, address(mailboxModule), body);
        VM.chainId(ORIGIN);
        try originMailbox.process(message) {
            violations++;
            assert(false);
        } catch {}
        _assertNoEscrowChanged();
    }

    function claimHonest(uint8 idx) public synced observed {
        (bool found, Order memory o) = _find(idx, 2);
        if (!found) return;
        VM.chainId(DEST);
        DestinationSettler.FillRecord memory record = dest.fillRecord(o.id);
        VM.chainId(ORIGIN);
        bondToken.mint(solvers[0], BOND);
        VM.prank(solvers[0]);
        optimistic.claim(o.id, record.filler, record.filledAt, keccak256(o.originData));
        claims.push(ClaimRef(o.id, record.filler, record.filledAt));
        honestlyClaimed[o.id] = true;
    }

    /// @dev A false claim by the attacker, or by the order's user squatting its own order (who then tries to refund).
    function claimFraud(uint8 idx, uint8 kind, uint32 back) public synced observed {
        (bool found, Order memory o) = _find(idx, 3);
        if (!found || claims.length >= MAX_CLAIMS) return;
        VM.chainId(DEST);
        DestinationSettler.FillRecord memory record = dest.fillRecord(o.id);
        VM.chainId(ORIGIN);
        uint256 latest = block.timestamp < o.fillDeadline ? block.timestamp : o.fillDeadline;
        address claimant = kind % 3 == 2 ? USER : ATTACKER;
        address filler = claimant;
        uint64 filledAt = uint64(latest - uint256(back) % (latest + 1));
        if (kind % 3 == 1 && record.filler != address(0)) {
            filler = record.filler;
            filledAt = record.filledAt == latest ? record.filledAt - 1 : uint64(latest);
        }
        if (optimistic.claimOf(o.id, filler, filledAt).claimant != address(0)) return;
        bondToken.mint(claimant, BOND);
        VM.prank(claimant);
        optimistic.claim(o.id, filler, filledAt, keccak256(o.originData));
        claims.push(ClaimRef(o.id, filler, filledAt));
        if (claimant == USER) {
            VM.prank(USER);
            try origin.refund(o.id) {
                assert(false); // a pending claim always blocks the refund
            } catch {}
        }
    }

    function finalize(uint8 seed) public synced observed {
        uint256 n = claims.length;
        if (n == 0) return;
        VM.chainId(ORIGIN);
        for (uint256 k = 0; k < n; ++k) {
            uint256 i = (uint256(seed) % n + k) % n;
            ClaimRef memory c = claims[i];
            OptimisticSettlementModule.Claim memory pending = optimistic.claimOf(c.orderId, c.filler, c.filledAt);
            if (block.timestamp <= pending.challengeDeadline) continue;
            bool wasOpen = origin.escrowOf(c.orderId).status == OrderStatus.Open;
            optimistic.finalize(c.orderId, c.filler, c.filledAt);
            if (wasOpen) ++finalizations;
            else ++voided;
            claims[i] = claims[claims.length - 1];
            claims.pop();
            return;
        }
    }

    function prove(uint8 idx) public synced observed {
        (bool found, Order memory o) = _find(idx, 5);
        if (!found) return;
        (uint256 blockNumber, DestStateProofs.Snapshot memory snap) = _relay(o.id);
        proofModule.proveFill(o.id, blockNumber, keccak256(o.originData), snap.accountProof, snap.slotProof);
        ++proofs;
        assert(origin.escrowOf(o.id).status == OrderStatus.Repaid);
    }

    function forgeProof(uint8 idx, uint8 otherIdx) public synced observed {
        if (orders.length < 2) return;
        Order memory o = orders[idx % orders.length];
        Order memory other = orders[otherIdx % orders.length];
        VM.chainId(DEST);
        if (o.module != address(proofModule) || other.id == o.id || dest.fillRecord(o.id).filler != address(0)) return;
        (uint256 blockNumber, DestStateProofs.Snapshot memory snap) = _relay(other.id);
        VM.prank(ATTACKER);
        try proofModule.proveFill(o.id, blockNumber, keccak256(o.originData), snap.accountProof, snap.slotProof) {
            violations++;
            assert(false);
        } catch {}
        _assertNoEscrowChanged();
    }

    function refund(uint8 idx) public synced observed {
        (bool found, Order memory o) = _find(idx, 6);
        if (!found) return;
        VM.chainId(ORIGIN);
        bool blocked = optimistic.hasPendingClaim(o.id);
        try origin.refund(o.id) {
            assert(!blocked);
        } catch {}
    }

    function advance(uint16 dt) public synced observed {
        _watch();
        clock = block.timestamp + 1 + uint256(dt) % 4000;
        VM.warp(clock);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Properties
    // ------------------------------------------------------------------------------------------------------------

    /// @notice INV-1 solver repaid implies user filled, by that filler, for the escrowed amount (observed payee).
    function property_solverRepaidImpliesUserFilled() public view returns (bool) {
        for (uint256 i = 0; i < orders.length; ++i) {
            bytes32 id = orders[i].id;
            if (origin.escrowOf(id).status != OrderStatus.Repaid) continue;
            address recorded = dest.fillRecord(id).filler;
            if (recorded == address(0) || repaidTo[id] != recorded || repaidAmount[id] != orders[i].inputAmount) {
                return false;
            }
        }
        return true;
    }

    /// @notice INV-2 refunded implies solver not repaid (and vice versa); refunds went to the user.
    function property_refundedImpliesNotRepaid() public view returns (bool) {
        for (uint256 i = 0; i < orders.length; ++i) {
            bytes32 id = orders[i].id;
            OrderStatus status = origin.escrowOf(id).status;
            if (status == OrderStatus.Refunded && (repaidTo[id] != address(0) || refundedTo[id] != USER)) return false;
            if (status == OrderStatus.Repaid && refundedTo[id] != address(0)) return false;
        }
        return true;
    }

    /// @notice INV-3 escrowed == outstanding + repaid + refunded, and the escrow holds exactly the outstanding sum.
    function property_escrowConservation() public view returns (bool) {
        uint256 outstanding = 0;
        for (uint256 i = 0; i < orders.length; ++i) {
            if (origin.escrowOf(orders[i].id).status == OrderStatus.Open) outstanding += orders[i].inputAmount;
        }
        return
            inputToken.balanceOf(address(origin)) == outstanding && escrowedSum == outstanding + repaidSum + refundedSum;
    }

    /// @notice INV-4 every fill paid the recipient at least the floor.
    function property_userReceivesAtLeastFloor() public view returns (bool) {
        for (uint256 i = 0; i < orders.length; ++i) {
            if (firstRecord[orders[i].id] != 0 && delivered[orders[i].id] < orders[i].outputEnd) return false;
        }
        return true;
    }

    /// @notice INV-5 fill records are write-once.
    function property_fillRecordsAreWriteOnce() public view returns (bool) {
        for (uint256 i = 0; i < orders.length; ++i) {
            bytes32 id = orders[i].id;
            if (uint256(VM.load(address(dest), FillProofLib.fillerSlot(id))) != firstRecord[id]) return false;
        }
        return true;
    }

    /// @notice INV-6 one bond per pending claim, whatever the number of claims per order.
    function property_bondsAreBacked() public view returns (bool) {
        uint256 pending = 0;
        for (uint256 i = 0; i < orders.length; ++i) {
            pending += optimistic.pendingClaims(orders[i].id);
        }
        return bondToken.balanceOf(address(optimistic)) == pending * BOND && pending == claims.length;
    }

    /// @notice INV-7 no attack succeeded.
    function property_noAttackSucceeded() public view returns (bool) {
        return violations == 0;
    }

    /// @notice INV-8 an order whose real fill was claimed is never refunded, whatever false claims surround it.
    function property_honestClaimIsNeverRefunded() public view returns (bool) {
        for (uint256 i = 0; i < orders.length; ++i) {
            bytes32 id = orders[i].id;
            if (honestlyClaimed[id] && origin.escrowOf(id).status == OrderStatus.Refunded) return false;
        }
        return true;
    }

    // ------------------------------------------------------------------------------------------------------------
    // Reachability (optimization mode reports the maximum of each)
    // ------------------------------------------------------------------------------------------------------------

    /// @notice Successful fraud-proof challenges by the watcher.
    function optimize_challenges() public view returns (int256) {
        return int256(challenges);
    }

    /// @notice Optimistic claims that finalized and repaid.
    function optimize_finalizations() public view returns (int256) {
        return int256(finalizations);
    }

    /// @notice Optimistic claims voided because another claim had already repaid the order.
    function optimize_voidedClaims() public view returns (int256) {
        return int256(voided);
    }

    /// @notice Storage-proof repayments.
    function optimize_proofs() public view returns (int256) {
        return int256(proofs);
    }

    /// @notice Refunds.
    function optimize_refunds() public view returns (int256) {
        return int256(refunds);
    }

    /// @notice Mailbox deliveries that repaid.
    function optimize_deliveries() public view returns (int256) {
        return int256(deliveries);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------------------------------------------------

    /// @dev kinds: 0 fillable, 1 reportable, 2 honestly claimable, 3 claimable, 5 provable, 6 refundable
    function _find(uint8 idx, uint8 kind) internal returns (bool, Order memory o) {
        uint256 n = orders.length;
        for (uint256 k = 0; k < n; ++k) {
            o = orders[(uint256(idx) % n + k) % n];
            if (_matches(o, kind)) return (true, o);
        }
        return (false, o);
    }

    function _matches(Order memory o, uint8 kind) internal returns (bool) {
        VM.chainId(DEST);
        DestinationSettler.FillRecord memory record = dest.fillRecord(o.id);
        bool filled = record.filler != address(0);
        VM.chainId(ORIGIN);
        bool isOpen = origin.escrowOf(o.id).status == OrderStatus.Open;
        if (kind == 0) return !filled && block.timestamp <= o.fillDeadline;
        if (kind == 1) return filled && isOpen && o.module == address(mailboxModule);
        if (kind == 5) return filled && isOpen && o.module == address(proofModule);
        if (kind == 6) return isOpen && block.timestamp > uint256(o.fillDeadline) + GRACE;
        bool claimable = o.module == address(optimistic) && isOpen;
        if (kind == 2) {
            return claimable && filled && claims.length < MAX_CLAIMS
                && optimistic.claimOf(o.id, record.filler, record.filledAt).claimant == address(0);
        }
        return claimable;
    }

    function _watch() internal {
        uint256 i = 0;
        while (i < claims.length) {
            ClaimRef memory c = claims[i];
            VM.chainId(ORIGIN);
            uint256 actual = uint256(VM.load(address(dest), FillProofLib.fillerSlot(c.orderId)));
            if (actual == FillProofLib.pack(c.filler, c.filledAt)) {
                ++i;
                continue;
            }
            if (block.timestamp <= c.filledAt) {
                clock = uint256(c.filledAt) + 1;
                VM.warp(clock);
            }
            (uint256 blockNumber, DestStateProofs.Snapshot memory snap) = _relay(c.orderId);
            VM.prank(WATCHER);
            optimistic.challenge(c.orderId, c.filler, c.filledAt, blockNumber, snap.accountProof, snap.slotProof);
            ++challenges;
            claims[i] = claims[claims.length - 1];
            claims.pop();
        }
    }

    function _relay(bytes32 target) internal returns (uint256 blockNumber, DestStateProofs.Snapshot memory snap) {
        blockNumber = ++destBlock;
        snap = DestStateProofs.snapshot(address(dest), orderIds, target, blockNumber, block.timestamp);
        VM.chainId(ORIGIN);
        headers.submitHeader(DEST, snap.header);
    }

    /// @dev The message the destination mailbox will emit for the next dispatch from `sender`.
    function _nextMessage(address sender, bytes memory body) internal view returns (bytes memory) {
        return abi.encode(
            MockMailbox.Message({
                nonce: destMailbox.outboundNonce(),
                originDomain: DEST,
                sender: sender,
                destinationDomain: ORIGIN,
                recipient: address(mailboxModule),
                body: body
            })
        );
    }
}
