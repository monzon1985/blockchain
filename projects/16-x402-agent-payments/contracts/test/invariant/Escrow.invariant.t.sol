// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {PaymentEscrow} from "../../src/escrow/PaymentEscrow.sol";
import {ResourceBinding} from "../../src/settlement/ResourceBinding.sol";
import {TestUSD} from "../../src/token/TestUSD.sol";
import {Fixture} from "../utils/Fixture.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

/// @notice Opens, delivers and refunds escrows at random times; mirrors every state change in a ghost model.
contract EscrowHandler is CommonBase, StdCheats, StdUtils {
    bytes32 internal constant RECEIVE_TYPEHASH = keccak256(
        "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );

    PaymentEscrow internal immutable ESCROW;
    TestUSD internal immutable TOKEN;
    address internal immutable PAYEE;
    uint256[2] internal payerKeys;

    bytes32[] public ids;
    mapping(bytes32 id => uint8 status) public ghostStatus; // 1 open, 2 released, 3 refunded
    mapping(bytes32 id => uint256 amount) public ghostAmount;
    uint256 public ghostOpenTotal;
    uint256 public ghostReleasedTotal;
    uint256 public ghostReleasedCount;
    uint256 public violations;
    uint256 internal saltCounter;

    constructor(PaymentEscrow escrow, TestUSD token, address payee, uint256[2] memory keys) {
        ESCROW = escrow;
        TOKEN = token;
        PAYEE = payee;
        payerKeys = keys;
    }

    function idCount() external view returns (uint256) {
        return ids.length;
    }

    function open(uint256 amountSeed, uint256 payerSeed, uint256 windowSeed) external {
        uint256 key = payerKeys[payerSeed % 2];
        address from = vm.addr(key);
        uint256 amount = bound(amountSeed, 1, 5e6);
        uint64 deadline = uint64(block.timestamp + bound(windowSeed, 1, 2 hours));
        bytes32 salt = keccak256(abi.encode(++saltCounter));
        PaymentEscrow.OpenRequest memory r = PaymentEscrow.OpenRequest({
            from: from,
            value: amount,
            validAfter: block.timestamp - 1,
            validBefore: block.timestamp + 60,
            nonce: ResourceBinding.escrowNonce(PAYEE, keccak256("job"), deadline, salt),
            payee: PAYEE,
            resourceHash: keccak256("job"),
            deliveryDeadline: deadline,
            salt: salt
        });
        bytes32 digest = MessageHashUtils.toTypedDataHash(
            TOKEN.DOMAIN_SEPARATOR(),
            keccak256(abi.encode(RECEIVE_TYPEHASH, from, address(ESCROW), amount, r.validAfter, r.validBefore, r.nonce))
        );
        (uint8 v, bytes32 rr, bytes32 s) = vm.sign(key, digest);
        try ESCROW.open(r, abi.encodePacked(rr, s, v)) returns (bytes32 id) {
            ids.push(id);
            ghostStatus[id] = 1;
            ghostAmount[id] = amount;
            ghostOpenTotal += amount;
        } catch {}
    }

    function deliver(uint256 idSeed) external {
        if (ids.length == 0) return;
        bytes32 id = ids[idSeed % ids.length];
        PaymentEscrow.Escrow memory e = ESCROW.escrowOf(id);
        bool shouldSucceed = ghostStatus[id] == 1 && block.timestamp <= e.deadline;
        vm.prank(PAYEE);
        try ESCROW.deliver(id, keccak256(abi.encode("result", id))) {
            if (!shouldSucceed) ++violations;
            ghostStatus[id] = 2;
            ghostOpenTotal -= ghostAmount[id];
            ghostReleasedTotal += ghostAmount[id];
            ++ghostReleasedCount;
        } catch {
            if (shouldSucceed) ++violations;
        }
    }

    function refund(uint256 idSeed) external {
        if (ids.length == 0) return;
        bytes32 id = ids[idSeed % ids.length];
        PaymentEscrow.Escrow memory e = ESCROW.escrowOf(id);
        bool shouldSucceed = ghostStatus[id] == 1 && block.timestamp > e.deadline;
        try ESCROW.refund(id) {
            if (!shouldSucceed) ++violations;
            ghostStatus[id] = 3;
            ghostOpenTotal -= ghostAmount[id];
        } catch {
            if (shouldSucceed) ++violations;
        }
    }

    function strangerDeliver(uint256 idSeed) external {
        if (ids.length == 0) return;
        bytes32 id = ids[idSeed % ids.length];
        vm.prank(address(0xBAD));
        try ESCROW.deliver(id, keccak256("forged")) {
            ++violations;
        } catch {}
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 0, 90 minutes));
    }
}

/// @notice Stateful invariants of the escrow. See README "Invariants" I6-I8.
contract EscrowInvariantTest is Fixture {
    EscrowHandler internal handler;
    address internal payerB;
    uint256 internal payerBKey;
    uint256 internal constant FUNDING = 1_000_000e6;

    function setUp() public override {
        super.setUp();
        (payerB, payerBKey) = makeAddrAndKey("payerB");
        _mint(payer, FUNDING);
        _mint(payerB, FUNDING);
        handler = new EscrowHandler(escrow, token, payee, [payerKey, payerBKey]);
        targetContract(address(handler));
    }

    /// @notice I6: the escrow holds exactly the sum of open escrows, and its own counter agrees.
    function invariant_EscrowBalanceEqualsOpenEscrows() public view {
        assertEq(token.balanceOf(address(escrow)), handler.ghostOpenTotal());
        assertEq(escrow.totalEscrowed(), handler.ghostOpenTotal());
    }

    /// @notice I7: value is conserved between payers, payee and escrow; the payee received exactly the released
    ///         escrows, and each release produced exactly one receipt.
    function invariant_ConservationAndReceipts() public view {
        assertEq(
            token.balanceOf(payer) + token.balanceOf(payerB) + token.balanceOf(payee)
                + token.balanceOf(address(escrow)),
            2 * FUNDING
        );
        assertEq(token.balanceOf(payee), handler.ghostReleasedTotal());
        assertEq(settlement.receiptCount(), handler.ghostReleasedCount());
    }

    /// @notice I8: on-chain status matches the ghost model (terminal states are final, never both), and delivery
    ///         and refund succeed exactly when their time conditions hold.
    function invariant_StatusMatchesModel() public view {
        uint256 n = handler.idCount();
        for (uint256 i = 0; i < n; ++i) {
            bytes32 id = handler.ids(i);
            assertEq(uint8(escrow.escrowOf(id).status), handler.ghostStatus(id));
        }
        assertEq(handler.violations(), 0);
    }
}
