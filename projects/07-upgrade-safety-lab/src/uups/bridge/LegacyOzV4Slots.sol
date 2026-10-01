// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title LegacyOzV4Slots
/// @notice Typed view of the 201 sequential slots that OpenZeppelin Contracts-Upgradeable 4.9.6 parents
///         (Initializable, ContextUpgradeable, OwnableUpgradeable, ERC1967UpgradeUpgradeable, UUPSUpgradeable)
///         occupied in V1. Inheriting it first keeps `RegistryStorageV1` at slots 201..250 in OZ 5.x contracts,
///         whose parents keep all their state in ERC-7201 namespaces instead.
/// @dev Only `SubscriptionRegistryBridge` reads these variables: it copies `_legacyInitialized` and
///      `_legacyOwner` into the OZ 5.x namespaces and then zeroes them. V2 and V3 inherit the contract purely to
///      hold the slots; `RetiredSlots.t.sol` proves that no function of the V2 or V3 API reads or writes slots
///      0..200.
abstract contract LegacyOzV4Slots {
    // These variables are written by V1 in the proxy's storage and read only by the bridge: Slither's
    // single-implementation view ("never initialized", "could be constant", "unused in V2/V3") does not apply.
    // slither-disable-start uninitialized-state,constable-states,unused-state

    /// @notice Slot 0, byte 0: OZ 4.9.6 `Initializable._initialized` (1 once V1 was initialized).
    uint8 internal _legacyInitialized;

    /// @notice Slot 0, byte 1: OZ 4.9.6 `Initializable._initializing`.
    bool internal _legacyInitializing;

    /// @dev Slots 1..50: `ContextUpgradeable.__gap`.
    uint256[50] private __legacyContextGap;

    /// @notice Slot 51: OZ 4.9.6 `OwnableUpgradeable._owner`.
    address internal _legacyOwner;

    /// @dev Slots 52..100: `OwnableUpgradeable.__gap`.
    uint256[49] private __legacyOwnableGap;

    /// @dev Slots 101..150: `ERC1967UpgradeUpgradeable.__gap`.
    uint256[50] private __legacyErc1967Gap;

    /// @dev Slots 151..200: `UUPSUpgradeable.__gap`.
    uint256[50] private __legacyUupsGap;

    // slither-disable-end uninitialized-state,constable-states,unused-state
}
