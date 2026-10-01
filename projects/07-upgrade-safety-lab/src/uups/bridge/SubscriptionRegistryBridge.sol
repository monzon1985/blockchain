// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IRegistryErrors} from "../../interfaces/IRegistry.sol";
import {RegistryStorageV1} from "../v1/RegistryStorageV1.sol";
import {LegacyOzV4Slots} from "./LegacyOzV4Slots.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

/// @title SubscriptionRegistryBridge
/// @notice Intermediate implementation for the safe OZ 4.x (sequential) to OZ 5.x (ERC-7201) migration.
///         It copies the owner and the initialized version out of the legacy slots into the OZ 5.x namespaces,
///         zeroes the legacy slots, and can then only be upgraded onwards. While it is live the registry is in
///         maintenance mode: the V1 read API keeps answering and every application write (plans, subscriptions)
///         reverts for lack of a selector. Still callable: `upgradeToAndCall` and the `Ownable2Step` functions
///         (owner only), and `migrateFromV4`, which its `reinitializer(2)` closes inside the upgrade transaction.
/// @dev Migration, two owner transactions (bundle them in one multisig batch to avoid a maintenance window):
///        1. `V1.upgradeToAndCall(bridge, abi.encodeCall(bridge.migrateFromV4, ()))`
///           V1 authorizes with its legacy owner (slot 51); `migrateFromV4` runs as `reinitializer(2)` and must be
///           called by that same owner.
///        2. `bridge.upgradeToAndCall(v2, abi.encodeCall(v2.initializeV2, (accessManager)))`
///           authorized by the owner now stored in `openzeppelin.storage.Ownable`.
///      Skipping this contract (V1 straight to V2) leaves V2 with owner == address(0) and an uninitialized
///      `Initializable` namespace: the owner is locked out and anyone can call `initialize` (OZ issue #6362).
contract SubscriptionRegistryBridge is
    LegacyOzV4Slots,
    RegistryStorageV1,
    Initializable,
    Ownable2StepUpgradeable,
    UUPSUpgradeable,
    IRegistryErrors
{
    /// @notice The legacy Initializable slot is not in the "initialized at version 1, not initializing" state.
    /// @param legacyInitialized Value of `_initialized` found in slot 0.
    /// @param legacyInitializing Value of `_initializing` found in slot 0.
    error LegacyStateInvalid(uint8 legacyInitialized, bool legacyInitializing);

    /// @notice The migration was triggered by an account other than the legacy owner.
    /// @param caller The account that called `migrateFromV4`.
    /// @param legacyOwner The owner recorded in slot 51.
    error NotLegacyOwner(address caller, address legacyOwner);

    /// @notice The OZ 4.x owner and initialized version were copied into the OZ 5.x namespaces.
    /// @param owner Owner copied from slot 51 into `openzeppelin.storage.Ownable`.
    /// @param legacyInitializedVersion Version found in slot 0 (always 1 for this lineage).
    event LegacyStateMigrated(address indexed owner, uint8 legacyInitializedVersion);

    /// @notice Locks the implementation so nobody can initialize the logic contract itself.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Copies the OZ 4.x owner into the OZ 5.x Ownable namespace, marks the OZ 5.x Initializable
    ///         namespace as version 2, and zeroes the legacy slots 0 and 51.
    /// @dev `reinitializer(2)` writes version 2 into `openzeppelin.storage.Initializable`, so `initialize` of every
    ///      later version is permanently closed and the next version must use `reinitializer(3)` or higher. Only
    ///      the legacy owner may call it, which `upgradeToAndCall` from V1 guarantees in the same transaction.
    function migrateFromV4() external reinitializer(2) {
        uint8 legacyVersion = _legacyInitialized;
        bool legacyInitializing = _legacyInitializing;
        if (legacyVersion != 1 || legacyInitializing) revert LegacyStateInvalid(legacyVersion, legacyInitializing);

        address legacyOwner = _legacyOwner;
        // A zero legacy owner also fails here: msg.sender is never address(0).
        if (msg.sender != legacyOwner) revert NotLegacyOwner(msg.sender, legacyOwner);

        _legacyInitialized = 0;
        _legacyOwner = address(0);
        _transferOwnership(legacyOwner);

        emit LegacyStateMigrated(legacyOwner, legacyVersion);
    }

    /// @notice Semantic version of this implementation.
    /// @return The version string.
    function version() external pure returns (string memory) {
        return "1.5.0-bridge";
    }

    /// @notice Number of plans created (read-only during maintenance).
    /// @return The plan count.
    function planCount() external view returns (uint256) {
        return _planCount;
    }

    /// @notice Plan parameters (read-only during maintenance).
    /// @param planId The plan to read.
    /// @return duration Seconds of access per subscription.
    /// @return active Whether new subscriptions are accepted.
    function plan(uint256 planId) external view returns (uint64 duration, bool active) {
        Plan memory p = _plans[planId];
        return (p.duration, p.active);
    }

    /// @notice The subscription of an account (read-only during maintenance).
    /// @param subscriber The account to read.
    /// @return planId Plan subscribed to (0 when none).
    /// @return expiresAt Expiry timestamp (0 when none).
    function subscriptionOf(address subscriber) external view returns (uint256 planId, uint64 expiresAt) {
        Subscription memory s = _subscriptions[subscriber];
        return (s.planId, s.expiresAt);
    }

    /// @notice Whether the account currently has access, with V1 semantics (no grace period).
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

    /// @notice Disabled: renouncing here would strand the proxy on the bridge forever.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    /// @dev Upgrades are authorized by the migrated owner (`openzeppelin.storage.Ownable`).
    function _authorizeUpgrade(address) internal override onlyOwner {}
}
