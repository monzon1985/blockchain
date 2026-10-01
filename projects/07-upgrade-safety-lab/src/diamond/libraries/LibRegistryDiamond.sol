// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev ERC-7201 base slot of the diamond's application state.
uint256 constant DIAMOND_REGISTRY_STORAGE_LOCATION = erc7201("upgradelab.storage.DiamondRegistry");

/// @title LibRegistryDiamond
/// @notice Application state of the registry diamond. A fresh deployment has no legacy region to preserve, so
///         the whole V3 feature set fits in one namespace and plan prices pack into the plan slot.
library LibRegistryDiamond {
    /// @notice Plan parameters.
    /// @param duration Seconds of access per subscription.
    /// @param active Whether new subscriptions are accepted.
    /// @param price Payment-token units per period (zero = free).
    struct Plan {
        uint64 duration;
        bool active;
        uint128 price;
    }

    /// @notice A subscriber's current subscription.
    /// @param planId Plan subscribed to (0 = none).
    /// @param expiresAt Timestamp at which access ends.
    struct Subscription {
        uint64 planId;
        uint64 expiresAt;
    }

    /// @notice Every piece of application state of the diamond.
    /// @param planCount Number of plans; ids are 1..planCount.
    /// @param totalSubscriptions Lifetime number of successful subscribe calls.
    /// @param gracePeriod Seconds after expiry during which `isActive` still returns true.
    /// @param paused Whether new subscriptions are paused.
    /// @param plans Plan parameters by id.
    /// @param subscriptions Current subscription by subscriber.
    /// @param renewals Number of renewals by subscriber.
    /// @param paymentToken ERC-20 token subscribers pay in.
    /// @param treasury Account that receives payments.
    /// @param totalRevenue Sum of every payment collected.
    /// @custom:storage-location erc7201:upgradelab.storage.DiamondRegistry
    struct RegistryStorage {
        uint64 planCount;
        uint64 totalSubscriptions;
        uint64 gracePeriod;
        bool paused;
        mapping(uint256 planId => Plan) plans;
        mapping(address subscriber => Subscription) subscriptions;
        mapping(address subscriber => uint32 count) renewals;
        IERC20 paymentToken;
        address treasury;
        uint256 totalRevenue;
    }

    /// @notice Returns a storage pointer to the application state.
    /// @return $ The ERC-7201 namespace `upgradelab.storage.DiamondRegistry`.
    function registryStorage() internal pure returns (RegistryStorage storage $) {
        uint256 location = DIAMOND_REGISTRY_STORAGE_LOCATION;
        // Only assigns the slot of a storage pointer; no memory or storage is touched.
        assembly {
            $.slot := location
        }
    }
}
