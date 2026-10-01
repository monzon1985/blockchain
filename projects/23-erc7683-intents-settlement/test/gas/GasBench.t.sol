// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {AccessManager} from "@openzeppelin-contracts/access/manager/AccessManager.sol";

import {GaslessCrossChainOrder} from "../../src/erc7683/IERC7683.sol";
import {HeaderStore} from "../../src/settlement/proof/HeaderStore.sol";
import {AnvilFixture, ProofHarness} from "../utils/AnvilFixture.sol";
import {IntentTestBase} from "../utils/IntentTestBase.sol";

// Gas benchmarks. Each measured call is the only call of its test, and every piece of state it touches is created in
// setUp (a separate transaction), so storage is cold exactly as for a first call in production. Numbers are the
// execution gas of the call frame as recorded by vm.snapshotGasLastFrame into snapshots/GasBench.json (no 21k
// intrinsic cost, no calldata cost); .gas-snapshot tracks whole-test gas for `forge snapshot --check`.

string constant GROUP = "GasBench";

/// @notice Opening an order: plain approve + open, and gasless through the Permit2 witness.
contract GasBenchOpen is IntentTestBase {
    OrderParams internal p;
    GaslessCrossChainOrder internal order;
    bytes internal signature;

    function setUp() public override {
        super.setUp();
        vm.chainId(ORIGIN);
        p = _params(address(mailboxModule));
        inputToken.mint(user, 2 * p.inputAmount);
        vm.startPrank(user);
        inputToken.approve(address(origin), type(uint256).max);
        inputToken.approve(PERMIT2_ADDRESS, type(uint256).max);
        vm.stopPrank();
        order = _gaslessOrder(p, 1);
        signature = _sign(order, userKey);
    }

    function test_gas_open_onchain() public {
        vm.prank(user);
        origin.open(_onchainOrder(p));
        vm.snapshotGasLastFrame(GROUP, "open (on-chain order, ERC-20 approval)");
    }

    function test_gas_openFor_permit2Witness() public {
        vm.prank(solver);
        origin.openFor(order, signature, "");
        vm.snapshotGasLastFrame(GROUP, "openFor (gasless, Permit2 witness transfer)");
    }
}

/// @notice Filling on the destination chain.
contract GasBenchFill is IntentTestBase {
    OrderParams internal p;
    bytes32 internal orderId;
    bytes internal originData;

    function setUp() public override {
        super.setUp();
        p = _params(address(mailboxModule));
        (orderId, originData) = _ids(_onchainIntent(p, user, 0));
        vm.chainId(DEST);
        outputToken.mint(solver, p.outputStart);
        outputToken.mint(recipient, 1); // recipient already holds the token, as is typical
        vm.prank(solver);
        outputToken.approve(address(dest), type(uint256).max);
    }

    function test_gas_fill_atStartAmount() public {
        vm.prank(solver);
        dest.fill(orderId, originData, abi.encode(solverRepayment));
        vm.snapshotGasLastFrame(GROUP, "fill (start amount, fillerData)");
    }

    function test_gas_fill_duringDecay() public {
        vm.warp((uint256(p.exclusivityDeadline) + p.fillDeadline) / 2);
        vm.prank(solver);
        dest.fillWithRepayment(orderId, originData, solverRepayment);
        vm.snapshotGasLastFrame(GROUP, "fillWithRepayment (during Dutch decay)");
    }
}

/// @notice Mode 1: report on the destination, delivery (which settles) on the origin.
contract GasBenchMailbox is IntentTestBase {
    bytes32 internal orderId;
    bytes internal message;

    function setUp() public override {
        super.setUp();
        bytes memory originData;
        (orderId, originData) = _openOnchain(_params(address(mailboxModule)));
        _fill(orderId, originData, solver, solverRepayment);
        vm.chainId(DEST);
        vm.recordLogs();
        reporter.report(orderId, ORIGIN); // steady state: the mailbox nonce is already non-zero
        message = _lastDispatch();
    }

    function test_gas_mailbox_report() public {
        vm.chainId(DEST);
        reporter.report(orderId, ORIGIN);
        vm.snapshotGasLastFrame(GROUP, "mode 1: report (destination)");
    }

    function test_gas_mailbox_deliverAndSettle() public {
        vm.chainId(ORIGIN);
        vm.prank(mailboxRelayer);
        originMailbox.process(message);
        vm.snapshotGasLastFrame(GROUP, "mode 1: mailbox delivery + settle (origin)");
    }
}

/// @notice Mode 2 happy path: bonded claim, then finalize.
contract GasBenchOptimisticClaim is IntentTestBase {
    bytes32 internal orderId;
    bytes internal originData;

    function setUp() public override {
        super.setUp();
        (orderId, originData) = _openOnchain(_params(address(optimistic)));
        _fill(orderId, originData, solver, solverRepayment);
        vm.chainId(ORIGIN);
        bondToken.mint(solver, BOND);
        vm.prank(solver);
        bondToken.approve(address(optimistic), BOND);
    }

    function test_gas_optimistic_claim() public {
        vm.prank(solver);
        optimistic.claim(orderId, solverRepayment, uint64(block.timestamp), keccak256(originData));
        vm.snapshotGasLastFrame(GROUP, "mode 2: claim with bond (origin)");
    }
}

contract GasBenchOptimisticFinalize is IntentTestBase {
    bytes32 internal orderId;
    uint64 internal filledAt;

    function setUp() public override {
        super.setUp();
        bytes memory originData;
        (orderId, originData) = _openOnchain(_params(address(optimistic)));
        _fill(orderId, originData, solver, solverRepayment);
        filledAt = uint64(block.timestamp);
        vm.chainId(ORIGIN);
        bondToken.mint(solver, BOND);
        vm.startPrank(solver);
        bondToken.approve(address(optimistic), BOND);
        optimistic.claim(orderId, solverRepayment, filledAt, keccak256(originData));
        vm.stopPrank();
        vm.warp(block.timestamp + CHALLENGE_WINDOW + 1);
    }

    function test_gas_optimistic_finalize() public {
        optimistic.finalize(orderId, solverRepayment, filledAt);
        vm.snapshotGasLastFrame(GROUP, "mode 2: finalize + settle + bond refund (origin)");
    }
}

/// @notice Refund of an unfilled order.
contract GasBenchRefund is IntentTestBase {
    bytes32 internal orderId;

    function setUp() public override {
        super.setUp();
        OrderParams memory p = _params(address(mailboxModule));
        (orderId,) = _openOnchain(p);
        vm.warp(uint256(p.fillDeadline) + REFUND_GRACE + 1);
    }

    function test_gas_refund() public {
        origin.refund(orderId);
        vm.snapshotGasLastFrame(GROUP, "refund after fill deadline + grace (origin)");
    }
}

/// @notice Proof-based paths measured on the real anvil proofs of test/fixtures/anvil-proofs.json. Everything is
/// parsed from the fixture in setUp, so the whole-test numbers in .gas-snapshot track the operations, not JSON I/O.
contract GasBenchProofs is AnvilFixture {
    Replay internal r;
    ProofHarness internal harness;

    bytes32 internal filledId;
    bytes32 internal filledFillHash;
    bytes32 internal filledSlot;
    bytes[] internal filledProof;
    bytes32 internal fillHashSlot;
    bytes[] internal fillHashProof;
    bytes32 internal unfilledId;
    bytes[] internal unfilledProof;
    address internal attacker = makeAddr("attacker");
    uint64 internal claimedAt;

    function setUp() public {
        _loadFixture();
        r = _replay();
        bytes memory filledData;
        (filledId, filledData, filledSlot,, filledProof) = _order("filledProof");
        filledFillHash = keccak256(filledData);
        fillHashSlot = vm.parseJsonBytes32(json, ".fillHashSlotOfFilledProof.slot");
        fillHashProof = vm.parseJsonBytesArray(json, ".fillHashSlotOfFilledProof.proof");
        bytes memory unfilledData;
        (unfilledId, unfilledData,,, unfilledProof) = _order("unfilledOptimistic");
        claimedAt = uint64(headerTimestamp - 10);
        _claim(r, attacker, unfilledId, attacker, claimedAt, keccak256(unfilledData));
        harness = new ProofHarness();
    }

    function test_gas_proof_proveFill() public {
        r.proofModule.proveFill(filledId, blockNumber, filledFillHash, accountProof, filledProof);
        vm.snapshotGasLastFrame(GROUP, "mode 3: proveFill (anvil account + storage proof) + settle");
    }

    function test_gas_optimistic_challengeWithExclusionProof() public {
        r.optimistic.challenge(unfilledId, attacker, claimedAt, blockNumber, accountProof, unfilledProof);
        vm.snapshotGasLastFrame(GROUP, "mode 2: challenge with exclusion proof (anvil)");
    }

    /// @dev Baseline for the single-slot design: verifying the account and ONE record slot...
    function test_gas_verify_oneRecordSlot() public {
        harness.verifyRecord(stateRoot, settler, accountProof, filledSlot, filledProof);
        vm.snapshotGasLastFrame(GROUP, "verify account + 1 record slot (what mode 3 does)");
    }

    /// @dev ...versus both record slots (filler|filledAt and fillHash), which the orderId commitment makes unnecessary.
    function test_gas_verify_twoRecordSlots() public {
        harness.verifyRecordAndFillHash(
            stateRoot, settler, accountProof, filledSlot, filledProof, fillHashSlot, fillHashProof
        );
        vm.snapshotGasLastFrame(GROUP, "verify account + 2 record slots (baseline)");
    }
}

/// @notice Storing a relayed destination header (the real anvil header of the fixture).
contract GasBenchHeader is AnvilFixture {
    HeaderStore internal headers;

    function setUp() public {
        _loadFixture();
        vm.chainId(ORIGIN);
        AccessManager manager = new AccessManager(address(this));
        headers = new HeaderStore(address(manager));
    }

    function test_gas_submitHeader() public {
        headers.submitHeader(DEST, headerRlp);
        vm.snapshotGasLastFrame(GROUP, "submitHeader (relayer, anvil header)");
    }
}
