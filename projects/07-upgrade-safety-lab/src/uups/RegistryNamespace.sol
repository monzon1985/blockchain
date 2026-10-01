// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev ERC-7201 namespace id of the registry state introduced in V2.
string constant REGISTRY_NAMESPACE_ID = "upgradelab.storage.SubscriptionRegistry";

/// @dev Base slot of the registry namespace, computed at compile time by the `erc7201` builtin
///      (Solidity 0.8.35+): keccak256(abi.encode(uint256(keccak256(id)) - 1)) & ~bytes32(uint256(0xff)).
///      `Erc7201Formula.t.sol` recomputes the formula by hand and pins the value.
uint256 constant REGISTRY_STORAGE_LOCATION = erc7201(REGISTRY_NAMESPACE_ID);

/// @title RegistryNamespaceV2
/// @notice The ERC-7201 storage of the registry as introduced in V2.
abstract contract RegistryNamespaceV2 {
    /// @notice State added in V2. Members may only ever be appended (see `RegistryNamespaceV3`).
    /// @param gracePeriod Seconds after `expiresAt` during which `isActive` still returns true.
    /// @param renewals Number of times each subscriber extended an unexpired subscription since V2.
    /// @custom:storage-location erc7201:upgradelab.storage.SubscriptionRegistry
    struct RegistryStorage {
        uint64 gracePeriod;
        mapping(address subscriber => uint32 count) renewals;
    }

    /// @dev Returns a storage pointer to the namespace.
    function _registry() internal pure returns (RegistryStorage storage $) {
        uint256 location = REGISTRY_STORAGE_LOCATION;
        // Only assigns the slot of a storage pointer; no memory or storage is touched.
        assembly {
            $.slot := location
        }
    }
}

/// @title RegistryNamespaceV3
/// @notice The same ERC-7201 namespace as `RegistryNamespaceV2`, with the paid-tier members appended.
abstract contract RegistryNamespaceV3 {
    /// @notice V2 members, unchanged and in the same order, followed by the members added in V3.
    /// @param gracePeriod Seconds after `expiresAt` during which `isActive` still returns true.
    /// @param renewals Number of times each subscriber extended an unexpired subscription since V2.
    /// @param paymentToken ERC-20 token subscribers pay in (zero until payments are configured).
    /// @param treasury Account that receives every payment.
    /// @param totalRevenue Sum of every payment collected, in payment-token units.
    /// @param planPrice Price per subscription period of each plan (zero means free).
    /// @custom:storage-location erc7201:upgradelab.storage.SubscriptionRegistry
    struct RegistryStorage {
        uint64 gracePeriod;
        mapping(address subscriber => uint32 count) renewals;
        IERC20 paymentToken;
        address treasury;
        uint256 totalRevenue;
        mapping(uint256 planId => uint128 price) planPrice;
    }

    /// @dev Returns a storage pointer to the namespace.
    function _registry() internal pure returns (RegistryStorage storage $) {
        uint256 location = REGISTRY_STORAGE_LOCATION;
        // Only assigns the slot of a storage pointer; no memory or storage is touched.
        assembly {
            $.slot := location
        }
    }
}
