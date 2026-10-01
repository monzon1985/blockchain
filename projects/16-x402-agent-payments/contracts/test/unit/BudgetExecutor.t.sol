// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {AgentAccount} from "../../src/account/AgentAccount.sol";
import {ISettlementLog} from "../../src/interfaces/ISettlementLog.sol";
import {BudgetExecutor} from "../../src/modules/BudgetExecutor.sol";
import {Fixture} from "../utils/Fixture.sol";
import {Mock1271Signer} from "../utils/Mocks.sol";
import {
    ERC7579Utils,
    Mode,
    ModePayload,
    ModeSelector
} from "@openzeppelin/contracts/account/utils/draft-ERC7579Utils.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {MODULE_TYPE_EXECUTOR, MODULE_TYPE_VALIDATOR} from "@openzeppelin/contracts/interfaces/draft-IERC7579.sol";

contract BudgetExecutorTest is Fixture {
    AgentAccount internal account;

    function setUp() public override {
        super.setUp();
        account = _createAccount(_defaultPolicy(), _payees());
        _mint(address(account), 100 * ONE);
    }

    // ------------------------------------------------------------------ install

    function test_InstalledByFactory() public view {
        assertTrue(executor.isInitialized(address(account)));
        assertTrue(account.isModuleInstalled(MODULE_TYPE_EXECUTOR, address(executor), ""));
        BudgetExecutor.Policy memory p = executor.policyOf(address(account));
        assertEq(p.sessionKey, session);
        assertEq(p.perCallCap, ONE);
        assertEq(p.periodBudget, 5 * ONE);
        assertEq(p.period, 1 hours);
        assertEq(p.maxPaymentsPerPeriod, 16);
        assertTrue(executor.isPayeeAllowed(address(account), payee));
        assertTrue(executor.isPayeeAllowed(address(account), otherPayee));
        assertFalse(executor.isPayeeAllowed(address(account), relayer));
        assertEq(executor.remainingBudget(address(account)), 5 * ONE);
    }

    function test_IsModuleType() public view {
        assertTrue(executor.isModuleType(MODULE_TYPE_EXECUTOR));
        assertFalse(executor.isModuleType(MODULE_TYPE_VALIDATOR));
    }

    function test_RevertWhen_InstalledTwice() public {
        vm.expectRevert(abi.encodeWithSelector(BudgetExecutor.AlreadyInstalled.selector, address(account)));
        vm.prank(address(account));
        executor.onInstall(abi.encode(_defaultPolicy(), _payees()));
    }

    function test_RevertWhen_InstallWithInvalidLimits() public {
        BudgetExecutor.Policy memory p = _defaultPolicy();
        p.perCallCap = 0;
        _expectInvalidLimits(p);
        p = _defaultPolicy();
        p.perCallCap = p.periodBudget + 1;
        _expectInvalidLimits(p);
        p = _defaultPolicy();
        p.period = executor.MIN_PERIOD() - 1;
        _expectInvalidLimits(p);
        p = _defaultPolicy();
        p.period = executor.MAX_PERIOD() + 1;
        _expectInvalidLimits(p);
        p = _defaultPolicy();
        p.maxPaymentsPerPeriod = 0;
        _expectInvalidLimits(p);
        p = _defaultPolicy();
        p.maxPaymentsPerPeriod = uint16(executor.RING_CAPACITY() + 1);
        _expectInvalidLimits(p);
    }

    function test_RevertWhen_InstallWithInvalidSessionKey() public {
        BudgetExecutor.Policy memory p = _defaultPolicy();
        p.sessionKey = address(0);
        _expectInvalidSession(p, address(0xBEEF));
        p = _defaultPolicy();
        p.sessionKey = address(0xBEEF);
        _expectInvalidSession(p, address(0xBEEF));
    }

    /// @notice An already-expired session installs (so a counterfactual deployment can never be bricked by the
    ///         clock), cannot spend, and spends again once the owner rotates it to a future expiry.
    function test_InstallWithExpiredSessionThenRotate() public {
        BudgetExecutor.Policy memory p = _defaultPolicy();
        p.validUntil = uint48(block.timestamp - 1);
        AgentAccount expired =
            AgentAccount(payable(factory.createAccount(owner, abi.encode(p, _payees()), bytes32(uint256(3)))));
        _mint(address(expired), 10 * ONE);
        assertTrue(executor.isInitialized(address(expired)));
        assertEq(executor.remainingBudget(address(expired)), 0);

        BudgetExecutor.PaymentIntent memory intent = _intent(address(expired), payee, ONE, RESOURCE, keccak256("n"));
        bytes memory sig = _signIntent(sessionKey, intent);
        vm.expectRevert(abi.encodeWithSelector(BudgetExecutor.SessionExpired.selector, p.validUntil, block.timestamp));
        executor.pay(intent, sig);

        // Rotation still demands a future expiry.
        vm.expectRevert(abi.encodeWithSelector(BudgetExecutor.InvalidSessionKey.selector, session, p.validUntil));
        vm.prank(address(expired));
        executor.setSessionKey(session, p.validUntil);
        vm.prank(address(expired));
        executor.setSessionKey(session, uint48(block.timestamp + 1 hours));
        executor.pay(intent, sig);
        assertEq(token.balanceOf(payee), ONE);
    }

    function test_RevertWhen_InstallWithInvalidPayee() public {
        address[] memory bad = new address[](1);
        bad[0] = address(0);
        vm.expectRevert(abi.encodeWithSelector(BudgetExecutor.InvalidPayee.selector, address(0)));
        vm.prank(address(0xBEEF));
        executor.onInstall(abi.encode(_defaultPolicy(), bad));

        bad[0] = address(0xBEEF);
        vm.expectRevert(abi.encodeWithSelector(BudgetExecutor.InvalidPayee.selector, address(0xBEEF)));
        vm.prank(address(0xBEEF));
        executor.onInstall(abi.encode(_defaultPolicy(), bad));
    }

    // ------------------------------------------------------------------ pay: happy path

    function test_Pay() public {
        BudgetExecutor.PaymentIntent memory intent = _intent(address(account), payee, ONE, RESOURCE, keccak256("n1"));
        bytes memory sig = _signIntent(sessionKey, intent);
        bytes32 expectedId = settlement.receiptIdFor(
            address(executor), ISettlementLog.Scheme.BudgetExec, address(account), intent.nonce
        );

        vm.expectEmit(address(executor));
        emit BudgetExecutor.BudgetPayment(address(account), payee, ONE, RESOURCE, intent.nonce, expectedId, ONE);
        vm.prank(relayer);
        bytes32 receiptId = executor.pay(intent, sig);

        assertEq(receiptId, expectedId);
        assertEq(token.balanceOf(payee), ONE);
        assertEq(token.balanceOf(address(account)), 99 * ONE);
        ISettlementLog.Receipt memory r = settlement.receiptOf(receiptId);
        assertEq(r.payer, address(account));
        assertEq(r.payee, payee);
        assertEq(r.amount, ONE);
        assertEq(r.resourceHash, RESOURCE);
        assertEq(uint8(r.scheme), uint8(ISettlementLog.Scheme.BudgetExec));
        assertTrue(executor.isNonceUsed(address(account), intent.nonce));
        (uint256 spent, uint256 count) = executor.windowState(address(account));
        assertEq(spent, ONE);
        assertEq(count, 1);
        assertEq(executor.remainingBudget(address(account)), 4 * ONE);
    }

    function test_Pay_WithERC1271SessionKey() public {
        Mock1271Signer contractKey = new Mock1271Signer(session);
        _ownerExecute(
            address(executor),
            abi.encodeCall(BudgetExecutor.setSessionKey, (address(contractKey), uint48(block.timestamp + 1 days)))
        );
        BudgetExecutor.PaymentIntent memory intent = _intent(address(account), payee, ONE, RESOURCE, keccak256("n"));
        executor.pay(intent, _signIntent(sessionKey, intent));
        assertEq(token.balanceOf(payee), ONE);
    }

    // ------------------------------------------------------------------ pay: revert paths

    function test_RevertWhen_NotInstalled() public {
        BudgetExecutor.PaymentIntent memory intent = _intent(relayer, payee, ONE, RESOURCE, keccak256("n"));
        vm.expectRevert(abi.encodeWithSelector(BudgetExecutor.NotInstalled.selector, relayer));
        executor.pay(intent, "");
    }

    function test_RevertWhen_IntentNotYetValid() public {
        BudgetExecutor.PaymentIntent memory intent = _intent(address(account), payee, ONE, RESOURCE, keccak256("n"));
        intent.validAfter = block.timestamp;
        bytes memory sig = _signIntent(sessionKey, intent);
        vm.expectRevert(
            abi.encodeWithSelector(
                BudgetExecutor.IntentNotActive.selector, intent.validAfter, intent.validBefore, block.timestamp
            )
        );
        executor.pay(intent, sig);
    }

    function test_RevertWhen_IntentExpired() public {
        BudgetExecutor.PaymentIntent memory intent = _intent(address(account), payee, ONE, RESOURCE, keccak256("n"));
        bytes memory sig = _signIntent(sessionKey, intent);
        vm.warp(intent.validBefore);
        vm.expectRevert(
            abi.encodeWithSelector(
                BudgetExecutor.IntentNotActive.selector, intent.validAfter, intent.validBefore, block.timestamp
            )
        );
        executor.pay(intent, sig);
    }

    function test_RevertWhen_SessionExpired() public {
        uint48 until = executor.policyOf(address(account)).validUntil;
        vm.warp(uint256(until) + 1);
        BudgetExecutor.PaymentIntent memory intent = _intent(address(account), payee, ONE, RESOURCE, keccak256("n"));
        bytes memory sig = _signIntent(sessionKey, intent);
        vm.expectRevert(abi.encodeWithSelector(BudgetExecutor.SessionExpired.selector, until, block.timestamp));
        executor.pay(intent, sig);
    }

    function test_PayAtExactSessionExpiry() public {
        vm.warp(executor.policyOf(address(account)).validUntil);
        _pay(address(account), payee, ONE, keccak256("n"));
        assertEq(token.balanceOf(payee), ONE);
    }

    function test_RevertWhen_AmountAboveCapOrZero() public {
        BudgetExecutor.PaymentIntent memory intent = _intent(address(account), payee, ONE + 1, RESOURCE, keccak256("n"));
        bytes memory sig = _signIntent(sessionKey, intent);
        vm.expectRevert(abi.encodeWithSelector(BudgetExecutor.PerCallCapExceeded.selector, ONE + 1, uint128(ONE)));
        executor.pay(intent, sig);

        intent.amount = 0;
        sig = _signIntent(sessionKey, intent);
        vm.expectRevert(abi.encodeWithSelector(BudgetExecutor.PerCallCapExceeded.selector, 0, uint128(ONE)));
        executor.pay(intent, sig);
    }

    function test_RevertWhen_PayeeNotAllowed() public {
        BudgetExecutor.PaymentIntent memory intent = _intent(address(account), relayer, ONE, RESOURCE, keccak256("n"));
        bytes memory sig = _signIntent(sessionKey, intent);
        vm.expectRevert(abi.encodeWithSelector(BudgetExecutor.PayeeNotAllowed.selector, relayer));
        executor.pay(intent, sig);
    }

    function test_RevertWhen_NonceReplayed() public {
        BudgetExecutor.PaymentIntent memory intent = _intent(address(account), payee, ONE, RESOURCE, keccak256("n"));
        bytes memory sig = _signIntent(sessionKey, intent);
        executor.pay(intent, sig);
        vm.expectRevert(
            abi.encodeWithSelector(BudgetExecutor.NonceAlreadyUsed.selector, address(account), intent.nonce)
        );
        executor.pay(intent, sig);
    }

    function test_RevertWhen_SignedByWrongKey() public {
        BudgetExecutor.PaymentIntent memory intent = _intent(address(account), payee, ONE, RESOURCE, keccak256("n"));
        bytes memory sig = _signIntent(ownerKey, intent);
        vm.expectRevert(abi.encodeWithSelector(BudgetExecutor.InvalidSessionSignature.selector, session));
        executor.pay(intent, sig);
    }

    function test_RevertWhen_RelayerTampersAmountPayeeOrResource() public {
        BudgetExecutor.PaymentIntent memory intent = _intent(address(account), payee, ONE / 2, RESOURCE, keccak256("n"));
        bytes memory sig = _signIntent(sessionKey, intent);

        BudgetExecutor.PaymentIntent memory tampered = intent;
        tampered.amount = ONE;
        vm.expectRevert(abi.encodeWithSelector(BudgetExecutor.InvalidSessionSignature.selector, session));
        executor.pay(tampered, sig);

        tampered = _intent(address(account), otherPayee, ONE / 2, RESOURCE, keccak256("n"));
        vm.expectRevert(abi.encodeWithSelector(BudgetExecutor.InvalidSessionSignature.selector, session));
        executor.pay(tampered, sig);

        tampered = _intent(address(account), payee, ONE / 2, OTHER_RESOURCE, keccak256("n"));
        vm.expectRevert(abi.encodeWithSelector(BudgetExecutor.InvalidSessionSignature.selector, session));
        executor.pay(tampered, sig);

        assertEq(token.balanceOf(payee) + token.balanceOf(otherPayee), 0);
    }

    function test_RevertWhen_IntentReplayedOnAnotherAccount() public {
        AgentAccount second = AgentAccount(
            payable(factory.createAccount(owner, abi.encode(_defaultPolicy(), _payees()), bytes32(uint256(1))))
        );
        _mint(address(second), 10 * ONE);
        BudgetExecutor.PaymentIntent memory intent = _intent(address(account), payee, ONE, RESOURCE, keccak256("n"));
        bytes memory sig = _signIntent(sessionKey, intent);
        intent.account = address(second);
        vm.expectRevert(abi.encodeWithSelector(BudgetExecutor.InvalidSessionSignature.selector, session));
        executor.pay(intent, sig);
    }

    function test_RevertWhen_BudgetExhausted() public {
        for (uint256 i = 0; i < 5; ++i) {
            _pay(address(account), payee, ONE, bytes32(i + 1));
        }
        assertEq(executor.remainingBudget(address(account)), 0);
        BudgetExecutor.PaymentIntent memory intent = _intent(address(account), payee, 1, RESOURCE, bytes32(uint256(99)));
        bytes memory sig = _signIntent(sessionKey, intent);
        vm.expectRevert(abi.encodeWithSelector(BudgetExecutor.BudgetExceeded.selector, 5 * ONE, 1, uint128(5 * ONE)));
        executor.pay(intent, sig);
    }

    function test_BudgetRollsOverAfterPeriod() public {
        for (uint256 i = 0; i < 5; ++i) {
            vm.warp(block.timestamp + 10 minutes);
            _pay(address(account), payee, ONE, bytes32(i + 1));
        }
        // First payment was at T0+10m; it leaves the window at T0+70m. The last four are still inside.
        vm.warp(T0 + 70 minutes - 1);
        (uint256 spent,) = executor.windowState(address(account));
        assertEq(spent, 5 * ONE);
        vm.warp(T0 + 70 minutes);
        (spent,) = executor.windowState(address(account));
        assertEq(spent, 4 * ONE);
        _pay(address(account), payee, ONE, bytes32(uint256(6)));
        (spent,) = executor.windowState(address(account));
        assertEq(spent, 5 * ONE);
    }

    function test_RevertWhen_RateLimited() public {
        _ownerExecute(
            address(executor), abi.encodeCall(BudgetExecutor.setLimits, (uint128(ONE), uint128(5 * ONE), 1 hours, 2))
        );
        _pay(address(account), payee, 1, bytes32(uint256(1)));
        _pay(address(account), payee, 1, bytes32(uint256(2)));
        BudgetExecutor.PaymentIntent memory intent = _intent(address(account), payee, 1, RESOURCE, bytes32(uint256(3)));
        bytes memory sig = _signIntent(sessionKey, intent);
        vm.expectRevert(abi.encodeWithSelector(BudgetExecutor.RateLimited.selector, 2, uint16(2)));
        executor.pay(intent, sig);
        assertEq(executor.remainingBudget(address(account)), 0);
        vm.warp(block.timestamp + 1 hours);
        _pay(address(account), payee, 1, bytes32(uint256(3)));
        assertEq(token.balanceOf(payee), 3);
    }

    function test_RevertWhen_AccountCannotCoverPayment() public {
        AgentAccount poor = AgentAccount(
            payable(factory.createAccount(owner, abi.encode(_defaultPolicy(), _payees()), bytes32(uint256(7))))
        );
        BudgetExecutor.PaymentIntent memory intent = _intent(address(poor), payee, ONE, RESOURCE, keccak256("n"));
        bytes memory sig = _signIntent(sessionKey, intent);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(poor), 0, ONE));
        executor.pay(intent, sig);
    }

    function test_RevertWhen_ModuleUninstalled_PolicyClearedByOnUninstall() public {
        // Uninstalling through the account calls onUninstall, which deletes the policy: the executor refuses first.
        vm.prank(owner);
        account.uninstallModule(MODULE_TYPE_EXECUTOR, address(executor), "");
        assertFalse(executor.isInitialized(address(account)));
        BudgetExecutor.PaymentIntent memory intent = _intent(address(account), payee, ONE, RESOURCE, keccak256("n"));
        bytes memory sig = _signIntent(sessionKey, intent);
        vm.expectRevert(abi.encodeWithSelector(BudgetExecutor.NotInstalled.selector, address(account)));
        executor.pay(intent, sig);
    }

    function test_RevertWhen_PolicyPresentButModuleNotInstalledInAccount() public {
        // The owner drops the module, then writes a policy into the executor directly (a call to onInstall that
        // does not go through installModule). The executor now has a policy, but the account itself rejects
        // executeFromExecutor from a module it does not list, so nothing can be charged.
        vm.prank(owner);
        account.uninstallModule(MODULE_TYPE_EXECUTOR, address(executor), "");
        _ownerExecute(
            address(executor), abi.encodeCall(BudgetExecutor.onInstall, (abi.encode(_defaultPolicy(), _payees())))
        );
        assertTrue(executor.isInitialized(address(account)));
        assertFalse(account.isModuleInstalled(MODULE_TYPE_EXECUTOR, address(executor), ""));

        BudgetExecutor.PaymentIntent memory intent = _intent(address(account), payee, ONE, RESOURCE, keccak256("n"));
        bytes memory sig = _signIntent(sessionKey, intent);
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC7579Utils.ERC7579UninstalledModule.selector, MODULE_TYPE_EXECUTOR, address(executor)
            )
        );
        executor.pay(intent, sig);
        assertEq(token.balanceOf(payee), 0);
    }

    // ------------------------------------------------------------------ administration

    function test_SetLimits() public {
        vm.expectEmit(address(executor));
        emit BudgetExecutor.LimitsUpdated(address(account), uint128(2 * ONE), uint128(3 * ONE), 2 hours, 4);
        _ownerExecute(
            address(executor),
            abi.encodeCall(BudgetExecutor.setLimits, (uint128(2 * ONE), uint128(3 * ONE), 2 hours, 4))
        );
        BudgetExecutor.Policy memory p = executor.policyOf(address(account));
        assertEq(p.perCallCap, 2 * ONE);
        assertEq(p.periodBudget, 3 * ONE);
        assertEq(p.period, 2 hours);
        assertEq(p.maxPaymentsPerPeriod, 4);
    }

    function test_LoweringBudgetTakesEffectImmediately() public {
        _pay(address(account), payee, ONE, bytes32(uint256(1)));
        _pay(address(account), payee, ONE, bytes32(uint256(2)));
        vm.prank(address(account));
        executor.setLimits(uint128(ONE), uint128(2 * ONE), 1 hours, 16);
        assertEq(executor.remainingBudget(address(account)), 0);
        BudgetExecutor.PaymentIntent memory intent = _intent(address(account), payee, 1, RESOURCE, bytes32(uint256(3)));
        bytes memory sig = _signIntent(sessionKey, intent);
        vm.expectRevert(abi.encodeWithSelector(BudgetExecutor.BudgetExceeded.selector, 2 * ONE, 1, uint128(2 * ONE)));
        executor.pay(intent, sig);
    }

    function test_RevertWhen_AdminCalledByNonInstalledAccount() public {
        vm.startPrank(relayer);
        vm.expectRevert(abi.encodeWithSelector(BudgetExecutor.NotInstalled.selector, relayer));
        executor.setLimits(1, 1, 1 hours, 1);
        vm.expectRevert(abi.encodeWithSelector(BudgetExecutor.NotInstalled.selector, relayer));
        executor.setSessionKey(session, uint48(block.timestamp + 1));
        vm.expectRevert(abi.encodeWithSelector(BudgetExecutor.NotInstalled.selector, relayer));
        executor.revokeSession();
        vm.expectRevert(abi.encodeWithSelector(BudgetExecutor.NotInstalled.selector, relayer));
        executor.setPayee(payee, true);
        vm.expectRevert(abi.encodeWithSelector(BudgetExecutor.NotInstalled.selector, relayer));
        executor.onUninstall("");
        vm.stopPrank();
    }

    function test_RevertWhen_SetLimitsInvalid() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                BudgetExecutor.InvalidLimits.selector, uint128(0), uint128(1), uint32(1 hours), uint16(1)
            )
        );
        vm.prank(address(account));
        executor.setLimits(0, 1, 1 hours, 1);
    }

    function test_RotateAndRevokeSessionKey() public {
        (address newSession, uint256 newKey) = makeAddrAndKey("newSession");
        vm.prank(address(account));
        executor.setSessionKey(newSession, uint48(block.timestamp + 1 hours));

        BudgetExecutor.PaymentIntent memory intent = _intent(address(account), payee, ONE, RESOURCE, keccak256("n"));
        bytes memory oldSig = _signIntent(sessionKey, intent);
        vm.expectRevert(abi.encodeWithSelector(BudgetExecutor.InvalidSessionSignature.selector, newSession));
        executor.pay(intent, oldSig);
        executor.pay(intent, _signIntent(newKey, intent));

        vm.expectEmit(address(executor));
        emit BudgetExecutor.SessionKeyUpdated(address(account), newSession, 0);
        vm.prank(address(account));
        executor.revokeSession();
        assertEq(executor.remainingBudget(address(account)), 0);
        BudgetExecutor.PaymentIntent memory next = _intent(address(account), payee, ONE, RESOURCE, keccak256("m"));
        bytes memory sig = _signIntent(newKey, next);
        vm.expectRevert(abi.encodeWithSelector(BudgetExecutor.SessionExpired.selector, uint48(0), block.timestamp));
        executor.pay(next, sig);

        vm.expectRevert(
            abi.encodeWithSelector(
                BudgetExecutor.InvalidSessionKey.selector, address(account), uint48(block.timestamp + 1)
            )
        );
        vm.prank(address(account));
        executor.setSessionKey(address(account), uint48(block.timestamp + 1));
    }

    function test_SetPayee() public {
        vm.prank(address(account));
        executor.setPayee(payee, false);
        assertFalse(executor.isPayeeAllowed(address(account), payee));
        vm.expectRevert(abi.encodeWithSelector(BudgetExecutor.InvalidPayee.selector, address(account)));
        vm.prank(address(account));
        executor.setPayee(address(account), true);
    }

    function test_ReinstallResetsAllowlistButKeepsNonces() public {
        _pay(address(account), payee, ONE, keccak256("n"));
        vm.startPrank(owner);
        account.uninstallModule(MODULE_TYPE_EXECUTOR, address(executor), "");
        address[] memory onlyOther = new address[](1);
        onlyOther[0] = otherPayee;
        account.installModule(MODULE_TYPE_EXECUTOR, address(executor), abi.encode(_defaultPolicy(), onlyOther));
        vm.stopPrank();

        assertFalse(executor.isPayeeAllowed(address(account), payee), "old allowlist ignored");
        assertTrue(executor.isPayeeAllowed(address(account), otherPayee));
        (uint256 spent, uint256 count) = executor.windowState(address(account));
        assertEq(spent + count, 0, "window reset");

        BudgetExecutor.PaymentIntent memory intent =
            _intent(address(account), otherPayee, ONE, RESOURCE, keccak256("n"));
        bytes memory sig = _signIntent(sessionKey, intent);
        vm.expectRevert(
            abi.encodeWithSelector(BudgetExecutor.NonceAlreadyUsed.selector, address(account), keccak256("n"))
        );
        executor.pay(intent, sig);
    }

    // ------------------------------------------------------------------ fuzz

    /// @notice The per-call cap is enforced for every amount.
    function testFuzz_PerCallCap(uint256 amount) public {
        amount = bound(amount, 0, 10 * ONE);
        BudgetExecutor.PaymentIntent memory intent = _intent(address(account), payee, amount, RESOURCE, keccak256("n"));
        bytes memory sig = _signIntent(sessionKey, intent);
        if (amount == 0 || amount > ONE) {
            vm.expectRevert(abi.encodeWithSelector(BudgetExecutor.PerCallCapExceeded.selector, amount, uint128(ONE)));
        }
        executor.pay(intent, sig);
        assertEq(token.balanceOf(payee), amount == 0 || amount > ONE ? 0 : amount);
    }

    /// @notice A signature over one intent never authorizes a different amount, payee or resource.
    function testFuzz_SignatureBindsIntent(uint256 amount, uint256 otherAmount, bytes32 otherResource) public {
        amount = bound(amount, 1, ONE);
        otherAmount = bound(otherAmount, 1, ONE);
        BudgetExecutor.PaymentIntent memory intent = _intent(address(account), payee, amount, RESOURCE, keccak256("n"));
        bytes memory sig = _signIntent(sessionKey, intent);
        BudgetExecutor.PaymentIntent memory tampered =
            _intent(address(account), payee, otherAmount, otherResource, keccak256("n"));
        if (otherAmount != amount || otherResource != RESOURCE) {
            vm.expectRevert(abi.encodeWithSelector(BudgetExecutor.InvalidSessionSignature.selector, session));
            executor.pay(tampered, sig);
            assertEq(token.balanceOf(payee), 0);
        }
    }

    // ------------------------------------------------------------------ helpers

    function _ownerExecute(address target, bytes memory data) internal {
        vm.prank(owner);
        account.execute(bytes32(0), abi.encodePacked(target, uint256(0), data));
    }

    function _expectInvalidLimits(BudgetExecutor.Policy memory p) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                BudgetExecutor.InvalidLimits.selector, p.perCallCap, p.periodBudget, p.period, p.maxPaymentsPerPeriod
            )
        );
        vm.prank(address(0xBEEF));
        executor.onInstall(abi.encode(p, _payees()));
    }

    function _expectInvalidSession(BudgetExecutor.Policy memory p, address acct) internal {
        vm.expectRevert(abi.encodeWithSelector(BudgetExecutor.InvalidSessionKey.selector, p.sessionKey, p.validUntil));
        vm.prank(acct);
        executor.onInstall(abi.encode(p, _payees()));
    }
}
