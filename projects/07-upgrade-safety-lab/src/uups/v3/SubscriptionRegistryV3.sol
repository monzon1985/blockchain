// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IRegistryErrors, IRegistryEvents, RegistryLimits} from "../../interfaces/IRegistry.sol";
import {RegistryNamespaceV3} from "../RegistryNamespace.sol";
import {LegacyOzV4Slots} from "../bridge/LegacyOzV4Slots.sol";
import {RegistryStorageV1} from "../v1/RegistryStorageV1.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {
    AccessManagedUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/manager/AccessManagedUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/// @title SubscriptionRegistryV3
/// @notice Version 3 of the registry: V2 plus paid tiers. Plans can carry a price in an ERC-20 payment token that
///         is pulled straight to the treasury on every subscription or renewal. Paying callers state the highest
///         price they accept (`subscribeWithMaxPrice`); the one-argument `subscribe` of V1/V2 never moves tokens.
/// @dev Storage: identical to V2 except that four members are appended to the ERC-7201 struct
///      (`paymentToken`, `treasury`, `totalRevenue`, `planPrice`). The reentrancy guard uses transient storage, so
///      it adds no persistent state. The contract does not declare `is ISubscriptionRegistry`: half of that API
///      comes from OpenZeppelin parents and would need override lists; scripts/check-layouts.mjs asserts instead
///      that V3 serves every ISubscriptionRegistry selector.
contract SubscriptionRegistryV3 is
    LegacyOzV4Slots,
    RegistryStorageV1,
    RegistryNamespaceV3,
    Initializable,
    Ownable2StepUpgradeable,
    PausableUpgradeable,
    AccessManagedUpgradeable,
    ReentrancyGuardTransient,
    UUPSUpgradeable,
    IRegistryEvents,
    IRegistryErrors
{
    using SafeERC20 for IERC20;

    /// @notice Locks the implementation so nobody can initialize (and take over) the logic contract itself.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @dev Like OpenZeppelin's `initializer`, admits only a proxy that was never initialized. Paired with
    ///      `reinitializer(4)` it records the version the upgrade path ends at, so a fresh proxy can never run the
    ///      upgrade-path `initializeV3` (which would let the owner swap the payment token).
    modifier onlyNeverInitialized() {
        if (_getInitializedVersion() != 0) revert InvalidInitialization();
        _;
    }

    /// @notice Initializes a fresh V3 proxy (no V1/V2 history) straight to version 4, the version `initializeV3`
    ///         leaves behind.
    /// @param initialOwner Plan administrator.
    /// @param initialAuthority AccessManager that authorizes upgrades.
    /// @param token ERC-20 token subscribers pay in.
    /// @param initialTreasury Account that receives payments.
    function initialize(address initialOwner, address initialAuthority, IERC20 token, address initialTreasury)
        external
        onlyNeverInitialized
        reinitializer(4)
    {
        if (initialAuthority.code.length == 0) revert InvalidAuthority(initialAuthority);
        __Ownable_init(initialOwner);
        __Ownable2Step_init();
        __Pausable_init();
        __AccessManaged_init(initialAuthority);
        _configurePayments(token, initialTreasury);
    }

    /// @notice Upgrade-path initializer that enables paid tiers. Called by the owner after the timelocked
    ///         V2 -> V3 upgrade has been executed by the AccessManager.
    /// @dev `reinitializer(4)` (V2 used 3). Owner-gated: the upgrade itself is executed by the AccessManager, whose
    ///      address is `msg.sender` inside `upgradeToAndCall`, so the payment configuration is a separate call.
    ///      Closed for good on a freshly initialized V3 proxy, which `initialize` already put at version 4.
    /// @param token ERC-20 token subscribers pay in.
    /// @param initialTreasury Account that receives payments.
    function initializeV3(IERC20 token, address initialTreasury) external reinitializer(4) onlyOwner {
        _configurePayments(token, initialTreasury);
    }

    /// @notice Creates a plan (free until priced with `setPlanPrice`).
    /// @param duration Seconds of access per subscription, 1..MAX_DURATION.
    /// @return planId Identifier of the new plan.
    function createPlan(uint64 duration) external onlyOwner returns (uint256 planId) {
        if (duration == 0 || duration > RegistryLimits.MAX_DURATION) {
            revert InvalidDuration(duration, RegistryLimits.MAX_DURATION);
        }
        uint64 id = _planCount + 1;
        _planCount = id;
        _plans[id] = Plan({duration: duration, active: true});
        emit PlanCreated(id, duration);
        return id;
    }

    /// @notice Opens or closes a plan for new subscriptions.
    /// @param planId The plan to update.
    /// @param active True to accept new subscriptions.
    function setPlanActive(uint256 planId, bool active) external onlyOwner {
        _requirePlan(planId);
        _plans[planId].active = active;
        emit PlanStatusChanged(planId, active);
    }

    /// @notice Sets the price of a plan.
    /// @param planId The plan to reprice.
    /// @param price Payment-token units per subscription period; zero makes the plan free.
    function setPlanPrice(uint256 planId, uint128 price) external onlyOwner {
        RegistryStorage storage $ = _registry();
        if (address($.paymentToken) == address(0)) revert PaymentsNotConfigured();
        _requirePlan(planId);
        $.planPrice[planId] = price;
        emit PlanPriceUpdated(planId, price);
    }

    /// @notice Changes the treasury that receives payments.
    /// @param newTreasury New treasury, non-zero.
    function setTreasury(address newTreasury) external onlyOwner {
        RegistryStorage storage $ = _registry();
        if (address($.paymentToken) == address(0)) revert PaymentsNotConfigured();
        if (newTreasury == address(0)) revert InvalidTreasury(address(0));
        emit TreasuryUpdated($.treasury, newTreasury);
        $.treasury = newTreasury;
    }

    /// @notice Subscribes the caller to a free plan; an unexpired subscription to the same plan is extended and
    ///         counted as a renewal. Never moves tokens: on a plan that carries a price it reverts with
    ///         `PriceAboveMax(planId, price, 0)`, so a repricing that lands first can never charge this caller.
    /// @param planId The plan to subscribe to.
    /// @return expiresAt Timestamp at which the caller's access ends.
    function subscribe(uint256 planId) external nonReentrant whenNotPaused returns (uint64 expiresAt) {
        return _subscribe(planId, 0);
    }

    /// @notice Subscribes the caller and pulls the plan price, which must not exceed `maxPrice`, from the caller
    ///         straight into the treasury. The bound protects a pending subscription (and the caller's standing
    ///         allowance) against a `setPlanPrice` that is mined first.
    /// @param planId The plan to subscribe to.
    /// @param maxPrice Highest price the caller accepts, in payment-token units.
    /// @return expiresAt Timestamp at which the caller's access ends.
    function subscribeWithMaxPrice(uint256 planId, uint128 maxPrice)
        external
        nonReentrant
        whenNotPaused
        returns (uint64 expiresAt)
    {
        return _subscribe(planId, maxPrice);
    }

    /// @notice Cancels the caller's subscription; the remaining time is forfeited (no refund).
    function cancel() external {
        uint64 planId = _subscriptions[msg.sender].planId;
        // Plan ids start at 1: zero is the "no subscription" sentinel.
        if (planId == 0) revert NoSubscription(msg.sender);
        delete _subscriptions[msg.sender];
        emit SubscriptionCancelled(msg.sender, planId);
    }

    /// @notice Sets the post-expiry grace period.
    /// @param newGracePeriod Grace period in seconds, at most MAX_GRACE_PERIOD.
    function setGracePeriod(uint64 newGracePeriod) external onlyOwner {
        if (newGracePeriod > RegistryLimits.MAX_GRACE_PERIOD) {
            revert InvalidGracePeriod(newGracePeriod, RegistryLimits.MAX_GRACE_PERIOD);
        }
        RegistryStorage storage $ = _registry();
        emit GracePeriodUpdated($.gracePeriod, newGracePeriod);
        $.gracePeriod = newGracePeriod;
    }

    /// @notice Pauses new subscriptions (cancellations stay open).
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Resumes new subscriptions.
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Disabled: renouncing would freeze plan administration forever.
    function renounceOwnership() public pure override(OwnableUpgradeable) {
        revert RenounceDisabled();
    }

    /// @notice Number of plans created; valid ids are 1..planCount.
    /// @return The plan count.
    function planCount() external view returns (uint256) {
        return _planCount;
    }

    /// @notice Plan parameters.
    /// @param planId The plan to read.
    /// @return duration Seconds of access per subscription.
    /// @return active Whether new subscriptions are accepted.
    function plan(uint256 planId) external view returns (uint64 duration, bool active) {
        Plan memory p = _plans[planId];
        return (p.duration, p.active);
    }

    /// @notice Price of a plan in payment-token units.
    /// @param planId The plan to read.
    /// @return The price (zero for free plans).
    function planPrice(uint256 planId) external view returns (uint128) {
        return _registry().planPrice[planId];
    }

    /// @notice The subscription of an account.
    /// @param subscriber The account to read.
    /// @return planId Plan subscribed to (0 when none).
    /// @return expiresAt Expiry timestamp (0 when none).
    function subscriptionOf(address subscriber) external view returns (uint256 planId, uint64 expiresAt) {
        Subscription memory s = _subscriptions[subscriber];
        return (s.planId, s.expiresAt);
    }

    /// @notice Whether the account currently has access.
    /// @param subscriber The account to check.
    /// @return True while `block.timestamp < expiresAt + gracePeriod`.
    function isActive(address subscriber) external view returns (bool) {
        uint64 expiresAt = _subscriptions[subscriber].expiresAt;
        return expiresAt != 0 && block.timestamp < uint256(expiresAt) + _registry().gracePeriod;
    }

    /// @notice Number of renewals by an account since V2.
    /// @param subscriber The account to read.
    /// @return The renewal count.
    function renewalsOf(address subscriber) external view returns (uint32) {
        return _registry().renewals[subscriber];
    }

    /// @notice Lifetime number of successful `subscribe` calls (V1 history included).
    /// @return The counter.
    function totalSubscriptions() external view returns (uint64) {
        return _totalSubscriptions;
    }

    /// @notice Post-expiry grace period in seconds.
    /// @return The grace period.
    function gracePeriod() external view returns (uint64) {
        return _registry().gracePeriod;
    }

    /// @notice Token subscribers pay in (zero until payments are configured).
    /// @return The payment token.
    function paymentToken() external view returns (address) {
        return address(_registry().paymentToken);
    }

    /// @notice Account receiving payments (zero until payments are configured).
    /// @return The treasury.
    function treasury() external view returns (address) {
        return _registry().treasury;
    }

    /// @notice Sum of every payment collected, in payment-token units.
    /// @return The lifetime revenue.
    function totalRevenue() external view returns (uint256) {
        return _registry().totalRevenue;
    }

    /// @notice Semantic version of this implementation.
    /// @return The version string.
    function version() external pure returns (string memory) {
        return "3.0.0";
    }

    /// @dev Upgrades go through the AccessManager (role-based, optionally delayed and cancellable).
    function _authorizeUpgrade(address) internal override restricted {}

    /// @dev Shared body of both `subscribe` entry points. Checks-effects-interactions: every state write and event
    ///      happens before the single token transfer, and the callers' `nonReentrant` (transient storage) blocks
    ///      callbacks from hook-enabled tokens.
    function _subscribe(uint256 planId, uint128 maxPrice) private returns (uint64 expiresAt) {
        _requirePlan(planId);
        Plan memory p = _plans[planId];
        if (!p.active) revert PlanInactive(planId);

        RegistryStorage storage $ = _registry();
        uint128 price = $.planPrice[planId];
        if (price > maxPrice) revert PriceAboveMax(planId, price, maxPrice);

        Subscription storage s = _subscriptions[msg.sender];
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 nowTs = uint64(block.timestamp); // lossless until the year 2^64 s (about 5.8e11 years)
        bool renewal = s.planId == planId && s.expiresAt > nowTs;
        expiresAt = (renewal ? s.expiresAt : nowTs) + p.duration;
        // forge-lint: disable-next-line(unsafe-typecast)
        s.planId = uint64(planId); // lossless: planId <= _planCount, which is a uint64
        s.expiresAt = expiresAt;
        _totalSubscriptions += 1;
        if (renewal) $.renewals[msg.sender] += 1;
        emit Subscribed(msg.sender, planId, expiresAt, renewal);

        if (price != 0) {
            address treasury_ = $.treasury;
            $.totalRevenue += price;
            emit PaymentCollected(msg.sender, planId, treasury_, price);
            $.paymentToken.safeTransferFrom(msg.sender, treasury_, price);
        }
    }

    /// @dev Validates and stores the payment configuration.
    function _configurePayments(IERC20 token, address initialTreasury) private {
        if (address(token).code.length == 0) revert InvalidPaymentToken(address(token));
        if (initialTreasury == address(0)) revert InvalidTreasury(address(0));
        RegistryStorage storage $ = _registry();
        $.paymentToken = token;
        $.treasury = initialTreasury;
        emit PaymentsConfigured(address(token), initialTreasury);
    }

    /// @dev Reverts unless `planId` is in 1.._planCount.
    function _requirePlan(uint256 planId) private view {
        if (planId == 0 || planId > _planCount) revert UnknownPlan(planId, _planCount);
    }
}
