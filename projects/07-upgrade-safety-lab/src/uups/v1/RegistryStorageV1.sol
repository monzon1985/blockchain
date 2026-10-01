// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title RegistryStorageV1
/// @notice The application storage of the V1 registry, written the OpenZeppelin 4.x way: sequential state
///         variables followed by a `__gap` reservation.
/// @dev FROZEN. Every later UUPS version inherits this contract unchanged so the V1 data keeps its slots
///      (201..250 behind the OZ 4.9.6 parents, see `LegacyOzV4Slots`). Mappings cannot be relocated in O(1),
///      so the legacy application region stays where it is forever; all new state from V2 on lives in the
///      ERC-7201 namespace `upgradelab.storage.SubscriptionRegistry`. The storage-layout gate
///      (`layout-diff`) fails CI if a variable here is reordered, retyped or removed.
abstract contract RegistryStorageV1 {
    /// @notice Parameters of a plan.
    /// @param duration Seconds of access per subscription.
    /// @param active Whether new subscriptions are accepted.
    struct Plan {
        uint64 duration;
        bool active;
    }

    /// @notice A subscriber's current subscription.
    /// @param planId Plan subscribed to (0 = none). Plan ids are bounded by `_planCount` (a uint64).
    /// @param expiresAt Timestamp at which access ends.
    struct Subscription {
        uint64 planId;
        uint64 expiresAt;
    }

    // The bridge only reads these variables (V1 wrote them in the proxy's storage), which Slither reports as
    // "never initialized" / "could be constant" when it analyses the bridge on its own.
    // slither-disable-start uninitialized-state,constable-states

    /// @notice Number of plans created; plan ids are 1.._planCount. Packed with `_totalSubscriptions`.
    uint64 internal _planCount;

    /// @notice Lifetime number of successful subscribe calls. Shares a slot with `_planCount`.
    uint64 internal _totalSubscriptions;

    /// @notice Plan parameters by plan id.
    mapping(uint256 planId => Plan) internal _plans;

    /// @notice Current subscription by subscriber.
    mapping(address subscriber => Subscription) internal _subscriptions;

    // slither-disable-end uninitialized-state,constable-states

    /// @dev Reserved slots so this region always spans 50 slots (3 used + 47 reserved).
    uint256[47] private __gap;
}
