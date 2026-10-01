// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {AgentAccount} from "../../src/account/AgentAccount.sol";
import {IdentityRegistry} from "../../src/registry/IdentityRegistry.sol";
import {ReputationRegistry} from "../../src/registry/ReputationRegistry.sol";
import {SettlementLog} from "../../src/settlement/SettlementLog.sol";
import {Fixture} from "../utils/Fixture.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract ReputationRegistryTest is Fixture {
    address internal agentOwner;
    address internal wallet;
    uint256 internal walletKey;
    uint256 internal agentId;
    address internal client2;
    uint256 internal client2Key;

    function setUp() public override {
        super.setUp();
        agentOwner = makeAddr("agentOwner");
        (wallet, walletKey) = makeAddrAndKey("serviceWallet");
        (client2, client2Key) = makeAddrAndKey("client2");
        _mint(payer, 100 * ONE);
        _mint(client2, 100 * ONE);

        vm.startPrank(agentOwner);
        agentId = identity.register("data:application/json;base64,e30=");
        uint256 deadline = block.timestamp + 1 hours;
        identity.setAgentWallet(
            agentId, wallet, deadline, _sign(walletKey, identity.agentWalletDigest(agentId, wallet, deadline))
        );
        vm.stopPrank();
    }

    /// @dev `exact` payment from `key` to the agent wallet; returns the receipt id.
    function _payAgent(uint256 key, uint256 value, bytes32 salt) internal returns (bytes32) {
        return _payTo(key, wallet, value, salt);
    }

    /// @dev `exact` payment from `key` to `to`; returns the receipt id.
    function _payTo(uint256 key, address to, uint256 value, bytes32 salt) internal returns (bytes32) {
        (SettlementLog.ExactAuthorization memory auth, bytes memory sig) = _exactAuth(key, to, value, RESOURCE, salt);
        return settlement.settleExact(auth, RESOURCE, salt, sig);
    }

    /// @dev Moves the agent's wallet to `newWallet` with that wallet's consent.
    function _rotateWallet(address newWallet, uint256 newWalletKey) internal {
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(newWalletKey, identity.agentWalletDigest(agentId, newWallet, deadline));
        vm.prank(agentOwner);
        identity.setAgentWallet(agentId, newWallet, deadline, sig);
    }

    function _input(int128 value, uint8 decimals, bytes32 receiptId)
        internal
        view
        returns (ReputationRegistry.FeedbackInput memory)
    {
        return ReputationRegistry.FeedbackInput({
            agentId: agentId,
            value: value,
            valueDecimals: decimals,
            tag1: "quality",
            tag2: "sentiment",
            endpoint: "/api/v1/sentiment",
            feedbackURI: "",
            feedbackHash: bytes32(0),
            receiptId: receiptId
        });
    }

    function _clients(address a) internal pure returns (address[] memory list) {
        list = new address[](1);
        list[0] = a;
    }

    function test_GiveFeedback() public {
        bytes32 receiptId = _payAgent(payerKey, ONE, "s1");
        vm.expectEmit(address(reputation));
        emit ReputationRegistry.FeedbackReceipt(agentId, payer, 1, receiptId);
        vm.prank(payer);
        uint64 index = reputation.giveFeedback(_input(90, 0, receiptId));
        assertEq(index, 1);
        (int128 value, uint8 decimals, string memory tag1, string memory tag2, bool revoked) =
            reputation.readFeedback(agentId, payer, 1);
        assertEq(value, 90);
        assertEq(decimals, 0);
        assertEq(tag1, "quality");
        assertEq(tag2, "sentiment");
        assertFalse(revoked);
        assertTrue(reputation.receiptUsed(receiptId));
        assertEq(reputation.feedbackReceipt(agentId, payer, 1), receiptId);
        assertEq(reputation.getLastIndex(agentId, payer), 1);
        assertEq(reputation.getClients(agentId).length, 1);
    }

    function test_RevertWhen_ReceiptReused() public {
        bytes32 receiptId = _payAgent(payerKey, ONE, "s1");
        vm.startPrank(payer);
        reputation.giveFeedback(_input(90, 0, receiptId));
        vm.expectRevert(abi.encodeWithSelector(ReputationRegistry.ReceiptAlreadyUsed.selector, receiptId));
        reputation.giveFeedback(_input(10, 0, receiptId));
        vm.stopPrank();
    }

    function test_RevertWhen_NoReceipt() public {
        bytes32 fake = keccak256("fake receipt");
        vm.expectRevert(abi.encodeWithSelector(ReputationRegistry.UnknownReceipt.selector, fake));
        vm.prank(payer);
        reputation.giveFeedback(_input(100, 0, fake));
    }

    function test_RevertWhen_ReceiptBelongsToSomeoneElse() public {
        bytes32 receiptId = _payAgent(payerKey, ONE, "s1");
        vm.expectRevert(abi.encodeWithSelector(ReputationRegistry.ReceiptPayerMismatch.selector, payer, client2));
        vm.prank(client2);
        reputation.giveFeedback(_input(100, 0, receiptId));
    }

    function test_RevertWhen_ReceiptPaidAnotherPayee() public {
        (SettlementLog.ExactAuthorization memory auth, bytes memory sig) =
            _exactAuth(payerKey, otherPayee, ONE, RESOURCE, "s1");
        bytes32 receiptId = settlement.settleExact(auth, RESOURCE, "s1", sig);
        vm.expectRevert(abi.encodeWithSelector(ReputationRegistry.ReceiptPayeeMismatch.selector, otherPayee, wallet));
        vm.prank(payer);
        reputation.giveFeedback(_input(100, 0, receiptId));
    }

    function test_RevertWhen_OwnerOperatorOrWalletRatesItself() public {
        vm.expectRevert(abi.encodeWithSelector(ReputationRegistry.SelfFeedback.selector, agentId, agentOwner));
        vm.prank(agentOwner);
        reputation.giveFeedback(_input(100, 0, bytes32(0)));

        vm.expectRevert(abi.encodeWithSelector(ReputationRegistry.SelfFeedback.selector, agentId, wallet));
        vm.prank(wallet);
        reputation.giveFeedback(_input(100, 0, bytes32(0)));

        vm.prank(agentOwner);
        identity.setApprovalForAll(payer, true);
        bytes32 receiptId = _payAgent(payerKey, ONE, "s1");
        vm.expectRevert(abi.encodeWithSelector(ReputationRegistry.SelfFeedback.selector, agentId, payer));
        vm.prank(payer);
        reputation.giveFeedback(_input(100, 0, receiptId));
    }

    /// @notice Regression: the owner cannot void receipts (and censor the feedback they back) by rotating, clearing
    ///         or transferring away the wallet after clients paid it.
    function test_FeedbackSurvivesWalletRotationClearingAndTransfer() public {
        // setUp set the wallet at T0; start one second later so that wallet is the one in force before the block.
        vm.warp(block.timestamp + 1);
        bytes32 r1 = _payAgent(payerKey, ONE, "s1");
        (address w2, uint256 w2Key) = makeAddrAndKey("rotatedWallet");
        _rotateWallet(w2, w2Key); // same block as the payment
        vm.warp(block.timestamp + 1 days);
        _rotateWallet(wallet, walletKey);
        bytes32 r2 = _payAgent(client2Key, ONE, "s2");
        vm.warp(block.timestamp + 1 days);
        _rotateWallet(w2, w2Key);
        bytes32 r3 = _payTo(payerKey, w2, ONE, "s3");
        vm.warp(block.timestamp + 1 days);
        vm.prank(agentOwner);
        identity.unsetAgentWallet(agentId);
        vm.prank(agentOwner);
        identity.transferFrom(agentOwner, relayer, agentId);

        vm.prank(payer);
        reputation.giveFeedback(_input(0, 0, r1));
        vm.prank(client2);
        reputation.giveFeedback(_input(10, 0, r2));
        vm.prank(payer);
        reputation.giveFeedback(_input(20, 0, r3));
        assertEq(reputation.getLastIndex(agentId, payer), 2);
        assertEq(reputation.getLastIndex(agentId, client2), 1);
    }

    function test_RevertWhen_ReceiptPaidWalletBeforeItBecameTheAgentWallet() public {
        (address w2, uint256 w2Key) = makeAddrAndKey("laterWallet");
        bytes32 early = _payTo(payerKey, w2, ONE, "early");
        vm.warp(block.timestamp + 10);
        _rotateWallet(w2, w2Key);
        vm.expectRevert(abi.encodeWithSelector(ReputationRegistry.ReceiptPayeeMismatch.selector, w2, wallet));
        vm.prank(payer);
        reputation.giveFeedback(_input(100, 0, early));
    }

    /// @notice Regression: a receipt paid to one agent cannot back feedback on a sibling agent of the same operator,
    ///         because a wallet serves one agent at a time.
    function test_RevertWhen_ReceiptBacksFeedbackOnAnotherAgent() public {
        vm.prank(agentOwner);
        uint256 sibling = identity.register("data:,sibling");
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(walletKey, identity.agentWalletDigest(sibling, wallet, deadline));
        vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.WalletInUse.selector, wallet, agentId));
        vm.prank(agentOwner);
        identity.setAgentWallet(sibling, wallet, deadline, sig);

        bytes32 receiptId = _payAgent(payerKey, ONE, "s1");
        ReputationRegistry.FeedbackInput memory f = _input(100, 0, receiptId);
        f.agentId = sibling;
        vm.expectRevert(abi.encodeWithSelector(ReputationRegistry.ReceiptPayeeMismatch.selector, wallet, agentOwner));
        vm.prank(payer);
        reputation.giveFeedback(f);
    }

    function test_RevertWhen_UnknownAgent() public {
        ReputationRegistry.FeedbackInput memory f = _input(1, 0, bytes32(0));
        f.agentId = 999;
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 999));
        vm.prank(payer);
        reputation.giveFeedback(f);
    }

    function test_RevertWhen_ValueOrDecimalsOutOfRange() public {
        bytes32 receiptId = _payAgent(payerKey, ONE, "s1");
        bytes32 other = _payAgent(payerKey, ONE, "s2");
        vm.startPrank(payer);
        vm.expectRevert(abi.encodeWithSelector(ReputationRegistry.InvalidDecimals.selector, 19));
        reputation.giveFeedback(_input(1, 19, receiptId));
        vm.expectRevert(abi.encodeWithSelector(ReputationRegistry.ValueOutOfRange.selector, int128(101), 0));
        reputation.giveFeedback(_input(101, 0, receiptId));
        vm.expectRevert(abi.encodeWithSelector(ReputationRegistry.ValueOutOfRange.selector, int128(-1001), 1));
        reputation.giveFeedback(_input(-1001, 1, receiptId));
        int128 huge = type(int128).max;
        vm.expectRevert(abi.encodeWithSelector(ReputationRegistry.ValueOutOfRange.selector, huge, 18));
        reputation.giveFeedback(_input(huge, 18, receiptId));
        // Both ends of the scale are accepted, whatever the decimals.
        reputation.giveFeedback(_input(100e18, 18, receiptId));
        reputation.giveFeedback(_input(-100, 0, other));
        vm.stopPrank();
    }

    function test_GiveFeedbackBySig_EOA() public {
        bytes32 receiptId = _payAgent(payerKey, ONE, "s1");
        ReputationRegistry.FeedbackInput memory f = _input(75, 0, receiptId);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(payerKey, reputation.feedbackDigest(f, payer, deadline));
        vm.prank(relayer);
        reputation.giveFeedbackBySig(f, payer, deadline, sig);
        (int128 value,,,,) = reputation.readFeedback(agentId, payer, 1);
        assertEq(value, 75);
        assertEq(reputation.nonces(payer), 1);
    }

    function test_RevertWhen_FeedbackSigInvalidOrExpired() public {
        bytes32 receiptId = _payAgent(payerKey, ONE, "s1");
        ReputationRegistry.FeedbackInput memory f = _input(75, 0, receiptId);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(client2Key, reputation.feedbackDigest(f, payer, deadline));
        vm.expectRevert(abi.encodeWithSelector(ReputationRegistry.InvalidFeedbackSignature.selector, payer));
        reputation.giveFeedbackBySig(f, payer, deadline, sig);

        sig = _sign(payerKey, reputation.feedbackDigest(f, payer, deadline));
        // Relayer bumps the score: signature no longer matches.
        f.value = 100;
        vm.expectRevert(abi.encodeWithSelector(ReputationRegistry.InvalidFeedbackSignature.selector, payer));
        reputation.giveFeedbackBySig(f, payer, deadline, sig);

        f.value = 75;
        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(ReputationRegistry.SignatureExpired.selector, deadline));
        reputation.giveFeedbackBySig(f, payer, deadline, sig);
    }

    function test_GiveFeedbackBySig_SmartAccountPayer() public {
        // The agent's smart account paid through the budget executor, then its owner signs feedback (ERC-7739).
        address[] memory payees = new address[](1);
        payees[0] = wallet;
        AgentAccount account = _createAccount(_defaultPolicy(), payees);
        _mint(address(account), 10 * ONE);
        bytes32 receiptId = _pay(address(account), wallet, ONE, keccak256("intent"));

        ReputationRegistry.FeedbackInput memory f = _input(88, 0, receiptId);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 structHash = keccak256(
            bytes.concat(
                abi.encode(
                    reputation.FEEDBACK_TYPEHASH(),
                    f.agentId,
                    f.value,
                    f.valueDecimals,
                    keccak256(bytes(f.tag1)),
                    keccak256(bytes(f.tag2)),
                    keccak256(bytes(f.endpoint)),
                    keccak256(bytes(f.feedbackURI))
                ),
                abi.encode(f.feedbackHash, f.receiptId, address(account), uint256(0), deadline)
            )
        );
        bytes memory sig = _erc7739Sign(
            ownerKey,
            account,
            _domainSeparator(address(reputation)),
            structHash,
            "Feedback",
            "Feedback(uint256 agentId,int128 value,uint8 valueDecimals,string tag1,string tag2,string endpoint,string feedbackURI,bytes32 feedbackHash,bytes32 receiptId,address client,uint256 nonce,uint256 deadline)"
        );
        vm.prank(relayer);
        reputation.giveFeedbackBySig(f, address(account), deadline, sig);
        (int128 value,,,,) = reputation.readFeedback(agentId, address(account), 1);
        assertEq(value, 88);
    }

    function test_RevokeFeedback() public {
        bytes32 receiptId = _payAgent(payerKey, ONE, "s1");
        vm.startPrank(payer);
        reputation.giveFeedback(_input(90, 0, receiptId));
        vm.expectEmit(address(reputation));
        emit ReputationRegistry.FeedbackRevoked(agentId, payer, 1);
        reputation.revokeFeedback(agentId, 1);
        vm.expectRevert(abi.encodeWithSelector(ReputationRegistry.AlreadyRevoked.selector, 1));
        reputation.revokeFeedback(agentId, 1);
        vm.expectRevert(abi.encodeWithSelector(ReputationRegistry.FeedbackNotFound.selector, agentId, payer, 2));
        reputation.revokeFeedback(agentId, 2);
        vm.expectRevert(abi.encodeWithSelector(ReputationRegistry.FeedbackNotFound.selector, agentId, payer, 0));
        reputation.revokeFeedback(agentId, 0);
        vm.stopPrank();
        (,,,, bool revoked) = reputation.readFeedback(agentId, payer, 1);
        assertTrue(revoked);
        assertTrue(reputation.receiptUsed(receiptId), "revocation does not free the receipt");
    }

    function test_AppendResponse() public {
        bytes32 receiptId = _payAgent(payerKey, ONE, "s1");
        vm.prank(payer);
        reputation.giveFeedback(_input(10, 0, receiptId));
        vm.expectEmit(address(reputation));
        emit ReputationRegistry.ResponseAppended(agentId, payer, 1, agentOwner, "ipfs://refund", keccak256("r"));
        vm.prank(agentOwner);
        reputation.appendResponse(agentId, payer, 1, "ipfs://refund", keccak256("r"));
        assertEq(reputation.getResponseCount(agentId, payer, 1), 1);
        vm.expectRevert(abi.encodeWithSelector(ReputationRegistry.FeedbackNotFound.selector, agentId, payer, 5));
        reputation.appendResponse(agentId, payer, 5, "", bytes32(0));
    }

    function test_GetSummary() public {
        bytes32 ra = _payAgent(payerKey, ONE, "a");
        bytes32 rb = _payAgent(payerKey, ONE, "b");
        bytes32 rc = _payAgent(client2Key, ONE, "c");
        vm.prank(payer);
        reputation.giveFeedback(_input(80, 0, ra));
        vm.prank(payer);
        reputation.giveFeedback(_input(605, 1, rb)); // 60.5
        ReputationRegistry.FeedbackInput memory other = _input(10, 0, rc);
        other.tag1 = "speed";
        vm.prank(client2);
        reputation.giveFeedback(other);

        address[] memory both = new address[](2);
        both[0] = payer;
        both[1] = client2;
        (uint64 count, int128 avg, uint8 decimals) = reputation.getSummary(agentId, both, "", "");
        assertEq(count, 3);
        assertEq(decimals, 18);
        int256 total = 80e18 + 60.5e18 + 10e18;
        assertEq(avg, int128(total / 3));

        (count, avg,) = reputation.getSummary(agentId, both, "quality", "");
        assertEq(count, 2);
        assertEq(avg, int128(70.25e18));

        (count,,) = reputation.getSummary(agentId, both, "", "nope");
        assertEq(count, 0);

        vm.prank(payer);
        reputation.revokeFeedback(agentId, 1);
        (count, avg,) = reputation.getSummary(agentId, _clients(payer), "", "");
        assertEq(count, 1);
        assertEq(avg, int128(60.5e18));

        (count, avg, decimals) = reputation.getSummary(agentId, _clients(relayer), "", "");
        assertEq(count + uint64(uint128(avg)) + decimals, 0);
    }

    function test_GetSummaryWeightsByReceiptAmount() public {
        bytes32 big = _payAgent(payerKey, 3 * ONE, "big");
        bytes32 small = _payAgent(client2Key, ONE, "small");
        vm.prank(payer);
        reputation.giveFeedback(_input(90, 0, big));
        vm.prank(client2);
        reputation.giveFeedback(_input(10, 0, small));
        assertEq(reputation.feedbackWeight(agentId, payer, 1), 3 * ONE);
        assertEq(reputation.feedbackWeight(agentId, client2, 1), ONE);

        address[] memory both = new address[](2);
        both[0] = payer;
        both[1] = client2;
        (uint64 count, int128 avg,) = reputation.getSummary(agentId, both, "", "");
        assertEq(count, 2);
        assertEq(avg, int128(70e18), "(90 * 3 + 10 * 1) / 4");
    }

    /// @notice A receipt of one base unit still backs a feedback entry (it is counted), but it weighs one base unit
    ///         in the average: a dust payment cannot move the score of an agent with real paying clients.
    function test_DustReceiptBuysDustWeight() public {
        bytes32 honest = _payAgent(payerKey, ONE, "honest");
        bytes32 dust = _payAgent(client2Key, 1, "dust");
        vm.prank(payer);
        reputation.giveFeedback(_input(90, 0, honest));
        vm.prank(client2);
        reputation.giveFeedback(_input(-100, 0, dust));
        assertEq(reputation.feedbackWeight(agentId, client2, 1), 1);

        address[] memory both = new address[](2);
        both[0] = payer;
        both[1] = client2;
        (uint64 count, int128 avg,) = reputation.getSummary(agentId, both, "", "");
        assertEq(count, 2, "the dust review is counted");
        assertEq(avg, int128((int256(90e18) * int256(ONE) - 100e18) / int256(ONE + 1)));
        assertGt(avg, int128(89.9998e18), "and moves the average by less than 0.0002");
    }

    function test_RevertWhen_SummaryWithoutClientFilter() public {
        vm.expectRevert(ReputationRegistry.ClientFilterRequired.selector);
        reputation.getSummary(agentId, new address[](0), "", "");
    }

    /// @notice The summary is exactly the receipt-weighted mean of the normalized values and lies between them.
    function testFuzz_SummaryBounds(int128 a, int128 b, uint8 da, uint8 db, uint256 wa, uint256 wb) public {
        da = uint8(bound(da, 0, 18));
        db = uint8(bound(db, 0, 18));
        int256 limitA = 100 * int256(10 ** uint256(da));
        int256 limitB = 100 * int256(10 ** uint256(db));
        a = int128(bound(a, -limitA, limitA));
        b = int128(bound(b, -limitB, limitB));
        wa = bound(wa, 1, 50 * ONE);
        wb = bound(wb, 1, 50 * ONE);
        bytes32 ra = _payAgent(payerKey, wa, "fa");
        bytes32 rb = _payAgent(payerKey, wb, "fb");
        vm.startPrank(payer);
        reputation.giveFeedback(_input(a, da, ra));
        reputation.giveFeedback(_input(b, db, rb));
        vm.stopPrank();
        (uint64 count, int128 avg,) = reputation.getSummary(agentId, _clients(payer), "", "");
        assertEq(count, 2);
        int256 na = int256(a) * int256(10 ** uint256(18 - da));
        int256 nb = int256(b) * int256(10 ** uint256(18 - db));
        assertEq(avg, (na * int256(wa) + nb * int256(wb)) / int256(wa + wb));
        assertGe(avg, na < nb ? na : nb);
        assertLe(avg, na < nb ? nb : na);
    }
}
