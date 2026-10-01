// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ISettlementLog} from "../../src/interfaces/ISettlementLog.sol";
import {IdentityRegistry} from "../../src/registry/IdentityRegistry.sol";
import {ReputationRegistry} from "../../src/registry/ReputationRegistry.sol";
import {ResourceBinding} from "../../src/settlement/ResourceBinding.sol";
import {SettlementLog} from "../../src/settlement/SettlementLog.sol";
import {TestUSD} from "../../src/token/TestUSD.sol";
import {Fixture} from "../utils/Fixture.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

/// @notice Pays an agent through `exact` settlement and leaves feedback, mixing honest and adversarial actions. The
///         agent owner keeps rotating the payment wallet between two addresses, which must never void a receipt.
contract ReputationHandler is CommonBase, StdCheats, StdUtils {
    bytes32 internal constant TRANSFER_TYPEHASH = keccak256(
        "TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );

    SettlementLog internal immutable LOG;
    ReputationRegistry internal immutable REPUTATION;
    IdentityRegistry internal immutable IDENTITY;
    TestUSD internal immutable TOKEN;
    uint256 internal immutable AGENT_ID;
    address internal immutable AGENT_OWNER;
    uint256[3] internal clientKeys;
    uint256[2] internal walletKeys;
    uint256 internal currentWallet;

    bytes32[] public receipts;
    mapping(bytes32 receiptId => bool) public ghostUsed;
    uint256 public ghostFeedback;
    uint256 public ghostPaid;
    uint256 public violations;
    uint256 public ghostRotations;
    uint256 internal saltCounter;

    constructor(
        SettlementLog log,
        ReputationRegistry reputation,
        TestUSD token,
        uint256 agentId,
        address agentOwner,
        uint256[3] memory keys,
        uint256[2] memory wallets
    ) {
        LOG = log;
        REPUTATION = reputation;
        IDENTITY = reputation.IDENTITY();
        TOKEN = token;
        AGENT_ID = agentId;
        AGENT_OWNER = agentOwner;
        clientKeys = keys;
        walletKeys = wallets;
    }

    function wallet(uint256 i) public view returns (address) {
        return vm.addr(walletKeys[i]);
    }

    /// @notice The owner moves the payment address to the other wallet, one second or more later.
    function rotateWallet(uint256 dtSeed) external {
        vm.warp(block.timestamp + bound(dtSeed, 1, 1 days));
        uint256 next = 1 - currentWallet;
        bytes32 digest = IDENTITY.agentWalletDigest(AGENT_ID, wallet(next), block.timestamp);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(walletKeys[next], digest);
        vm.prank(AGENT_OWNER);
        IDENTITY.setAgentWallet(AGENT_ID, wallet(next), block.timestamp, abi.encodePacked(r, s, v));
        currentWallet = next;
        ++ghostRotations;
    }

    function receiptCount() external view returns (uint256) {
        return receipts.length;
    }

    function client(uint256 i) external view returns (address) {
        return vm.addr(clientKeys[i]);
    }

    function pay(uint256 clientSeed, uint256 amountSeed) external {
        uint256 key = clientKeys[clientSeed % 3];
        uint256 amount = bound(amountSeed, 1, 2e6);
        bytes32 resource = keccak256(abi.encode("resource", clientSeed % 7));
        bytes32 salt = keccak256(abi.encode(++saltCounter));
        SettlementLog.ExactAuthorization memory auth = SettlementLog.ExactAuthorization({
            from: vm.addr(key),
            to: wallet(currentWallet),
            value: amount,
            validAfter: block.timestamp - 1,
            validBefore: block.timestamp + 60,
            nonce: ResourceBinding.exactNonce(resource, salt)
        });
        bytes32 digest = MessageHashUtils.toTypedDataHash(
            TOKEN.DOMAIN_SEPARATOR(),
            keccak256(
                abi.encode(
                    TRANSFER_TYPEHASH, auth.from, auth.to, auth.value, auth.validAfter, auth.validBefore, auth.nonce
                )
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        try LOG.settleExact(auth, resource, salt, abi.encodePacked(r, s, v)) returns (bytes32 id) {
            receipts.push(id);
            ghostPaid += amount;
        } catch {}
    }

    function rate(uint256 receiptSeed, int128 value, uint256 authorSeed) external {
        if (receipts.length == 0) return;
        bytes32 receiptId = receipts[receiptSeed % receipts.length];
        address payer = LOG.receiptOf(receiptId).payer;
        // One time in four, try to use somebody else's receipt.
        address author = authorSeed % 4 == 0 ? vm.addr(clientKeys[authorSeed % 3]) : payer;
        bool shouldSucceed = author == payer && !ghostUsed[receiptId];
        vm.prank(author);
        try REPUTATION.giveFeedback(_input(receiptId, value)) {
            if (!shouldSucceed) ++violations;
            ghostUsed[receiptId] = true;
            ++ghostFeedback;
        } catch {
            if (shouldSucceed) ++violations;
        }
    }

    function rateWithoutReceipt(bytes32 fakeReceipt, int128 value) external {
        address author = vm.addr(clientKeys[0]);
        if (LOG.receiptOf(fakeReceipt).payer != address(0)) return;
        vm.prank(author);
        try REPUTATION.giveFeedback(_input(fakeReceipt, value)) {
            ++violations;
        } catch {}
    }

    function selfRate(uint256 receiptSeed, int128 value, bool asWallet) external {
        bytes32 receiptId = receipts.length == 0 ? bytes32(0) : receipts[receiptSeed % receipts.length];
        vm.prank(asWallet ? wallet(currentWallet) : AGENT_OWNER);
        try REPUTATION.giveFeedback(_input(receiptId, value)) {
            ++violations;
        } catch {}
    }

    function _input(bytes32 receiptId, int128 value) internal view returns (ReputationRegistry.FeedbackInput memory) {
        return ReputationRegistry.FeedbackInput({
            agentId: AGENT_ID,
            value: int128(bound(value, 0, 100)),
            valueDecimals: 0,
            tag1: "",
            tag2: "",
            endpoint: "",
            feedbackURI: "",
            feedbackHash: bytes32(0),
            receiptId: receiptId
        });
    }
}

/// @notice Stateful invariants of receipt-backed reputation. See README "Invariants" I9-I11.
contract ReputationInvariantTest is Fixture {
    ReputationHandler internal handler;
    uint256 internal agentId;
    address internal agentOwner = makeAddr("agentOwner");

    function setUp() public override {
        super.setUp();
        (address wallet0, uint256 walletKey0) = makeAddrAndKey("wallet0");
        (, uint256 walletKey1) = makeAddrAndKey("wallet1");
        vm.startPrank(agentOwner);
        agentId = identity.register("data:,card");
        uint256 deadline = block.timestamp + 1;
        bytes memory sig = _sign(walletKey0, identity.agentWalletDigest(agentId, wallet0, deadline));
        identity.setAgentWallet(agentId, wallet0, deadline, sig);
        vm.stopPrank();
        // Payments start one second after the wallet was set (the registrant was the wallet earlier in that second).
        vm.warp(block.timestamp + 1);

        uint256[3] memory keys;
        for (uint256 i = 0; i < 3; ++i) {
            (address c, uint256 k) = makeAddrAndKey(string(abi.encode("client", i)));
            keys[i] = k;
            _mint(c, 1_000_000e6);
        }
        handler =
            new ReputationHandler(settlement, reputation, token, agentId, agentOwner, keys, [walletKey0, walletKey1]);
        targetContract(address(handler));
    }

    /// @notice I9: every stored feedback is backed by a distinct receipt in which the author paid the agent's
    ///         wallet as it stood when the payment settled, however often the wallet rotated since.
    function invariant_FeedbackBackedByDistinctPaidReceipts() public view {
        uint256 total;
        for (uint256 c = 0; c < 3; ++c) {
            address client = handler.client(c);
            uint64 last = reputation.getLastIndex(agentId, client);
            for (uint64 i = 1; i <= last; ++i) {
                ISettlementLog.Receipt memory r = settlement.receiptOf(reputation.feedbackReceipt(agentId, client, i));
                assertEq(r.payer, client, "receipt payer");
                assertTrue(identity.wasAgentWalletAt(agentId, r.payee, r.settledAt), "receipt payee");
                assertGt(r.amount, 0);
                assertEq(reputation.feedbackWeight(agentId, client, i), r.amount, "weight is the receipt amount");
            }
            total += last;
        }
        assertEq(total, handler.ghostFeedback());
        assertLe(total, handler.receiptCount(), "more feedback than receipts");
    }

    /// @notice I10: the agent's wallets received exactly the settled amounts, one receipt per settlement.
    function invariant_ReceiptsMatchPayments() public view {
        assertEq(token.balanceOf(handler.wallet(0)) + token.balanceOf(handler.wallet(1)), handler.ghostPaid());
        assertEq(settlement.receiptCount(), handler.receiptCount());
    }

    /// @notice I11: no feedback without a receipt, with someone else's receipt, reusing a receipt, or from the
    ///         agent's owner or wallet was ever accepted, and no receipt of the author was ever refused (wallet
    ///         rotations included).
    function invariant_NoUnbackedOrSelfFeedback() public view {
        assertEq(handler.violations(), 0);
    }
}
