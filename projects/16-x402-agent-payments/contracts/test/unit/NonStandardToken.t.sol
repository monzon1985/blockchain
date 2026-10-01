// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {AgentAccount} from "../../src/account/AgentAccount.sol";
import {AgentAccountFactory} from "../../src/account/AgentAccountFactory.sol";
import {PaymentEscrow} from "../../src/escrow/PaymentEscrow.sol";
import {BudgetExecutor} from "../../src/modules/BudgetExecutor.sol";
import {ResourceBinding} from "../../src/settlement/ResourceBinding.sol";
import {SettlementLog} from "../../src/settlement/SettlementLog.sol";
import {Fixture} from "../utils/Fixture.sol";
import {QuirkyToken} from "../utils/Mocks.sol";

/// @notice The settlement contracts never trust a token's word: they measure balance deltas. These tests deploy
///         the stack over a fee-on-transfer / no-return-value token and check that short deliveries revert.
contract NonStandardTokenTest is Fixture {
    QuirkyToken internal quirky;
    SettlementLog internal qLog;
    BudgetExecutor internal qExecutor;
    PaymentEscrow internal qEscrow;
    AgentAccount internal qAccount;

    function setUp() public override {
        super.setUp();
        quirky = new QuirkyToken();
        vm.startPrank(deployer);
        qLog = new SettlementLog(address(quirky), deployer);
        qExecutor = new BudgetExecutor(qLog);
        qEscrow = new PaymentEscrow(qLog);
        qLog.setRecorder(address(qExecutor), true);
        qLog.setRecorder(address(qEscrow), true);
        qLog.seal();
        vm.stopPrank();
        AgentAccountFactory qFactory = new AgentAccountFactory(address(qExecutor));
        qAccount = AgentAccount(payable(qFactory.createAccount(owner, abi.encode(_defaultPolicy(), _payees()), 0)));
        quirky.mint(address(qAccount), 100 * ONE);
        quirky.mint(payer, 100 * ONE);
    }

    function _exact() internal view returns (SettlementLog.ExactAuthorization memory) {
        return SettlementLog.ExactAuthorization({
            from: payer,
            to: payee,
            value: ONE,
            validAfter: 0,
            validBefore: type(uint256).max,
            nonce: ResourceBinding.exactNonce(RESOURCE, "s")
        });
    }

    function _escrowOpen() internal view returns (PaymentEscrow.OpenRequest memory) {
        uint64 deadline = uint64(block.timestamp + 1 hours);
        return PaymentEscrow.OpenRequest({
            from: payer,
            value: ONE,
            validAfter: 0,
            validBefore: type(uint256).max,
            nonce: ResourceBinding.escrowNonce(payee, RESOURCE, deadline, "s"),
            payee: payee,
            resourceHash: RESOURCE,
            deliveryDeadline: deadline,
            salt: "s"
        });
    }

    function _qPay(bytes32 nonce) internal returns (bytes32) {
        BudgetExecutor.PaymentIntent memory intent = _intent(address(qAccount), payee, ONE, RESOURCE, nonce);
        bytes memory sig = _sign(sessionKey, qExecutor.hashPaymentIntent(intent));
        return qExecutor.pay(intent, sig);
    }

    function test_ExactSettlement_RejectsShortDelivery() public {
        quirky.setFee(100); // 1 %
        vm.expectRevert(abi.encodeWithSelector(SettlementLog.TransferAmountMismatch.selector, ONE, ONE - ONE / 100));
        qLog.settleExact(_exact(), RESOURCE, "s", "");
    }

    function test_ExactSettlement_AcceptsExactDelivery() public {
        qLog.settleExact(_exact(), RESOURCE, "s", "");
        assertEq(quirky.balanceOf(payee), ONE);
    }

    function test_BudgetPay_RejectsShortDelivery() public {
        quirky.setFee(100);
        bytes32 nonce = keccak256("n");
        BudgetExecutor.PaymentIntent memory intent = _intent(address(qAccount), payee, ONE, RESOURCE, nonce);
        bytes memory sig = _sign(sessionKey, qExecutor.hashPaymentIntent(intent));
        vm.expectRevert(abi.encodeWithSelector(BudgetExecutor.TransferFailed.selector, ONE, ONE - ONE / 100));
        qExecutor.pay(intent, sig);
    }

    function test_BudgetPay_AcceptsTokenWithoutReturnValue() public {
        quirky.setReturnsBool(false);
        _qPay(keccak256("n"));
        assertEq(quirky.balanceOf(payee), ONE);
    }

    function test_Escrow_RejectsShortFunding() public {
        quirky.setFee(100);
        vm.expectRevert(abi.encodeWithSelector(PaymentEscrow.FundingMismatch.selector, ONE, ONE - ONE / 100));
        qEscrow.open(_escrowOpen(), "");
    }
}
