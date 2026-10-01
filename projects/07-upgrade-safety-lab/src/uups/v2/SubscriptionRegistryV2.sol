// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IRegistryErrors, IRegistryEvents, RegistryLimits} from "../../interfaces/IRegistry.sol";
import {RegistryNamespaceV2} from "../RegistryNamespace.sol";
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

/// @title SubscriptionRegistryV2
/// @notice Version 2 of the registry on OpenZeppelin Contracts-Upgradeable 5.7.0. Every OZ parent keeps its state
///         in an ERC-7201 namespace; the V1 application data stays in its frozen sequential region; the state added
///         in V2 (grace period, renewal counters) lives in `upgradelab.storage.SubscriptionRegistry`.
/// @dev Roles: the owner (Ownable2Step) administers plans, the grace period and the pause switch. Upgrades are
///      `restricted` by an AccessManager, which puts them behind an execution delay that a guardian can cancel.
///      Reached from V1 only through `SubscriptionRegistryBridge`; a direct V1 -> V2 upgrade is the OZ #6362
///      failure reproduced in `NaiveMigration6362.t.sol` and rejected by the layout gate.
contract SubscriptionRegistryV2 is
    LegacyOzV4Slots,
    RegistryStorageV1,
    RegistryNamespaceV2,
    Initializable,
    Ownable2StepUpgradeable,
    PausableUpgradeable,
    AccessManagedUpgradeable,
    UUPSUpgradeable,
    IRegistryEvents,
    IRegistryErrors
{
    /// @notice Locks the implementation so nobody can initialize (and take over) the logic contract itself.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @dev Like OpenZeppelin's `initializer`, admits only a proxy that was never initialized. Paired with
    ///      `reinitializer(3)` it records the version the upgrade path ends at, so a fresh proxy can never run the
    ///      upgrade-path `initializeV2` (which would let the owner swap the upgrade authority).
    modifier onlyNeverInitialized() {
        if (_getInitializedVersion() != 0) revert InvalidInitialization();
        _;
    }

    /// @notice Initializes a fresh V2 proxy (no V1 history) straight to version 3, the version `initializeV2`
    ///         leaves behind, so every later re-initializer sees the same state on both paths.
    /// @param initialOwner Plan administrator.
    /// @param initialAuthority AccessManager that authorizes upgrades.
    function initialize(address initialOwner, address initialAuthority) external onlyNeverInitialized reinitializer(3) {
        if (initialAuthority.code.length == 0) revert InvalidAuthority(initialAuthority);
        __Ownable_init(initialOwner);
        __Ownable2Step_init();
        __Pausable_init();
        __AccessManaged_init(initialAuthority);
    }

    /// @notice Upgrade-path initializer, called by the owner through `bridge.upgradeToAndCall`.
    /// @dev `reinitializer(3)`: the bridge left the Initializable namespace at version 2. Owner-gated so that an
    ///      upgrade executed without calldata cannot be followed by a front-run authority takeover. Closed for good
    ///      on a freshly initialized V2 proxy, which `initialize` already put at version 3.
    /// @param initialAuthority AccessManager that authorizes upgrades from now on.
    function initializeV2(address initialAuthority) external reinitializer(3) onlyOwner {
        if (initialAuthority.code.length == 0) revert InvalidAuthority(initialAuthority);
        __Pausable_init();
        __AccessManaged_init(initialAuthority);
    }

    /// @notice Creates a plan.
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

    /// @notice Subscribes the caller; an unexpired subscription to the same plan is extended and counted as a
    ///         renewal, anything else starts a fresh period from now.
    /// @param planId The plan to subscribe to.
    /// @return expiresAt Timestamp at which the caller's access ends.
    function subscribe(uint256 planId) external whenNotPaused returns (uint64 expiresAt) {
        _requirePlan(planId);
        Plan memory p = _plans[planId];
        if (!p.active) revert PlanInactive(planId);

        Subscription storage s = _subscriptions[msg.sender];
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 nowTs = uint64(block.timestamp); // lossless until the year 2^64 s (about 5.8e11 years)
        bool renewal = s.planId == planId && s.expiresAt > nowTs;
        expiresAt = (renewal ? s.expiresAt : nowTs) + p.duration;
        // forge-lint: disable-next-line(unsafe-typecast)
        s.planId = uint64(planId); // lossless: planId <= _planCount, which is a uint64
        s.expiresAt = expiresAt;
        _totalSubscriptions += 1;
        if (renewal) _registry().renewals[msg.sender] += 1;
        emit Subscribed(msg.sender, planId, expiresAt, renewal);
    }

    /// @notice Cancels the caller's subscription; the remaining time is forfeited.
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

    /// @notice Semantic version of this implementation.
    /// @return The version string.
    function version() external pure returns (string memory) {
        return "2.0.0";
    }

    /// @dev Upgrades go through the AccessManager (role-based, optionally delayed and cancellable).
    function _authorizeUpgrade(address) internal override restricted {}

    /// @dev Reverts unless `planId` is in 1.._planCount.
    function _requirePlan(uint256 planId) private view {
        if (planId == 0 || planId > _planCount) revert UnknownPlan(planId, _planCount);
    }
}
