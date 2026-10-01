// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {AgentAccount} from "../../src/account/AgentAccount.sol";
import {PaymentEscrow} from "../../src/escrow/PaymentEscrow.sol";
import {BudgetExecutor} from "../../src/modules/BudgetExecutor.sol";
import {ReputationRegistry} from "../../src/registry/ReputationRegistry.sol";
import {SettlementLog} from "../../src/settlement/SettlementLog.sol";
import {Fixture} from "../utils/Fixture.sol";

/// @notice Deterministic gas benchmarks. Each test measures exactly one external call with
///         `vm.snapshotGasLastFrame`, written to `snapshots/x402.json`, and the whole-test totals go to
///         `.gas-snapshot`. Both files are committed and checked in CI.
contract GasTest is Fixture {
    AgentAccount internal account;

    function setUp() public override {
        super.setUp();
        _mint(payer, 1000 * ONE);
        account = _createAccount(_policy(uint128(ONE), uint128(20 * ONE), 1 hours, 32), _payees());
        _mint(address(account), 1000 * ONE);
        // Steady state: the payee already holds tokens and the log already has receipts, so the benchmarks do not
        // include one-off zero-to-non-zero writes of shared counters.
        _mint(payee, 1);
        _settleExact(1, RESOURCE, "warm-up");
    }

    /// @dev 32 payments one period apart: every ring slot has been written once and each payment expired the
    ///      previous one, so later writes are non-zero to non-zero like on a long-lived account.
    function _warmRing() internal {
        for (uint256 i = 0; i < executor.RING_CAPACITY(); ++i) {
            vm.warp(block.timestamp + 1 hours);
            _pay(address(account), payee, ONE, keccak256(abi.encode("warm", i)));
        }
        vm.warp(block.timestamp + 1 hours);
    }

    /// Baseline: a raw EIP-3009 transfer, without receipt recording.
    function test_Gas_Baseline_TransferWithAuthorization() public {
        (SettlementLog.ExactAuthorization memory a, bytes memory sig) =
            _exactAuth(payerKey, payee, ONE, RESOURCE, "baseline");
        token.transferWithAuthorization(a.from, a.to, a.value, a.validAfter, a.validBefore, a.nonce, sig);
        vm.snapshotGasLastFrame("x402", "baseline_transferWithAuthorization");
    }

    function test_Gas_SettleExact() public {
        (SettlementLog.ExactAuthorization memory a, bytes memory sig) = _exactAuth(payerKey, payee, ONE, RESOURCE, "s");
        settlement.settleExact(a, RESOURCE, "s", sig);
        vm.snapshotGasLastFrame("x402", "settleExact");
    }

    function test_Gas_BudgetPay_FirstPaymentOfAccount() public {
        _payMeasured(keccak256("first"), "budgetPay_firstEver");
    }

    function test_Gas_BudgetPay_Steady_OneExpired() public {
        _warmRing();
        _payMeasured(keccak256("next"), "budgetPay_steady_1expired");
    }

    function test_Gas_BudgetPay_Steady_FourLive() public {
        _warmRing();
        for (uint256 i = 0; i < 4; ++i) {
            _pay(address(account), payee, ONE, bytes32(i + 1));
        }
        _payMeasured(keccak256("fifth"), "budgetPay_steady_4live_0expired");
    }

    function test_Gas_BudgetPay_Steady_FiveExpireAtOnce() public {
        _warmRing();
        for (uint256 i = 0; i < 4; ++i) {
            _pay(address(account), payee, ONE, bytes32(i + 1));
        }
        vm.warp(block.timestamp + 1 hours);
        _payMeasured(keccak256("fifth"), "budgetPay_steady_5expired");
    }

    function test_Gas_CreateAccount() public {
        factory.createAccount(owner, abi.encode(_defaultPolicy(), _payees()), bytes32(uint256(77)));
        vm.snapshotGasLastFrame("x402", "factory_createAccount");
    }

    function test_Gas_EscrowOpenDeliver() public {
        uint64 deadline = uint64(block.timestamp + 1 hours);
        (PaymentEscrow.OpenRequest memory r, bytes memory sig) =
            _escrowRequest(payerKey, payee, ONE, RESOURCE, deadline, "e");
        bytes32 id = escrow.open(r, sig);
        vm.snapshotGasLastFrame("x402", "escrow_open");
        vm.prank(payee);
        escrow.deliver(id, keccak256("result"));
        vm.snapshotGasLastFrame("x402", "escrow_deliver");
    }

    function test_Gas_EscrowRefund() public {
        uint64 deadline = uint64(block.timestamp + 1 hours);
        (PaymentEscrow.OpenRequest memory r, bytes memory sig) =
            _escrowRequest(payerKey, payee, ONE, RESOURCE, deadline, "e");
        bytes32 id = escrow.open(r, sig);
        vm.warp(uint256(deadline) + 1);
        escrow.refund(id);
        vm.snapshotGasLastFrame("x402", "escrow_refund");
    }

    function test_Gas_GiveFeedback() public {
        address agentOwner = makeAddr("agentOwner");
        vm.prank(agentOwner);
        uint256 agentId = identity.register("data:,card");
        vm.snapshotGasLastFrame("x402", "identity_register");
        (SettlementLog.ExactAuthorization memory a, bytes memory sig) =
            _exactAuth(payerKey, agentOwner, ONE, RESOURCE, "f");
        bytes32 receiptId = settlement.settleExact(a, RESOURCE, "f", sig);
        ReputationRegistry.FeedbackInput memory f = ReputationRegistry.FeedbackInput({
            agentId: agentId,
            value: 95,
            valueDecimals: 0,
            tag1: "quality",
            tag2: "",
            endpoint: "/api/v1/sentiment",
            feedbackURI: "",
            feedbackHash: bytes32(0),
            receiptId: receiptId
        });
        vm.prank(payer);
        reputation.giveFeedback(f);
        vm.snapshotGasLastFrame("x402", "reputation_giveFeedback");
    }

    function _payMeasured(bytes32 nonce, string memory name) internal {
        BudgetExecutor.PaymentIntent memory intent = _intent(address(account), payee, ONE, RESOURCE, nonce);
        bytes memory sig = _signIntent(sessionKey, intent);
        executor.pay(intent, sig);
        vm.snapshotGasLastFrame("x402", name);
    }
}
