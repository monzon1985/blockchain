// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IRegistryErrors, IRegistryEvents, RegistryLimits} from "../../src/interfaces/IRegistry.sol";
import {SubscriptionRegistryV1} from "../../src/uups/v1/SubscriptionRegistryV1.sol";
import {IUUPS, LabBase} from "../utils/LabBase.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice Unit tests of the legacy V1 (OpenZeppelin 4.9.6) registry: happy paths and every revert path.
contract SubscriptionRegistryV1Test is LabBase, IRegistryEvents {
    SubscriptionRegistryV1 internal reg;
    address internal alice = makeAddr("alice");

    function setUp() public {
        vm.warp(1_700_000_000);
        reg = SubscriptionRegistryV1(_deployV1(owner));
    }

    function test_initialize_setsOwnerAndVersion() public view {
        assertEq(reg.owner(), owner);
        assertEq(reg.version(), "1.0.0");
        // Sequential layout: owner at slot 51, initialized version 1 at slot 0.
        assertEq(address(uint160(uint256(vm.load(address(reg), LEGACY_OWNER_SLOT)))), owner);
        assertEq(uint256(vm.load(address(reg), LEGACY_INITIALIZABLE_SLOT)), 1);
    }

    function test_initialize_rejectsZeroOwner() public {
        SubscriptionRegistryV1 impl = new SubscriptionRegistryV1();
        vm.expectRevert(abi.encodeWithSelector(IRegistryErrors.InvalidOwner.selector, address(0)));
        new ERC1967Proxy(address(impl), abi.encodeCall(SubscriptionRegistryV1.initialize, (address(0))));
    }

    function test_initialize_onlyOnce() public {
        vm.expectRevert("Initializable: contract is already initialized");
        reg.initialize(alice);
    }

    function test_implementation_isLocked() public {
        SubscriptionRegistryV1 impl = SubscriptionRegistryV1(_implementation(address(reg)));
        vm.expectRevert("Initializable: contract is already initialized");
        impl.initialize(alice);
        vm.expectRevert("Function must be called through delegatecall");
        impl.upgradeToAndCall(address(impl), "");
    }

    function test_createPlan_andViews() public {
        vm.expectEmit(address(reg));
        emit PlanCreated(1, 30 days);
        vm.prank(owner);
        assertEq(reg.createPlan(30 days), 1);
        assertEq(reg.planCount(), 1);
        (uint64 duration, bool active) = reg.plan(1);
        assertEq(duration, 30 days);
        assertTrue(active);
    }

    function test_createPlan_reverts() public {
        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(alice);
        reg.createPlan(30 days);

        vm.startPrank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(IRegistryErrors.InvalidDuration.selector, 0, RegistryLimits.MAX_DURATION)
        );
        reg.createPlan(0);
        uint64 tooLong = RegistryLimits.MAX_DURATION + 1;
        vm.expectRevert(
            abi.encodeWithSelector(IRegistryErrors.InvalidDuration.selector, tooLong, RegistryLimits.MAX_DURATION)
        );
        reg.createPlan(tooLong);
        vm.stopPrank();
    }

    function test_setPlanActive() public {
        vm.startPrank(owner);
        reg.createPlan(30 days);
        vm.expectEmit(address(reg));
        emit PlanStatusChanged(1, false);
        reg.setPlanActive(1, false);
        vm.expectRevert(abi.encodeWithSelector(IRegistryErrors.UnknownPlan.selector, 2, 1));
        reg.setPlanActive(2, true);
        vm.stopPrank();
        (, bool active) = reg.plan(1);
        assertFalse(active);

        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(alice);
        reg.setPlanActive(1, true);
    }

    function test_subscribe_freshRenewalSwitchAndCancel() public {
        vm.startPrank(owner);
        reg.createPlan(30 days);
        reg.createPlan(7 days);
        vm.stopPrank();

        uint64 start = uint64(vm.getBlockTimestamp());
        vm.expectEmit(address(reg));
        emit Subscribed(alice, 1, start + 30 days, false);
        vm.prank(alice);
        assertEq(reg.subscribe(1), start + 30 days);
        assertTrue(reg.isActive(alice));

        vm.warp(start + 1 days);
        vm.prank(alice);
        assertEq(reg.subscribe(1), start + 60 days, "renewal stacks");

        vm.prank(alice);
        assertEq(reg.subscribe(2), start + 1 days + 7 days, "switch restarts");
        assertEq(reg.totalSubscriptions(), 3);

        vm.warp(start + 1 days + 7 days);
        assertFalse(reg.isActive(alice), "expiresAt is exclusive");

        vm.expectEmit(address(reg));
        emit SubscriptionCancelled(alice, 2);
        vm.prank(alice);
        reg.cancel();
        (uint256 planId, uint64 expiresAt) = reg.subscriptionOf(alice);
        assertEq(planId, 0);
        assertEq(expiresAt, 0);
    }

    function test_subscribe_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IRegistryErrors.UnknownPlan.selector, 0, 0));
        vm.prank(alice);
        reg.subscribe(0);

        vm.startPrank(owner);
        reg.createPlan(30 days);
        reg.setPlanActive(1, false);
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(IRegistryErrors.PlanInactive.selector, 1));
        vm.prank(alice);
        reg.subscribe(1);
    }

    function test_cancel_revertsWithoutSubscription() public {
        vm.expectRevert(abi.encodeWithSelector(IRegistryErrors.NoSubscription.selector, alice));
        vm.prank(alice);
        reg.cancel();
    }

    function test_upgrade_onlyOwner() public {
        address next = address(new SubscriptionRegistryV1());
        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(alice);
        reg.upgradeTo(next);

        // OZ 4.x quirk: upgradeToAndCall with empty data still delegatecalls (forceCall) and fails without a
        // fallback on the new implementation; `upgradeTo` is the no-call path.
        vm.expectRevert("Address: low-level delegate call failed");
        vm.prank(owner);
        IUUPS(address(reg)).upgradeToAndCall(next, "");

        vm.prank(owner);
        reg.upgradeTo(next);
        assertEq(_implementation(address(reg)), next);
    }

    function test_rawSlots_matchTheDocumentedLayout() public {
        vm.startPrank(owner);
        reg.createPlan(30 days);
        reg.createPlan(90 days);
        vm.stopPrank();
        vm.prank(alice);
        uint64 expiresAt = reg.subscribe(2);

        // slot 201 = _planCount (bytes 0..7) | _totalSubscriptions (bytes 8..15)
        uint256 counters = uint256(vm.load(address(reg), APP_COUNTERS_SLOT));
        assertEq(uint64(counters), 2);
        assertEq(uint64(counters >> 64), 1);
        // _plans[2] at keccak256(2 . 202) = duration | active << 64
        bytes32 planSlot = keccak256(abi.encode(uint256(2), PLANS_MAPPING_SLOT));
        assertEq(uint256(vm.load(address(reg), planSlot)), uint256(90 days) | (uint256(1) << 64));
        // _subscriptions[alice] at keccak256(alice . 203) = planId | expiresAt << 64
        bytes32 subSlot = keccak256(abi.encode(alice, SUBSCRIPTIONS_MAPPING_SLOT));
        assertEq(uint256(vm.load(address(reg), subSlot)), 2 | (uint256(expiresAt) << 64));
    }
}
