// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IRegistryErrors} from "../../src/interfaces/IRegistry.sol";
import {SubscriptionRegistryBridge} from "../../src/uups/bridge/SubscriptionRegistryBridge.sol";
import {SubscriptionRegistryV1} from "../../src/uups/v1/SubscriptionRegistryV1.sol";
import {SubscriptionRegistryV2} from "../../src/uups/v2/SubscriptionRegistryV2.sol";
import {IUUPS, LabBase} from "../utils/LabBase.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

/// @notice The escape hatch: `migrateFromV4` moves the OZ 4.x owner and initialized version into the OZ 5.x
///         namespaces, zeroes the legacy slots, and every misuse reverts.
contract SubscriptionRegistryBridgeTest is LabBase {
    address internal proxy;
    SubscriptionRegistryBridge internal bridge;
    address internal attacker = makeAddr("attacker");

    event LegacyStateMigrated(address indexed owner, uint8 legacyInitializedVersion);
    event Initialized(uint64 version);

    function setUp() public {
        proxy = _deployV1(owner);
        bridge = new SubscriptionRegistryBridge();
    }

    /// @dev OZ 4.x quirk: `upgradeToAndCall(impl, "")` still delegatecalls `impl` with empty calldata (forceCall),
    ///      which reverts on an implementation without a fallback. An upgrade without a call is `upgradeTo`.
    function _upgradeToBridge(bytes memory data) internal {
        vm.prank(owner);
        if (data.length == 0) SubscriptionRegistryV1(proxy).upgradeTo(address(bridge));
        else SubscriptionRegistryV1(proxy).upgradeToAndCall(address(bridge), data);
    }

    function test_migrateFromV4_copiesOwnerAndInitializedThenZeroesLegacySlots() public {
        vm.expectEmit(proxy);
        emit LegacyStateMigrated(owner, 1);
        vm.expectEmit(proxy);
        emit Initialized(2);
        _upgradeToBridge(abi.encodeCall(SubscriptionRegistryBridge.migrateFromV4, ()));

        SubscriptionRegistryBridge b = SubscriptionRegistryBridge(proxy);
        assertEq(b.owner(), owner);
        assertEq(b.version(), "1.5.0-bridge");
        // New homes: OZ 5.x namespaces.
        assertEq(address(uint160(uint256(vm.load(proxy, OZ_OWNABLE_SLOT)))), owner);
        assertEq(uint64(uint256(vm.load(proxy, OZ_INITIALIZABLE_SLOT))), 2);
        // Old homes: zeroed.
        assertEq(vm.load(proxy, LEGACY_INITIALIZABLE_SLOT), bytes32(0));
        assertEq(vm.load(proxy, LEGACY_OWNER_SLOT), bytes32(0));
    }

    function test_migrateFromV4_onlyLegacyOwner() public {
        // Upgrading without calldata is a mistake the bridge survives: the migration can only be triggered by
        // the legacy owner, so a front-runner gains nothing.
        _upgradeToBridge("");
        vm.expectRevert(abi.encodeWithSelector(SubscriptionRegistryBridge.NotLegacyOwner.selector, attacker, owner));
        vm.prank(attacker);
        SubscriptionRegistryBridge(proxy).migrateFromV4();

        vm.prank(owner);
        SubscriptionRegistryBridge(proxy).migrateFromV4();
        assertEq(SubscriptionRegistryBridge(proxy).owner(), owner);
    }

    function test_migrateFromV4_runsOnlyOnce() public {
        _upgradeToBridge(abi.encodeCall(SubscriptionRegistryBridge.migrateFromV4, ()));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vm.prank(owner);
        SubscriptionRegistryBridge(proxy).migrateFromV4();
    }

    function test_migrateFromV4_rejectsUnexpectedLegacyState() public {
        _upgradeToBridge("");
        // Legacy slot 0 claims "initializing" (a corrupted or mid-initialization proxy).
        vm.store(proxy, LEGACY_INITIALIZABLE_SLOT, bytes32(uint256(1) | (uint256(1) << 8)));
        vm.expectRevert(abi.encodeWithSelector(SubscriptionRegistryBridge.LegacyStateInvalid.selector, 1, true));
        vm.prank(owner);
        SubscriptionRegistryBridge(proxy).migrateFromV4();

        // Legacy slot 0 says "never initialized".
        vm.store(proxy, LEGACY_INITIALIZABLE_SLOT, bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(SubscriptionRegistryBridge.LegacyStateInvalid.selector, 0, false));
        vm.prank(owner);
        SubscriptionRegistryBridge(proxy).migrateFromV4();
    }

    function test_bridge_upgradeOnlyByMigratedOwner() public {
        _upgradeToBridge(abi.encodeCall(SubscriptionRegistryBridge.migrateFromV4, ()));
        SubscriptionRegistryV2 v2 = new SubscriptionRegistryV2();
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        vm.prank(attacker);
        IUUPS(proxy).upgradeToAndCall(address(v2), "");
    }

    function test_bridge_servesReadsAndRejectsWrites() public {
        vm.warp(1_700_000_000);
        vm.prank(owner);
        SubscriptionRegistryV1(proxy).createPlan(30 days);
        vm.prank(attacker);
        uint64 expiresAt = SubscriptionRegistryV1(proxy).subscribe(1);
        _upgradeToBridge(abi.encodeCall(SubscriptionRegistryBridge.migrateFromV4, ()));

        SubscriptionRegistryBridge b = SubscriptionRegistryBridge(proxy);
        assertEq(b.planCount(), 1);
        (uint64 duration, bool active) = b.plan(1);
        assertEq(duration, 30 days);
        assertTrue(active);
        (uint256 planId, uint64 storedExpiry) = b.subscriptionOf(attacker);
        assertEq(planId, 1);
        assertEq(storedExpiry, expiresAt);
        assertTrue(b.isActive(attacker));
        assertEq(b.totalSubscriptions(), 1);

        // Writes do not exist on the bridge.
        vm.expectRevert();
        vm.prank(attacker);
        SubscriptionRegistryV1(proxy).subscribe(1);
    }

    function test_bridge_renounceDisabled() public {
        _upgradeToBridge(abi.encodeCall(SubscriptionRegistryBridge.migrateFromV4, ()));
        vm.expectRevert(IRegistryErrors.RenounceDisabled.selector);
        vm.prank(owner);
        SubscriptionRegistryBridge(proxy).renounceOwnership();
    }

    function test_bridge_implementationIsLocked() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        bridge.migrateFromV4();
        vm.expectRevert(UUPSUpgradeable.UUPSUnauthorizedCallContext.selector);
        bridge.upgradeToAndCall(address(bridge), "");
        assertEq(bridge.proxiableUUID(), IMPLEMENTATION_SLOT);
    }

    function test_initializeV2_requiresOwnerAndCode() public {
        _upgradeToBridge(abi.encodeCall(SubscriptionRegistryBridge.migrateFromV4, ()));
        AccessManager manager = _deployManager(governance, proxy);
        SubscriptionRegistryV2 v2 = new SubscriptionRegistryV2();

        // An upgrade with empty calldata leaves initializeV2 open, but only to the owner.
        vm.prank(owner);
        IUUPS(proxy).upgradeToAndCall(address(v2), "");
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        vm.prank(attacker);
        SubscriptionRegistryV2(proxy).initializeV2(address(manager));

        vm.expectRevert(abi.encodeWithSelector(IRegistryErrors.InvalidAuthority.selector, attacker));
        vm.prank(owner);
        SubscriptionRegistryV2(proxy).initializeV2(attacker);

        vm.prank(owner);
        SubscriptionRegistryV2(proxy).initializeV2(address(manager));
        assertEq(SubscriptionRegistryV2(proxy).authority(), address(manager));

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vm.prank(owner);
        SubscriptionRegistryV2(proxy).initializeV2(address(manager));
    }
}
