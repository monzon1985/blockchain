// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {AgentAccount} from "../../src/account/AgentAccount.sol";
import {BudgetExecutor} from "../../src/modules/BudgetExecutor.sol";
import {SettlementLog} from "../../src/settlement/SettlementLog.sol";
import {TestUSD} from "../../src/token/TestUSD.sol";
import {Fixture} from "../utils/Fixture.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

/// @notice Drives the budget executor with random payments, time jumps, replays and tampered intents, and keeps a
///         ghost log of every payment that succeeded.
contract BudgetHandler is CommonBase, StdCheats, StdUtils {
    struct Spend {
        uint256 timestamp;
        uint256 amount;
    }

    BudgetExecutor internal immutable EXECUTOR;
    TestUSD internal immutable TOKEN;
    address internal immutable ACCOUNT;
    uint256 internal immutable SESSION_KEY;
    address[3] internal payees;

    Spend[] public spends;
    uint256 public ghostTotal;
    uint256 public violations;
    uint256 internal nonceCounter;
    bytes32 internal lastNonce;
    uint256 public calls;

    constructor(
        BudgetExecutor executor,
        TestUSD token,
        address account,
        uint256 sessionKey,
        address[3] memory payees_
    ) {
        EXECUTOR = executor;
        TOKEN = token;
        ACCOUNT = account;
        SESSION_KEY = sessionKey;
        payees = payees_;
    }

    function spendCount() external view returns (uint256) {
        return spends.length;
    }

    function spendAt(uint256 i) external view returns (uint256, uint256) {
        return (spends[i].timestamp, spends[i].amount);
    }

    function _intent(address payee, uint256 amount, bytes32 nonce)
        internal
        view
        returns (BudgetExecutor.PaymentIntent memory)
    {
        return BudgetExecutor.PaymentIntent({
            account: ACCOUNT,
            payee: payee,
            amount: amount,
            resourceHash: keccak256("resource"),
            nonce: nonce,
            validAfter: block.timestamp - 1,
            validBefore: block.timestamp + 60
        });
    }

    function _sig(BudgetExecutor.PaymentIntent memory intent) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SESSION_KEY, EXECUTOR.hashPaymentIntent(intent));
        return abi.encodePacked(r, s, v);
    }

    /// @notice Honest payment attempt; may legitimately fail on budget, rate limit, cap or allowlist.
    function pay(uint256 amountSeed, uint256 payeeSeed) external {
        ++calls;
        uint256 amount = bound(amountSeed, 1, 1.25e6); // cap is 1e6: ~20% of attempts exceed it
        address payee = payees[payeeSeed % 3]; // payees[2] is not allowlisted
        bytes32 nonce = keccak256(abi.encode("nonce", ++nonceCounter));
        BudgetExecutor.PaymentIntent memory intent = _intent(payee, amount, nonce);
        try EXECUTOR.pay(intent, _sig(intent)) {
            spends.push(Spend(block.timestamp, amount));
            ghostTotal += amount;
            lastNonce = nonce;
            if (payee == payees[2] || amount > 1e6) ++violations;
        } catch {}
    }

    /// @notice Moves time forward by up to two periods.
    function warp(uint256 dt) external {
        ++calls;
        vm.warp(block.timestamp + bound(dt, 0, 2 hours));
    }

    /// @notice Replays the last successful intent nonce: must always fail.
    function replay(uint256 amountSeed) external {
        ++calls;
        if (lastNonce == bytes32(0)) return;
        BudgetExecutor.PaymentIntent memory intent = _intent(payees[0], bound(amountSeed, 1, 1e6), lastNonce);
        try EXECUTOR.pay(intent, _sig(intent)) {
            ++violations;
        } catch {}
    }

    /// @notice Signs one amount and submits another (a malicious relayer): must always fail.
    function tamper(uint256 signedSeed, uint256 submittedSeed) external {
        ++calls;
        uint256 signedAmount = bound(signedSeed, 1, 1e6);
        uint256 submitted = bound(submittedSeed, 1, 1e6);
        if (signedAmount == submitted) return;
        bytes32 nonce = keccak256(abi.encode("tamper", ++nonceCounter));
        BudgetExecutor.PaymentIntent memory intent = _intent(payees[0], signedAmount, nonce);
        bytes memory sig = _sig(intent);
        intent.amount = submitted;
        try EXECUTOR.pay(intent, sig) {
            ++violations;
        } catch {}
    }
}

/// @notice Stateful invariants of the rolling-window budget. See README "Invariants" I1-I5.
contract BudgetWindowInvariantTest is Fixture {
    BudgetHandler internal handler;
    AgentAccount internal account;
    uint256 internal constant FUNDING = 1_000_000e6;
    uint128 internal constant BUDGET = 3e6;
    uint32 internal constant PERIOD = 1 hours;
    uint16 internal constant MAX_PAYMENTS = 5;
    address internal stranger = makeAddr("stranger");

    function setUp() public override {
        super.setUp();
        BudgetExecutor.Policy memory policy = _policy(uint128(ONE), BUDGET, PERIOD, MAX_PAYMENTS);
        policy.validUntil = uint48(block.timestamp + 3650 days);
        account = _createAccount(policy, _payees());
        _mint(address(account), FUNDING);
        handler = new BudgetHandler(executor, token, address(account), sessionKey, [payee, otherPayee, stranger]);

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = BudgetHandler.pay.selector;
        selectors[1] = BudgetHandler.warp.selector;
        selectors[2] = BudgetHandler.replay.selector;
        selectors[3] = BudgetHandler.tamper.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @notice I1: for every payment time t, payments in (t - period, t] sum to at most the budget. Checking the
    ///         windows that end at each payment is sufficient: the sum over any window is maximised by a window
    ///         ending at one of its own payments.
    function invariant_SpendInAnyWindowWithinBudget() public view {
        uint256 n = handler.spendCount();
        for (uint256 i = 0; i < n; ++i) {
            (uint256 ti,) = handler.spendAt(i);
            uint256 sum;
            for (uint256 j = 0; j < n; ++j) {
                (uint256 tj, uint256 aj) = handler.spendAt(j);
                if (tj <= ti && tj + PERIOD > ti) sum += aj;
            }
            assertLe(sum, BUDGET, "window budget exceeded");
        }
    }

    /// @notice I2: no window contains more than `maxPaymentsPerPeriod` payments.
    function invariant_PaymentsInAnyWindowWithinRateLimit() public view {
        uint256 n = handler.spendCount();
        for (uint256 i = 0; i < n; ++i) {
            (uint256 ti,) = handler.spendAt(i);
            uint256 count;
            for (uint256 j = 0; j < n; ++j) {
                (uint256 tj,) = handler.spendAt(j);
                if (tj <= ti && tj + PERIOD > ti) ++count;
            }
            assertLe(count, MAX_PAYMENTS, "rate limit exceeded");
        }
    }

    /// @notice I3: the module's own window accounting equals the ghost recomputation for the current time.
    function invariant_WindowStateMatchesGhost() public view {
        (uint256 spent, uint256 count) = executor.windowState(address(account));
        uint256 ghostSpent;
        uint256 ghostCount;
        uint256 n = handler.spendCount();
        for (uint256 j = 0; j < n; ++j) {
            (uint256 tj, uint256 aj) = handler.spendAt(j);
            if (tj + PERIOD > block.timestamp) {
                ghostSpent += aj;
                ++ghostCount;
            }
        }
        assertEq(spent, ghostSpent, "spent drift");
        assertEq(count, ghostCount, "count drift");
    }

    /// @notice I4: the account lost exactly what the ghost log paid out, all of it to allowlisted payees, and every
    ///         payment has a receipt.
    function invariant_ConservationAndReceipts() public view {
        uint256 total = handler.ghostTotal();
        assertEq(FUNDING - token.balanceOf(address(account)), total);
        assertEq(token.balanceOf(payee) + token.balanceOf(otherPayee), total);
        assertEq(token.balanceOf(stranger), 0);
        assertEq(settlement.receiptCount(), handler.spendCount());
    }

    /// @notice I5: replayed nonces, tampered amounts, over-cap amounts and non-allowlisted payees never succeed.
    function invariant_NoUnauthorizedSpend() public view {
        assertEq(handler.violations(), 0);
    }
}
