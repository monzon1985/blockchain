// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title Registry limits
/// @notice Bounds shared by every UUPS version and by the diamond, so both architectures reject the same inputs.
library RegistryLimits {
    /// @notice Longest plan a registry accepts (about ten years). Bounds `expiresAt` arithmetic for any realistic horizon.
    uint64 internal constant MAX_DURATION = 3650 days;
    /// @notice Longest grace period after expiry during which `isActive` still returns true (introduced in V2).
    uint64 internal constant MAX_GRACE_PERIOD = 30 days;
}

/// @title Registry events
/// @notice Events emitted by the subscription registry. Every version and the diamond emit the same events, so an
///         indexer does not care which upgrade architecture it is watching.
interface IRegistryEvents {
    /// @notice A plan was created.
    /// @param planId Sequential identifier of the plan, starting at 1.
    /// @param duration Seconds of access a single subscription to this plan buys.
    event PlanCreated(uint256 indexed planId, uint64 duration);

    /// @notice A plan was opened or closed for new subscriptions.
    /// @param planId The plan whose status changed.
    /// @param active True when new subscriptions are accepted.
    event PlanStatusChanged(uint256 indexed planId, bool active);

    /// @notice A subscriber bought or extended access.
    /// @param subscriber The account that subscribed.
    /// @param planId The plan subscribed to.
    /// @param expiresAt Timestamp at which access ends (grace period excluded).
    /// @param renewal True when an unexpired subscription to the same plan was extended.
    event Subscribed(address indexed subscriber, uint256 indexed planId, uint64 expiresAt, bool renewal);

    /// @notice A subscriber cancelled; the remaining time is forfeited.
    /// @param subscriber The account whose subscription was deleted.
    /// @param planId The plan the cancelled subscription belonged to.
    event SubscriptionCancelled(address indexed subscriber, uint256 indexed planId);

    /// @notice The post-expiry grace period changed (V2 and later).
    /// @param previousGracePeriod Grace period before the change, in seconds.
    /// @param newGracePeriod Grace period after the change, in seconds.
    event GracePeriodUpdated(uint64 previousGracePeriod, uint64 newGracePeriod);

    /// @notice Paid tiers were enabled with a payment token and a treasury (V3 and later).
    /// @param token ERC-20 token subscribers pay in.
    /// @param treasury Account that receives every payment.
    event PaymentsConfigured(address indexed token, address indexed treasury);

    /// @notice The treasury that receives payments changed (V3 and later).
    /// @param previousTreasury Treasury before the change.
    /// @param newTreasury Treasury after the change.
    event TreasuryUpdated(address indexed previousTreasury, address indexed newTreasury);

    /// @notice The price of a plan changed (V3 and later). A price of zero makes the plan free.
    /// @param planId The repriced plan.
    /// @param price New price per subscription period, in payment-token units.
    event PlanPriceUpdated(uint256 indexed planId, uint128 price);

    /// @notice A subscriber paid for a period (V3 and later).
    /// @param subscriber The paying account.
    /// @param planId The plan paid for.
    /// @param treasury The account that received the payment.
    /// @param amount Payment-token units transferred.
    event PaymentCollected(
        address indexed subscriber, uint256 indexed planId, address indexed treasury, uint128 amount
    );
}

/// @title Registry errors
/// @notice Custom errors shared by every version and by the diamond. Identical selectors let the differential
///         fuzzer compare revert data byte for byte across the two architectures.
interface IRegistryErrors {
    /// @notice The zero address was supplied where an owner is required.
    /// @param owner The rejected owner.
    error InvalidOwner(address owner);

    /// @notice A plan duration is zero or above `RegistryLimits.MAX_DURATION`.
    /// @param duration The rejected duration.
    /// @param maxDuration The largest accepted duration.
    error InvalidDuration(uint64 duration, uint64 maxDuration);

    /// @notice The plan id does not exist.
    /// @param planId The requested id.
    /// @param planCount Number of plans created so far (valid ids are 1..planCount).
    error UnknownPlan(uint256 planId, uint256 planCount);

    /// @notice The plan exists but is closed for new subscriptions.
    /// @param planId The closed plan.
    error PlanInactive(uint256 planId);

    /// @notice The account has no subscription to cancel.
    /// @param subscriber The account without a subscription.
    error NoSubscription(address subscriber);

    /// @notice A grace period above `RegistryLimits.MAX_GRACE_PERIOD` was requested.
    /// @param gracePeriod The rejected grace period.
    /// @param maxGracePeriod The largest accepted grace period.
    error InvalidGracePeriod(uint64 gracePeriod, uint64 maxGracePeriod);

    /// @notice The AccessManager authority is not a contract.
    /// @param authority The rejected authority.
    error InvalidAuthority(address authority);

    /// @notice The payment token is not a contract.
    /// @param token The rejected token.
    error InvalidPaymentToken(address token);

    /// @notice The treasury is the zero address.
    /// @param treasury The rejected treasury.
    error InvalidTreasury(address treasury);

    /// @notice A price was set before paid tiers were configured.
    error PaymentsNotConfigured();

    /// @notice The plan costs more than the subscriber accepted (V3 and later). The one-argument `subscribe` accepts
    ///         a price of zero only.
    /// @param planId The plan subscribed to.
    /// @param price Its current price, in payment-token units.
    /// @param maxPrice The highest price the subscriber accepted.
    error PriceAboveMax(uint256 planId, uint128 price, uint128 maxPrice);

    /// @notice Renouncing ownership is disabled: it would freeze plan administration forever.
    error RenounceDisabled();
}

/// @title Subscription registry API (V3 feature set)
/// @notice The external surface that UUPS V3 and the diamond both expose. The differential fuzzer drives both
///         deployments through this interface only.
interface ISubscriptionRegistry is IRegistryEvents, IRegistryErrors {
    /// @notice Creates a plan (owner only).
    /// @param duration Seconds of access per subscription, 1..MAX_DURATION.
    /// @return planId Identifier of the new plan.
    function createPlan(uint64 duration) external returns (uint256 planId);

    /// @notice Opens or closes a plan for new subscriptions (owner only).
    /// @param planId The plan to update.
    /// @param active True to accept new subscriptions.
    function setPlanActive(uint256 planId, bool active) external;

    /// @notice Sets the price of a plan in payment-token units (owner only, requires configured payments).
    /// @param planId The plan to reprice.
    /// @param price New price; zero makes the plan free.
    function setPlanPrice(uint256 planId, uint128 price) external;

    /// @notice Subscribes the caller to a free plan, extending an unexpired subscription to the same plan. Never
    ///         moves tokens: a priced plan reverts with `PriceAboveMax(planId, price, 0)`.
    /// @param planId The plan to subscribe to.
    /// @return expiresAt Timestamp at which the caller's access ends.
    function subscribe(uint256 planId) external returns (uint64 expiresAt);

    /// @notice Subscribes the caller and pays the plan price, reverting with `PriceAboveMax` when the current price
    ///         exceeds `maxPrice` (front-running protection for a repricing mined first).
    /// @param planId The plan to subscribe to.
    /// @param maxPrice Highest price the caller accepts, in payment-token units.
    /// @return expiresAt Timestamp at which the caller's access ends.
    function subscribeWithMaxPrice(uint256 planId, uint128 maxPrice) external returns (uint64 expiresAt);

    /// @notice Cancels the caller's subscription without refund.
    function cancel() external;

    /// @notice Sets the post-expiry grace period (owner only).
    /// @param newGracePeriod New grace period in seconds, at most MAX_GRACE_PERIOD.
    function setGracePeriod(uint64 newGracePeriod) external;

    /// @notice Changes the treasury that receives payments (owner only, requires configured payments).
    /// @param newTreasury New treasury, non-zero.
    function setTreasury(address newTreasury) external;

    /// @notice Pauses new subscriptions (owner only).
    function pause() external;

    /// @notice Resumes new subscriptions (owner only).
    function unpause() external;

    /// @notice Starts a two-step ownership transfer (owner only).
    /// @param newOwner The account that must call `acceptOwnership`.
    function transferOwnership(address newOwner) external;

    /// @notice Completes a two-step ownership transfer (pending owner only).
    function acceptOwnership() external;

    /// @notice Always reverts with `RenounceDisabled`.
    function renounceOwnership() external;

    /// @notice Current owner.
    /// @return The account allowed to administer plans.
    function owner() external view returns (address);

    /// @notice Account allowed to accept ownership, or zero.
    /// @return The pending owner.
    function pendingOwner() external view returns (address);

    /// @notice Number of plans created; valid ids are 1..planCount.
    /// @return The plan count.
    function planCount() external view returns (uint256);

    /// @notice Plan parameters.
    /// @param planId The plan to read.
    /// @return duration Seconds of access per subscription.
    /// @return active Whether new subscriptions are accepted.
    function plan(uint256 planId) external view returns (uint64 duration, bool active);

    /// @notice Price of a plan in payment-token units.
    /// @param planId The plan to read.
    /// @return The price (zero for free plans).
    function planPrice(uint256 planId) external view returns (uint128);

    /// @notice The subscription of an account.
    /// @param subscriber The account to read.
    /// @return planId Plan subscribed to (0 when none).
    /// @return expiresAt Expiry timestamp (0 when none).
    function subscriptionOf(address subscriber) external view returns (uint256 planId, uint64 expiresAt);

    /// @notice Whether the account currently has access (expiry plus grace period).
    /// @param subscriber The account to check.
    /// @return True while `block.timestamp < expiresAt + gracePeriod`.
    function isActive(address subscriber) external view returns (bool);

    /// @notice Number of renewals (extensions of an unexpired subscription) by an account since V2.
    /// @param subscriber The account to read.
    /// @return The renewal count.
    function renewalsOf(address subscriber) external view returns (uint32);

    /// @notice Lifetime number of successful `subscribe` calls.
    /// @return The counter.
    function totalSubscriptions() external view returns (uint64);

    /// @notice Post-expiry grace period in seconds.
    /// @return The grace period.
    function gracePeriod() external view returns (uint64);

    /// @notice Whether new subscriptions are paused.
    /// @return True when paused.
    function paused() external view returns (bool);

    /// @notice Token subscribers pay in (zero until payments are configured).
    /// @return The payment token.
    function paymentToken() external view returns (address);

    /// @notice Account receiving payments (zero until payments are configured).
    /// @return The treasury.
    function treasury() external view returns (address);

    /// @notice Sum of every payment collected, in payment-token units.
    /// @return The lifetime revenue.
    function totalRevenue() external view returns (uint256);

    /// @notice Semantic version of the deployed logic.
    /// @return The version string.
    function version() external pure returns (string memory);
}
