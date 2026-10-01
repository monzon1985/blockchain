// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ISubscriptionRegistry} from "../../src/interfaces/IRegistry.sol";
import {SubscriptionRegistryBridge} from "../../src/uups/bridge/SubscriptionRegistryBridge.sol";
import {SubscriptionRegistryV2} from "../../src/uups/v2/SubscriptionRegistryV2.sol";
import {LabBase} from "../utils/LabBase.sol";
import {MockERC20} from "../utils/Mocks.sol";

/// @notice After the bridge, slots 0..200 (the OZ 4.9.6 parents' region) are dead: neither V2 nor V3 reads or
///         writes them through any function of its API, and the bridge touches exactly slots 0 and 51 in that region.
contract RetiredSlotsTest is LabBase {
    uint256 internal constant LEGACY_REGION_END = 201;

    function _assertNoLegacyAccess(address target, string memory context) internal view {
        (bytes32[] memory reads, bytes32[] memory writes) = vm.accesses(target);
        for (uint256 i; i < reads.length; ++i) {
            assertGe(uint256(reads[i]), LEGACY_REGION_END, string.concat(context, ": read of a retired slot"));
        }
        for (uint256 i; i < writes.length; ++i) {
            assertGe(uint256(writes[i]), LEGACY_REGION_END, string.concat(context, ": write of a retired slot"));
        }
    }

    function test_v2ApiNeverTouchesRetiredSlots() public {
        vm.warp(1_700_000_000);
        address proxy = _deployV1(owner);
        _migrateToV2(proxy, _deployManager(governance, proxy));
        SubscriptionRegistryV2 reg = SubscriptionRegistryV2(proxy);
        address alice = makeAddr("alice");

        vm.record();
        vm.startPrank(owner);
        reg.createPlan(30 days);
        reg.setPlanActive(1, true);
        reg.setGracePeriod(1 days);
        reg.pause();
        reg.unpause();
        reg.transferOwnership(alice);
        vm.stopPrank();
        vm.startPrank(alice);
        reg.acceptOwnership();
        reg.subscribe(1);
        reg.subscribe(1);
        reg.cancel();
        vm.stopPrank();
        reg.planCount();
        reg.plan(1);
        reg.subscriptionOf(alice);
        reg.isActive(alice);
        reg.renewalsOf(alice);
        reg.totalSubscriptions();
        reg.gracePeriod();
        reg.paused();
        reg.owner();
        reg.pendingOwner();
        reg.authority();
        reg.version();
        _assertNoLegacyAccess(proxy, "V2 API");
    }

    function test_v3ApiNeverTouchesRetiredSlots() public {
        vm.warp(1_700_000_000);
        MockERC20 token = new MockERC20("Test USD", "TUSD");
        (address proxy,) = _deployV3ThroughChain(token);
        ISubscriptionRegistry reg = ISubscriptionRegistry(proxy);
        address alice = makeAddr("alice");
        token.mint(alice, 1e18);
        vm.prank(alice);
        token.approve(proxy, type(uint256).max);

        vm.record();
        vm.startPrank(owner);
        reg.createPlan(30 days);
        reg.setPlanActive(1, true);
        reg.setPlanPrice(1, 5e6);
        reg.setGracePeriod(1 days);
        reg.setTreasury(treasury);
        reg.pause();
        reg.unpause();
        reg.transferOwnership(alice);
        vm.stopPrank();
        vm.startPrank(alice);
        reg.acceptOwnership();
        reg.subscribeWithMaxPrice(1, 5e6);
        reg.subscribeWithMaxPrice(1, 5e6);
        reg.cancel();
        reg.setPlanPrice(1, 0);
        reg.subscribe(1);
        vm.stopPrank();
        reg.planCount();
        reg.plan(1);
        reg.planPrice(1);
        reg.subscriptionOf(alice);
        reg.isActive(alice);
        reg.renewalsOf(alice);
        reg.totalSubscriptions();
        reg.gracePeriod();
        reg.paused();
        reg.paymentToken();
        reg.treasury();
        reg.totalRevenue();
        reg.owner();
        reg.pendingOwner();
        _assertNoLegacyAccess(proxy, "V3 API");
    }

    function test_bridgeTouchesOnlySlots0And51OfTheLegacyRegion() public {
        address proxy = _deployV1(owner);
        SubscriptionRegistryBridge bridge = new SubscriptionRegistryBridge();
        vm.record();
        vm.prank(owner);
        SubscriptionRegistryBridge(proxy)
            .upgradeToAndCall(address(bridge), abi.encodeCall(SubscriptionRegistryBridge.migrateFromV4, ()));
        (, bytes32[] memory writes) = vm.accesses(proxy);
        uint256 legacyWrites;
        for (uint256 i; i < writes.length; ++i) {
            uint256 slot = uint256(writes[i]);
            if (slot < LEGACY_REGION_END) {
                assertTrue(slot == 0 || slot == 51, "unexpected legacy write");
                ++legacyWrites;
            }
        }
        assertGt(legacyWrites, 0);
    }
}
