// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ISettlementLog} from "../interfaces/ISettlementLog.sol";
import {
    ERC7579Utils,
    Mode,
    ModePayload,
    ModeSelector
} from "@openzeppelin/contracts/account/utils/draft-ERC7579Utils.sol";
import {
    IERC7579Execution,
    IERC7579Module,
    MODULE_TYPE_EXECUTOR
} from "@openzeppelin/contracts/interfaces/draft-IERC7579.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

/// @title BudgetExecutor
/// @notice ERC-7579 executor module (type 2) that lets an agent's session key spend the account's settlement asset
///         under an on-chain policy: per-call cap, rolling-window budget, payment-rate limit, payee allowlist and
///         session expiry. Each payment is an EIP-712 `PaymentIntent` signed by the session key and bound to the
///         account, payee, amount and x402 resource. Anyone may relay an intent (the x402 facilitator does), but
///         nobody can alter it.
/// @dev Rolling window. The module keeps, per account, a ring buffer of the payments that may still be inside the
///      current window, plus their running sum. On every payment it first drops entries older than `period`, then
///      checks `spent + amount <= periodBudget` and `count < maxPaymentsPerPeriod`, then appends. Each entry is
///      written once and expired once, so the cost is amortised O(1) storage reads per payment. This enforces the
///      exact sliding-window property: for every `t`, the payments with timestamps in `(t - period, t]` sum to at
///      most `periodBudget` (see `test/invariant/BudgetWindow.invariant.t.sol`). The guarantee is stated for
///      intervals during which the account does not change its own limits.
///
///      The module only ever asks the account for a single `CALL` to `asset.transfer(payee, amount)`. It never
///      requests delegatecall or batch mode, and the paired {AgentAccount} rejects delegatecall mode entirely.
contract BudgetExecutor is IERC7579Module, EIP712, ReentrancyGuardTransient {
    /// @notice Spending policy of one account. Packed into two storage slots.
    /// @param sessionKey Key (EOA or ERC-1271 contract) that signs payment intents.
    /// @param validUntil The session can spend up to and including this timestamp.
    /// @param period Rolling window length in seconds.
    /// @param maxPaymentsPerPeriod Maximum number of payments inside any window (1..{RING_CAPACITY}).
    /// @param perCallCap Maximum amount of a single payment.
    /// @param periodBudget Maximum sum of payments inside any window.
    struct Policy {
        address sessionKey;
        uint48 validUntil;
        uint32 period;
        uint16 maxPaymentsPerPeriod;
        uint128 perCallCap;
        uint128 periodBudget;
    }

    /// @notice A payment the session key authorizes. EIP-712 typed data.
    /// @param account Smart account that pays.
    /// @param payee Recipient (x402 `payTo`); must be allowlisted.
    /// @param amount Amount in asset base units.
    /// @param resourceHash keccak256 of the canonical x402 resource string.
    /// @param nonce Random 32-byte value, single use per account.
    /// @param validAfter Valid strictly after this timestamp.
    /// @param validBefore Valid strictly before this timestamp.
    struct PaymentIntent {
        address account;
        address payee;
        uint256 amount;
        bytes32 resourceHash;
        bytes32 nonce;
        uint256 validAfter;
        uint256 validBefore;
    }

    /// @dev One ring-buffer entry.
    struct Spend {
        uint64 timestamp;
        uint128 amount;
    }

    /// @dev Sliding-window accounting. `head` is the next write position; the live entries are the `count` slots
    ///      before it. `generation` increments on every install so stale allowlist entries are ignored.
    struct Window {
        uint128 spent;
        uint16 count;
        uint16 head;
        uint64 generation;
    }

    /// @notice Capacity of the per-account ring buffer, and upper bound of `maxPaymentsPerPeriod`.
    uint256 public constant RING_CAPACITY = 32;

    /// @notice Shortest allowed window.
    uint32 public constant MIN_PERIOD = 60;

    /// @notice Longest allowed window.
    uint32 public constant MAX_PERIOD = 365 days;

    /// @notice EIP-712 type hash of {PaymentIntent}.
    bytes32 public constant PAYMENT_INTENT_TYPEHASH = keccak256(
        "PaymentIntent(address account,address payee,uint256 amount,bytes32 resourceHash,bytes32 nonce,uint256 validAfter,uint256 validBefore)"
    );

    /// @notice Receipt registry this module reports to (it must be an allowed recorder there).
    ISettlementLog public immutable SETTLEMENT_LOG;

    /// @notice The only token this module moves (the settlement log's asset).
    IERC20 public immutable ASSET;

    /// @dev Policy per account; `sessionKey == address(0)` means not installed.
    mapping(address account => Policy) private _policies;

    /// @dev Window accounting per account.
    mapping(address account => Window) private _windows;

    /// @dev Ring buffer per account. Written through a storage pointer in {_consumeBudget}.
    // slither-disable-next-line uninitialized-state
    mapping(address account => Spend[RING_CAPACITY]) private _ring;

    /// @dev Payee allowlist per account and install generation.
    mapping(address account => mapping(uint64 generation => mapping(address payee => bool))) private _allowedPayees;

    /// @dev Consumed intent nonces. Never cleared, so an intent cannot be replayed after a reinstall.
    mapping(address account => mapping(bytes32 nonce => bool)) private _usedNonces;

    /// @notice Emitted when an account installs the module.
    /// @param account The smart account.
    /// @param sessionKey Session key allowed to sign intents.
    /// @param validUntil Session expiry.
    /// @param generation Install generation.
    event PolicyInstalled(address indexed account, address indexed sessionKey, uint48 validUntil, uint64 generation);

    /// @notice Emitted when an account uninstalls the module.
    /// @param account The smart account.
    event PolicyUninstalled(address indexed account);

    /// @notice Emitted when an account changes its limits (also on install).
    /// @param account The smart account.
    /// @param perCallCap New per-call cap.
    /// @param periodBudget New per-window budget.
    /// @param period New window length.
    /// @param maxPaymentsPerPeriod New per-window payment count limit.
    event LimitsUpdated(
        address indexed account, uint128 perCallCap, uint128 periodBudget, uint32 period, uint16 maxPaymentsPerPeriod
    );

    /// @notice Emitted when an account rotates or revokes its session key.
    /// @param account The smart account.
    /// @param sessionKey New session key.
    /// @param validUntil New expiry (0 = revoked).
    event SessionKeyUpdated(address indexed account, address indexed sessionKey, uint48 validUntil);

    /// @notice Emitted when an account edits its payee allowlist (also on install).
    /// @param account The smart account.
    /// @param payee The payee.
    /// @param allowed Whether the session may pay it.
    event PayeeSet(address indexed account, address indexed payee, bool allowed);

    /// @notice Emitted for every executed payment.
    /// @param account Paying smart account.
    /// @param payee Recipient.
    /// @param amount Amount paid.
    /// @param resourceHash Resource the intent was bound to.
    /// @param nonce Intent nonce.
    /// @param receiptId Receipt recorded in the settlement log.
    /// @param spentInWindow Window total after this payment.
    event BudgetPayment(
        address indexed account,
        address indexed payee,
        uint256 amount,
        bytes32 resourceHash,
        bytes32 nonce,
        bytes32 indexed receiptId,
        uint256 spentInWindow
    );

    /// @notice The account has no active policy.
    /// @param account The account.
    error NotInstalled(address account);

    /// @notice The account already has a policy.
    /// @param account The account.
    error AlreadyInstalled(address account);

    /// @notice Limits are inconsistent or out of range.
    /// @param perCallCap Proposed per-call cap.
    /// @param periodBudget Proposed budget.
    /// @param period Proposed window length.
    /// @param maxPaymentsPerPeriod Proposed count limit.
    error InvalidLimits(uint128 perCallCap, uint128 periodBudget, uint32 period, uint16 maxPaymentsPerPeriod);

    /// @notice Session key is zero or the account itself, or a rotation sets an expiry that is not in the future.
    /// @param sessionKey Proposed key.
    /// @param validUntil Proposed expiry.
    error InvalidSessionKey(address sessionKey, uint48 validUntil);

    /// @notice Payee is zero or the account itself.
    /// @param payee Proposed payee.
    error InvalidPayee(address payee);

    /// @notice The intent's validity window does not contain the current time.
    /// @param validAfter Intent lower bound (exclusive).
    /// @param validBefore Intent upper bound (exclusive).
    /// @param nowTs Current block timestamp.
    error IntentNotActive(uint256 validAfter, uint256 validBefore, uint256 nowTs);

    /// @notice The session key has expired or was revoked.
    /// @param validUntil Session expiry.
    /// @param nowTs Current block timestamp.
    error SessionExpired(uint48 validUntil, uint256 nowTs);

    /// @notice Amount is zero or above the per-call cap.
    /// @param amount Requested amount.
    /// @param perCallCap Cap.
    error PerCallCapExceeded(uint256 amount, uint128 perCallCap);

    /// @notice Payee is not on the account's allowlist.
    /// @param payee The payee.
    error PayeeNotAllowed(address payee);

    /// @notice Intent nonce already consumed.
    /// @param account The account.
    /// @param nonce The nonce.
    error NonceAlreadyUsed(address account, bytes32 nonce);

    /// @notice Signature is not a valid session-key signature over the intent.
    /// @param sessionKey The expected signer.
    error InvalidSessionSignature(address sessionKey);

    /// @notice The payment would push the rolling-window total above the budget.
    /// @param spentInWindow Amount already spent in the current window.
    /// @param amount Requested amount.
    /// @param periodBudget The budget.
    error BudgetExceeded(uint256 spentInWindow, uint256 amount, uint128 periodBudget);

    /// @notice The rolling window already contains the maximum number of payments.
    /// @param paymentsInWindow Payments in the current window.
    /// @param maxPaymentsPerPeriod The limit.
    error RateLimited(uint256 paymentsInWindow, uint16 maxPaymentsPerPeriod);

    /// @notice The account's token transfer did not deliver exactly `expected` to the payee.
    /// @param expected Intended amount.
    /// @param received Observed payee balance delta.
    error TransferFailed(uint256 expected, uint256 received);

    /// @param settlementLog_ Receipt registry; its asset becomes this module's asset.
    constructor(ISettlementLog settlementLog_) EIP712("BudgetExecutor", "1") {
        SETTLEMENT_LOG = settlementLog_;
        ASSET = IERC20(settlementLog_.asset());
    }

    // ---------------------------------------------------------------------------------------------------------------
    // ERC-7579 module lifecycle (msg.sender is the account)
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Installs a policy for the calling account. `validUntil` may already be in the past (the session is
    ///         then installed but cannot spend until rotated).
    /// @param data `abi.encode(Policy policy, address[] payees)`.
    function onInstall(bytes calldata data) external {
        address account = msg.sender;
        require(_policies[account].sessionKey == address(0), AlreadyInstalled(account));
        (Policy memory policy, address[] memory payees) = abi.decode(data, (Policy, address[]));
        _checkLimits(policy.perCallCap, policy.periodBudget, policy.period, policy.maxPaymentsPerPeriod);
        // The expiry is deliberately not checked here: the install payload is part of the factory's CREATE2 salt, so
        // rejecting an expired session would make a funded counterfactual address undeployable forever. An expired
        // session simply cannot spend ({pay} checks `validUntil`) until the owner rotates it with {setSessionKey}.
        _checkSessionKey(account, policy.sessionKey, policy.validUntil, false);

        uint64 generation = _windows[account].generation + 1;
        _windows[account] = Window({spent: 0, count: 0, head: 0, generation: generation});
        _policies[account] = policy;
        emit PolicyInstalled(account, policy.sessionKey, policy.validUntil, generation);
        emit LimitsUpdated(account, policy.perCallCap, policy.periodBudget, policy.period, policy.maxPaymentsPerPeriod);
        for (uint256 i = 0; i < payees.length; ++i) {
            _setPayee(account, generation, payees[i], true);
        }
    }

    /// @notice Removes the calling account's policy. Used nonces are kept.
    function onUninstall(bytes calldata) external {
        address account = msg.sender;
        require(_policies[account].sessionKey != address(0), NotInstalled(account));
        delete _policies[account];
        _windows[account] = Window({spent: 0, count: 0, head: 0, generation: _windows[account].generation});
        emit PolicyUninstalled(account);
    }

    /// @notice This module is an executor (type 2) only.
    /// @param moduleTypeId ERC-7579 module type id.
    /// @return True iff `moduleTypeId == MODULE_TYPE_EXECUTOR`.
    function isModuleType(uint256 moduleTypeId) external pure returns (bool) {
        return moduleTypeId == MODULE_TYPE_EXECUTOR;
    }

    /// @notice Whether `account` has an active policy.
    /// @param account The smart account.
    /// @return True if installed.
    function isInitialized(address account) external view returns (bool) {
        return _policies[account].sessionKey != address(0);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Policy administration (msg.sender is the account, i.e. its owner acting through `execute`)
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Replaces the calling account's limits. Takes effect immediately.
    /// @param perCallCap New per-call cap (> 0, <= periodBudget).
    /// @param periodBudget New per-window budget.
    /// @param period New window length in seconds.
    /// @param maxPaymentsPerPeriod New per-window count limit (1..RING_CAPACITY).
    function setLimits(uint128 perCallCap, uint128 periodBudget, uint32 period, uint16 maxPaymentsPerPeriod) external {
        Policy storage policy = _installedPolicy(msg.sender);
        _checkLimits(perCallCap, periodBudget, period, maxPaymentsPerPeriod);
        policy.perCallCap = perCallCap;
        policy.periodBudget = periodBudget;
        policy.period = period;
        policy.maxPaymentsPerPeriod = maxPaymentsPerPeriod;
        emit LimitsUpdated(msg.sender, perCallCap, periodBudget, period, maxPaymentsPerPeriod);
    }

    /// @notice Rotates the session key and/or its expiry.
    /// @param sessionKey New session key.
    /// @param validUntil New expiry (must be in the future).
    function setSessionKey(address sessionKey, uint48 validUntil) external {
        Policy storage policy = _installedPolicy(msg.sender);
        _checkSessionKey(msg.sender, sessionKey, validUntil, true);
        policy.sessionKey = sessionKey;
        policy.validUntil = validUntil;
        emit SessionKeyUpdated(msg.sender, sessionKey, validUntil);
    }

    /// @notice Immediately stops the session key from spending (expiry set to 0). The policy stays installed.
    function revokeSession() external {
        Policy storage policy = _installedPolicy(msg.sender);
        policy.validUntil = 0;
        emit SessionKeyUpdated(msg.sender, policy.sessionKey, 0);
    }

    /// @notice Adds or removes a payee from the calling account's allowlist.
    /// @param payee The payee.
    /// @param allowed Whether the session may pay it.
    function setPayee(address payee, bool allowed) external {
        _installedPolicy(msg.sender);
        _setPayee(msg.sender, _windows[msg.sender].generation, payee, allowed);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Payments
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Executes a session-key-signed payment from `intent.account` to `intent.payee`. Callable by anyone.
    /// @param intent The signed payment intent.
    /// @param signature Session-key signature over the EIP-712 digest of `intent`.
    /// @return receiptId Receipt id in the settlement log.
    function pay(PaymentIntent calldata intent, bytes calldata signature)
        external
        nonReentrant
        returns (bytes32 receiptId)
    {
        address account = intent.account;
        Policy memory policy = _policies[account];
        require(policy.sessionKey != address(0), NotInstalled(account));
        require(
            block.timestamp > intent.validAfter && block.timestamp < intent.validBefore,
            IntentNotActive(intent.validAfter, intent.validBefore, block.timestamp)
        );
        require(block.timestamp <= policy.validUntil, SessionExpired(policy.validUntil, block.timestamp));
        require(
            intent.amount != 0 && intent.amount <= policy.perCallCap,
            PerCallCapExceeded(intent.amount, policy.perCallCap)
        );
        require(_allowedPayees[account][_windows[account].generation][intent.payee], PayeeNotAllowed(intent.payee));
        require(!_usedNonces[account][intent.nonce], NonceAlreadyUsed(account, intent.nonce));
        require(
            SignatureChecker.isValidSignatureNow(policy.sessionKey, hashPaymentIntent(intent), signature),
            InvalidSessionSignature(policy.sessionKey)
        );

        // Effects: consume the nonce and the budget before calling out.
        _usedNonces[account][intent.nonce] = true;
        uint256 spentInWindow = _consumeBudget(account, policy, intent.amount);

        // Interaction: the account performs a single CALL to asset.transfer(payee, amount).
        uint256 payeeBalanceBefore = ASSET.balanceOf(intent.payee);
        bytes[] memory returnData = IERC7579Execution(account)
            .executeFromExecutor(
                Mode.unwrap(
                    ERC7579Utils.encodeMode(
                        ERC7579Utils.CALLTYPE_SINGLE,
                        ERC7579Utils.EXECTYPE_DEFAULT,
                        ModeSelector.wrap(0),
                        ModePayload.wrap(0)
                    )
                ),
                abi.encodePacked(
                    address(ASSET), uint256(0), abi.encodeCall(IERC20.transfer, (intent.payee, intent.amount))
                )
            );
        _checkTransfer(returnData, intent.payee, payeeBalanceBefore, intent.amount);

        receiptId = SETTLEMENT_LOG.recordReceipt(
            ISettlementLog.Scheme.BudgetExec, account, intent.payee, intent.amount, intent.resourceHash, intent.nonce
        );
        emit BudgetPayment(
            account, intent.payee, intent.amount, intent.resourceHash, intent.nonce, receiptId, spentInWindow
        );
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice EIP-712 digest the session key signs for `intent`.
    /// @param intent The payment intent.
    /// @return The typed-data digest.
    function hashPaymentIntent(PaymentIntent calldata intent) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    PAYMENT_INTENT_TYPEHASH,
                    intent.account,
                    intent.payee,
                    intent.amount,
                    intent.resourceHash,
                    intent.nonce,
                    intent.validAfter,
                    intent.validBefore
                )
            )
        );
    }

    /// @notice The policy of `account` (all zero if not installed).
    /// @param account The smart account.
    /// @return The policy.
    function policyOf(address account) external view returns (Policy memory) {
        return _policies[account];
    }

    /// @notice Spend and payment count inside the window that ends now.
    /// @param account The smart account.
    /// @return spent Sum of payments with timestamp in `(now - period, now]`.
    /// @return count Number of such payments.
    function windowState(address account) public view returns (uint256 spent, uint256 count) {
        Window memory w = _windows[account];
        uint32 period = _policies[account].period;
        spent = w.spent;
        count = w.count;
        Spend[RING_CAPACITY] storage ring = _ring[account];
        while (count != 0) {
            Spend memory oldest = ring[(w.head + RING_CAPACITY - count) % RING_CAPACITY];
            if (uint256(oldest.timestamp) + period > block.timestamp) break;
            spent -= oldest.amount;
            --count;
        }
    }

    /// @notice How much the session could still spend right now (0 when expired, revoked or not installed).
    /// @param account The smart account.
    /// @return The remaining budget of the current window, ignoring the per-call cap.
    function remainingBudget(address account) external view returns (uint256) {
        Policy memory policy = _policies[account];
        if (policy.sessionKey == address(0) || block.timestamp > policy.validUntil) return 0;
        (uint256 spent, uint256 count) = windowState(account);
        if (count >= policy.maxPaymentsPerPeriod || spent >= policy.periodBudget) return 0;
        return policy.periodBudget - spent;
    }

    /// @notice Whether the session of `account` may pay `payee`.
    /// @param account The smart account.
    /// @param payee The payee.
    /// @return True if allowlisted in the current install generation.
    function isPayeeAllowed(address account, address payee) external view returns (bool) {
        return _allowedPayees[account][_windows[account].generation][payee];
    }

    /// @notice Whether an intent nonce has been consumed.
    /// @param account The smart account.
    /// @param nonce The intent nonce.
    /// @return True if used.
    function isNonceUsed(address account, bytes32 nonce) external view returns (bool) {
        return _usedNonces[account][nonce];
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Expires old entries, checks count and budget, appends the new spend. Returns the new window total.
    function _consumeBudget(address account, Policy memory policy, uint256 amount) private returns (uint256) {
        Window memory w = _windows[account];
        Spend[RING_CAPACITY] storage ring = _ring[account];
        uint256 spent = w.spent;
        uint256 count = w.count;
        uint256 head = w.head;

        while (count != 0) {
            Spend memory oldest = ring[(head + RING_CAPACITY - count) % RING_CAPACITY];
            if (uint256(oldest.timestamp) + policy.period > block.timestamp) break;
            spent -= oldest.amount;
            --count;
        }
        require(count < policy.maxPaymentsPerPeriod, RateLimited(count, policy.maxPaymentsPerPeriod));
        require(spent + amount <= policy.periodBudget, BudgetExceeded(spent, amount, policy.periodBudget));

        // `count < maxPaymentsPerPeriod <= RING_CAPACITY`, so `head` is never a live slot.
        // Casts are safe: amount <= perCallCap <= type(uint128).max, timestamps fit in 64 bits for ~5e11 years,
        // spent <= periodBudget <= type(uint128).max, count <= RING_CAPACITY and head < RING_CAPACITY.
        // forge-lint: disable-next-line(unsafe-typecast)
        ring[head] = Spend({timestamp: uint64(block.timestamp), amount: uint128(amount)});
        spent += amount;
        // forge-lint: disable-next-item(unsafe-typecast)
        _windows[account] = Window({
            spent: uint128(spent),
            count: uint16(count + 1),
            head: uint16((head + 1) % RING_CAPACITY),
            generation: w.generation
        });
        return spent;
    }

    /// @dev SafeERC20-equivalent check on the account's call result, plus an exact balance-delta check.
    function _checkTransfer(bytes[] memory returnData, address payee, uint256 balanceBefore, uint256 amount)
        private
        view
    {
        bytes memory ret = returnData[0];
        bool ok = ret.length == 0 ? address(ASSET).code.length != 0 : (ret.length == 32 && abi.decode(ret, (bool)));
        uint256 received = ASSET.balanceOf(payee) - balanceBefore;
        require(ok && received == amount, TransferFailed(amount, received));
    }

    function _installedPolicy(address account) private view returns (Policy storage policy) {
        policy = _policies[account];
        require(policy.sessionKey != address(0), NotInstalled(account));
    }

    function _setPayee(address account, uint64 generation, address payee, bool allowed) private {
        require(payee != address(0) && payee != account, InvalidPayee(payee));
        _allowedPayees[account][generation][payee] = allowed;
        emit PayeeSet(account, payee, allowed);
    }

    function _checkLimits(uint128 perCallCap, uint128 periodBudget, uint32 period, uint16 maxPaymentsPerPeriod)
        private
        pure
    {
        require(
            perCallCap != 0 && perCallCap <= periodBudget && period >= MIN_PERIOD && period <= MAX_PERIOD
                && maxPaymentsPerPeriod != 0 && maxPaymentsPerPeriod <= RING_CAPACITY,
            InvalidLimits(perCallCap, periodBudget, period, maxPaymentsPerPeriod)
        );
    }

    /// @dev `requireFuture` is false at install time (see {onInstall}) and true when the owner rotates the key.
    function _checkSessionKey(address account, address sessionKey, uint48 validUntil, bool requireFuture) private view {
        require(
            sessionKey != address(0) && sessionKey != account && (!requireFuture || validUntil > block.timestamp),
            InvalidSessionKey(sessionKey, validUntil)
        );
    }
}
