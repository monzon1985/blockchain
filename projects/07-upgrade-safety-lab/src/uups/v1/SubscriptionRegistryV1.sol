// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IRegistryErrors, IRegistryEvents, RegistryLimits} from "../../interfaces/IRegistry.sol";
import {RegistryStorageV1} from "./RegistryStorageV1.sol";
import {OwnableUpgradeable} from "@openzeppelin-v4/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin-v4/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin-v4/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title SubscriptionRegistryV1
/// @notice Version 1 of the subscription registry, built on OpenZeppelin Contracts-Upgradeable 4.9.6: the
///         pre-ERC-7201 world of sequential storage and `__gap` arrays. It is the starting point of the upgrade lab.
/// @dev Storage layout (verified by `forge inspect` and pinned by the layout gate):
///      slot 0        Initializable._initialized (uint8) | _initializing (bool)
///      slots 1-50    ContextUpgradeable.__gap
///      slot 51       OwnableUpgradeable._owner
///      slots 52-100  OwnableUpgradeable.__gap
///      slots 101-150 ERC1967UpgradeUpgradeable.__gap
///      slots 151-200 UUPSUpgradeable.__gap
///      slots 201-250 RegistryStorageV1 (application data + __gap)
///      Upgrading this contract straight to an OZ 5.x implementation strands `_initialized` and `_owner` in
///      slots the new code never reads (OpenZeppelin issue #6362). `SubscriptionRegistryBridge` is the only
///      supported way out.
contract SubscriptionRegistryV1 is
    Initializable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    RegistryStorageV1,
    IRegistryEvents,
    IRegistryErrors
{
    /// @notice Locks the implementation so nobody can initialize (and take over) the logic contract itself.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the proxy.
    /// @param initialOwner Account that administers plans and authorizes upgrades.
    function initialize(address initialOwner) external initializer {
        if (initialOwner == address(0)) revert InvalidOwner(address(0));
        __Ownable_init();
        __UUPSUpgradeable_init();
        _transferOwnership(initialOwner);
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

    /// @notice Subscribes the caller. An unexpired subscription to the same plan is extended; anything else
    ///         starts a fresh period from now (remaining time on another plan is forfeited).
    /// @param planId The plan to subscribe to.
    /// @return expiresAt Timestamp at which the caller's access ends.
    function subscribe(uint256 planId) external returns (uint64 expiresAt) {
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
    /// @return True while `block.timestamp < expiresAt`.
    function isActive(address subscriber) external view returns (bool) {
        return block.timestamp < _subscriptions[subscriber].expiresAt;
    }

    /// @notice Lifetime number of successful `subscribe` calls.
    /// @return The counter.
    function totalSubscriptions() external view returns (uint64) {
        return _totalSubscriptions;
    }

    /// @notice Semantic version of this implementation.
    /// @return The version string.
    function version() external pure returns (string memory) {
        return "1.0.0";
    }

    /// @dev Upgrades are authorized by the owner (sequential slot 51).
    function _authorizeUpgrade(address) internal override onlyOwner {}

    /// @dev Reverts unless `planId` is in 1.._planCount.
    function _requirePlan(uint256 planId) private view {
        if (planId == 0 || planId > _planCount) revert UnknownPlan(planId, _planCount);
    }
}
