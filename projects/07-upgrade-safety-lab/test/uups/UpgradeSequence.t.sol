// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {SubscriptionRegistryBridge} from "../../src/uups/bridge/SubscriptionRegistryBridge.sol";
import {SubscriptionRegistryV1} from "../../src/uups/v1/SubscriptionRegistryV1.sol";
import {SubscriptionRegistryV2} from "../../src/uups/v2/SubscriptionRegistryV2.sol";
import {SubscriptionRegistryV3} from "../../src/uups/v3/SubscriptionRegistryV3.sol";
import {IUUPS, LabBase} from "../utils/LabBase.sol";
import {MockERC20} from "../utils/Mocks.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";

/// @notice The supported lineage V1 -> bridge -> V2 -> V3 with storage sentinels: every value written by V1
///         (through its public API) is read back after every step, both through the ABI and as raw slots.
contract UpgradeSequenceTest is LabBase {
    event Upgraded(address indexed implementation);

    address internal proxy;
    AccessManager internal manager;
    MockERC20 internal token;

    address[] internal subscribers;
    uint256[] internal subscriberPlan;
    uint64[] internal subscriberExpiry;
    uint64[] internal planDurations;
    bool[] internal planActive;
    uint64 internal totalSubscriptionsSentinel;
    bytes32[] internal rawSentinelSlots;
    bytes32[] internal rawSentinelValues;

    function setUp() public {
        vm.warp(1_700_000_000);
        token = new MockERC20("Test USD", "TUSD");
        proxy = _deployV1(owner);
        manager = _deployManager(governance, proxy);
    }

    // ------------------------------------------------------------------ sentinel helpers

    function _seedV1(uint64[] memory durations, uint256 subscriberCount, uint256 seed) internal {
        SubscriptionRegistryV1 v1 = SubscriptionRegistryV1(proxy);
        vm.startPrank(owner);
        for (uint256 i; i < durations.length; ++i) {
            v1.createPlan(durations[i]);
            planDurations.push(durations[i]);
            planActive.push(true);
        }
        vm.stopPrank();
        for (uint256 i; i < subscriberCount; ++i) {
            address who = address(uint160(uint256(keccak256(abi.encode("subscriber", seed, i)))));
            uint256 planId = 1 + (uint256(keccak256(abi.encode(seed, i))) % durations.length);
            vm.warp(vm.getBlockTimestamp() + (uint256(keccak256(abi.encode(seed, i, "t"))) % 3 days));
            vm.prank(who);
            uint64 expiresAt = v1.subscribe(planId);
            if (uint256(keccak256(abi.encode(seed, i, "renew"))) % 2 == 0) {
                vm.prank(who);
                expiresAt = v1.subscribe(planId);
                ++totalSubscriptionsSentinel;
            }
            ++totalSubscriptionsSentinel;
            subscribers.push(who);
            subscriberPlan.push(planId);
            subscriberExpiry.push(expiresAt);
        }
        if (durations.length > 1) {
            vm.prank(owner);
            v1.setPlanActive(durations.length, false);
            planActive[durations.length - 1] = false;
        }
        // Raw sentinels: the counters word and every mapping slot the V1 API wrote.
        rawSentinelSlots.push(APP_COUNTERS_SLOT);
        for (uint256 id = 1; id <= durations.length; ++id) {
            rawSentinelSlots.push(keccak256(abi.encode(id, PLANS_MAPPING_SLOT)));
        }
        for (uint256 i; i < subscribers.length; ++i) {
            rawSentinelSlots.push(keccak256(abi.encode(subscribers[i], SUBSCRIPTIONS_MAPPING_SLOT)));
        }
        for (uint256 i; i < rawSentinelSlots.length; ++i) {
            rawSentinelValues.push(vm.load(proxy, rawSentinelSlots[i]));
        }
    }

    function _assertSentinels(string memory stage) internal view {
        SubscriptionRegistryV1 r = SubscriptionRegistryV1(proxy); // the V1 read API is a subset of every version
        assertEq(r.planCount(), planDurations.length, stage);
        for (uint256 i; i < planDurations.length; ++i) {
            (uint64 duration, bool active) = r.plan(i + 1);
            assertEq(duration, planDurations[i], stage);
            assertEq(active, planActive[i], stage);
        }
        for (uint256 i; i < subscribers.length; ++i) {
            (uint256 planId, uint64 expiresAt) = r.subscriptionOf(subscribers[i]);
            assertEq(planId, subscriberPlan[i], stage);
            assertEq(expiresAt, subscriberExpiry[i], stage);
        }
        assertEq(r.totalSubscriptions(), totalSubscriptionsSentinel, stage);
        for (uint256 i; i < rawSentinelSlots.length; ++i) {
            assertEq(vm.load(proxy, rawSentinelSlots[i]), rawSentinelValues[i], stage);
        }
        // UUPS proxies carry no ERC-1967 admin.
        assertEq(vm.load(proxy, ADMIN_SLOT), bytes32(0), stage);
    }

    // ------------------------------------------------------------------ the lineage

    function test_fullLineagePreservesEverySentinel() public {
        uint64[] memory durations = new uint64[](3);
        durations[0] = 30 days;
        durations[1] = 365 days;
        durations[2] = 7 days;
        _seedV1(durations, 12, 42);
        _assertSentinels("v1");
        assertEq(SubscriptionRegistryV1(proxy).version(), "1.0.0");

        // Step 1: V1 -> bridge, migrating the OZ 4.x state in the same transaction.
        SubscriptionRegistryBridge bridge = new SubscriptionRegistryBridge();
        vm.expectEmit(proxy);
        emit Upgraded(address(bridge));
        vm.prank(owner);
        SubscriptionRegistryV1(proxy)
            .upgradeToAndCall(address(bridge), abi.encodeCall(SubscriptionRegistryBridge.migrateFromV4, ()));
        _assertSentinels("bridge");
        assertEq(_implementation(proxy), address(bridge));
        assertEq(SubscriptionRegistryBridge(proxy).version(), "1.5.0-bridge");
        assertEq(SubscriptionRegistryBridge(proxy).owner(), owner);

        // Step 2: bridge -> V2, owner-authorized, wiring the AccessManager.
        SubscriptionRegistryV2 v2 = new SubscriptionRegistryV2();
        vm.prank(owner);
        IUUPS(proxy)
            .upgradeToAndCall(address(v2), abi.encodeCall(SubscriptionRegistryV2.initializeV2, (address(manager))));
        _assertSentinels("v2");
        assertEq(_implementation(proxy), address(v2));
        assertEq(SubscriptionRegistryV2(proxy).version(), "2.0.0");
        assertEq(SubscriptionRegistryV2(proxy).owner(), owner);
        assertEq(SubscriptionRegistryV2(proxy).authority(), address(manager));
        assertEq(uint64(uint256(vm.load(proxy, OZ_INITIALIZABLE_SLOT))), 3);

        // V2 writes new state only into its namespace.
        vm.prank(owner);
        SubscriptionRegistryV2(proxy).setGracePeriod(2 days);
        _assertSentinels("v2 after namespace write");

        // Step 3: V2 -> V3 through the AccessManager delay, then payments.
        _upgradeToV3(proxy, manager, token);
        _assertSentinels("v3");
        SubscriptionRegistryV3 v3 = SubscriptionRegistryV3(proxy);
        assertEq(v3.version(), "3.0.0");
        assertEq(v3.owner(), owner);
        assertEq(v3.gracePeriod(), 2 days, "V2 namespace member survives V3 append");
        assertEq(v3.paymentToken(), address(token));
        assertEq(uint64(uint256(vm.load(proxy, OZ_INITIALIZABLE_SLOT))), 4);

        // Legacy OZ 4.x slots stay zero forever after the bridge.
        assertEq(vm.load(proxy, LEGACY_INITIALIZABLE_SLOT), bytes32(0));
        assertEq(vm.load(proxy, LEGACY_OWNER_SLOT), bytes32(0));
    }

    /// @notice Fuzzed V1 state (plan set, subscriber count, timing, renewals) must survive every step.
    function testFuzz_stateSurvivesEveryUpgrade(uint64[4] memory rawDurations, uint8 rawSubscribers, uint256 seed)
        public
    {
        uint256 planCount = 1 + (seed % 4);
        uint64[] memory durations = new uint64[](planCount);
        for (uint256 i; i < planCount; ++i) {
            durations[i] = uint64(bound(rawDurations[i], 1 hours, 3650 days));
        }
        _seedV1(durations, bound(rawSubscribers, 1, 16), seed);
        _assertSentinels("v1");

        _migrateToV2(proxy, manager);
        _assertSentinels("v2");

        _upgradeToV3(proxy, manager, token);
        _assertSentinels("v3");

        // Existing subscribers keep renewing on V3 exactly as they did on V1.
        SubscriptionRegistryV3 v3 = SubscriptionRegistryV3(proxy);
        address first = subscribers[0];
        (uint256 planId, uint64 expiresAt) = v3.subscriptionOf(first);
        (uint64 duration, bool active) = v3.plan(planId);
        if (active && expiresAt > vm.getBlockTimestamp()) {
            vm.prank(first);
            assertEq(v3.subscribe(planId), expiresAt + duration);
            assertEq(v3.renewalsOf(first), 1);
        }
    }
}
