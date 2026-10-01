// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {SubscriptionRegistryBridge} from "../../src/uups/bridge/SubscriptionRegistryBridge.sol";
import {SubscriptionRegistryV1} from "../../src/uups/v1/SubscriptionRegistryV1.sol";
import {SubscriptionRegistryV2} from "../../src/uups/v2/SubscriptionRegistryV2.sol";
import {SubscriptionRegistryV3} from "../../src/uups/v3/SubscriptionRegistryV3.sol";
import {LabBase} from "../utils/LabBase.sol";
import {MockERC20} from "../utils/Mocks.sol";
import {UpgradeChainHandler} from "./UpgradeChainHandler.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";

/// @notice Stateful upgrade fuzzing: arbitrary application traffic (free and paid subscriptions, plan pricing,
///         pause, two-step ownership transfers) interleaved with every upgrade sub-step (bridge, V2, scheduling,
///         cancelling, too-early and expired executions, the window with V3 code but no payment configuration,
///         `initializeV3`), checked against a ghost model after every call.
contract UpgradeChainInvariantTest is LabBase {
    UpgradeChainHandler internal handler;
    address internal proxy;
    MockERC20 internal token;

    function setUp() public {
        vm.warp(1_700_000_000);
        proxy = _deployV1(owner);
        AccessManager manager = _deployManager(governance, proxy);
        address[4] memory impls = [
            _implementation(proxy),
            address(new SubscriptionRegistryBridge()),
            address(new SubscriptionRegistryV2()),
            address(new SubscriptionRegistryV3())
        ];
        token = new MockERC20("Test USD", "TUSD");
        handler = new UpgradeChainHandler(
            proxy, owner, upgrader, guardian, manager, token, [treasury, makeAddr("treasury2")], UPGRADE_DELAY, impls
        );
        targetContract(address(handler));
        // Only the actions: the handler's many view getters would otherwise dilute the campaign.
        bytes4[] memory actions = new bytes4[](19);
        actions[0] = UpgradeChainHandler.createPlan.selector;
        actions[1] = UpgradeChainHandler.setPlanActive.selector;
        actions[2] = UpgradeChainHandler.setPlanPrice.selector;
        actions[3] = UpgradeChainHandler.subscribe.selector;
        actions[4] = UpgradeChainHandler.subscribeWithMaxPrice.selector;
        actions[5] = UpgradeChainHandler.cancel.selector;
        actions[6] = UpgradeChainHandler.setGracePeriod.selector;
        actions[7] = UpgradeChainHandler.setTreasury.selector;
        actions[8] = UpgradeChainHandler.pause.selector;
        actions[9] = UpgradeChainHandler.unpause.selector;
        actions[10] = UpgradeChainHandler.transferOwnership.selector;
        actions[11] = UpgradeChainHandler.acceptOwnership.selector;
        actions[12] = UpgradeChainHandler.warp.selector;
        actions[13] = UpgradeChainHandler.upgradeToBridge.selector;
        actions[14] = UpgradeChainHandler.upgradeToV2.selector;
        actions[15] = UpgradeChainHandler.scheduleV3.selector;
        actions[16] = UpgradeChainHandler.cancelV3.selector;
        actions[17] = UpgradeChainHandler.executeV3.selector;
        actions[18] = UpgradeChainHandler.initializeV3.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: actions}));
    }

    /// @dev Runs every invariant (the scripted walk below checks them after each step).
    function _checkAll() internal view {
        invariant_everyOutcomeMatchesTheModel();
        invariant_stateSurvivesEveryUpgrade();
        invariant_implementationOwnerAndVersionTrackTheStage();
        invariant_retiredSlotsStayZeroAndNoAdmin();
        invariant_paymentsMatchTheModel();
    }

    /// @notice Harness sanity check: a scripted walk through every stage and sub-stage, with traffic, failures and
    ///         the cancel, too-early and expired paths, keeps the model and every invariant in agreement. The random
    ///         campaign therefore cannot pass merely because it never leaves V1.
    function test_scriptedWalkThroughEverySubStage() public {
        uint256 asOwner = 1; // `_admin(1)` is the current owner
        handler.createPlan(asOwner, 30 days);
        handler.subscribe(0, 1);
        handler.transferOwnership(asOwner, 2); // V1: one-step transfer to person 2
        _checkAll();
        handler.upgradeToBridge(asOwner);
        handler.subscribe(0, 1); // maintenance mode: must fail
        handler.transferOwnership(asOwner, 3); // from the bridge on: a nomination
        handler.acceptOwnership(3);
        _checkAll();
        handler.upgradeToV2(asOwner);
        handler.pause(asOwner);
        handler.subscribe(1, 1); // paused: must fail
        handler.unpause(asOwner);
        handler.setGracePeriod(asOwner, 1 days);
        _checkAll();
        handler.scheduleV3();
        handler.scheduleV3(); // already scheduled: must fail
        handler.executeV3(0); // too early: must fail
        _checkAll();
        handler.cancelV3(); // guardian: back to V2
        handler.scheduleV3();
        handler.warp(30 days); // past readiness and expiration
        handler.executeV3(0); // expired: must fail, back to V2
        assertEq(handler.stage(), handler.V2());
        handler.scheduleV3();
        handler.executeV3(2); // one second early: must fail
        handler.executeV3(1); // exactly at readiness
        assertEq(handler.stage(), handler.V3_UNCONFIGURED());
        handler.setPlanPrice(asOwner, 1, 5e6); // payments not configured: must fail
        handler.subscribeWithMaxPrice(0, 1, 0); // free plan through the new entry point
        _checkAll();
        handler.initializeV3(asOwner);
        handler.initializeV3(asOwner); // once only
        handler.setPlanPrice(asOwner, 1, 5e6);
        handler.subscribe(0, 1); // priced plan through the one-argument subscribe: must fail
        handler.subscribeWithMaxPrice(0, 1, 2); // bound one below the price: must fail
        handler.subscribeWithMaxPrice(0, 1, 0); // pays
        handler.setTreasury(asOwner, 1);
        handler.subscribeWithMaxPrice(1, 1, 1); // pays the second treasury
        _checkAll();
        assertEq(handler.stage(), handler.V3());
        assertEq(handler.stageVisits(), 0x3f, "every stage visited");
        assertEq(handler.ghostRevenue(), 10e6);
    }

    /// @notice Invariant 1: every call succeeded or failed exactly as the model predicted.
    function invariant_everyOutcomeMatchesTheModel() public view {
        assertEq(handler.mismatches(), 0);
    }

    /// @notice Invariant 2: every plan, price, subscription and counter written at any stage is readable,
    ///         unchanged, through whichever implementation is live now.
    function invariant_stateSurvivesEveryUpgrade() public view {
        SubscriptionRegistryV1 r = SubscriptionRegistryV1(proxy); // read API shared by every stage
        uint256 stage = handler.stage();
        uint256 count = handler.ghostPlanCount();
        assertEq(r.planCount(), count, "planCount");
        for (uint256 id = 1; id <= count; ++id) {
            (uint64 duration, bool active) = r.plan(id);
            (uint64 gDuration, bool gActive, uint128 gPrice) = handler.ghostPlans(id);
            assertEq(duration, gDuration, "plan.duration");
            assertEq(active, gActive, "plan.active");
            if (stage >= handler.V3_UNCONFIGURED()) assertEq(SubscriptionRegistryV3(proxy).planPrice(id), gPrice);
        }
        assertEq(r.totalSubscriptions(), handler.ghostTotalSubscriptions(), "totalSubscriptions");
        uint256 grace = stage >= handler.V2() ? SubscriptionRegistryV2(proxy).gracePeriod() : 0;
        assertEq(grace, handler.ghostGracePeriod(), "gracePeriod");
        if (stage >= handler.V2()) assertEq(SubscriptionRegistryV2(proxy).paused(), handler.ghostPaused(), "paused");
        for (uint256 i = 1; i < 5; ++i) {
            address who = handler.personAt(i);
            (uint256 planId, uint64 expiresAt) = r.subscriptionOf(who);
            (uint256 gPlanId, uint64 gExpiresAt) = handler.ghostSubscription(who);
            assertEq(planId, gPlanId, "subscription.planId");
            assertEq(expiresAt, gExpiresAt, "subscription.expiresAt");
            bool expectedActive = gExpiresAt != 0 && vm.getBlockTimestamp() < uint256(gExpiresAt) + grace;
            assertEq(r.isActive(who), expectedActive, "isActive");
            if (stage >= handler.V2()) {
                assertEq(SubscriptionRegistryV2(proxy).renewalsOf(who), handler.ghostRenewals(who));
            }
        }
    }

    /// @notice Invariant 3: the proxy runs the implementation of its stage, the owner and pending owner follow the
    ///         model, the OZ 5.x `Initializable` namespace holds the version of each sub-stage (0 at V1, 2 at the
    ///         bridge, 3 at V2, while the V3 upgrade is pending and once V3 code runs unconfigured, 4 after
    ///         `initializeV3`), and a pending upgrade is visible on the manager until it expires.
    function invariant_implementationOwnerAndVersionTrackTheStage() public view {
        uint256 stage = handler.stage();
        assertEq(_implementation(proxy), handler.expectedImplementation(), "implementation");
        assertEq(SubscriptionRegistryV1(proxy).owner(), handler.ghostOwner(), "owner");
        if (stage >= handler.BRIDGE()) {
            assertEq(SubscriptionRegistryBridge(proxy).pendingOwner(), handler.ghostPendingOwner(), "pendingOwner");
        }
        uint64[6] memory versions = [uint64(0), 2, 3, 3, 3, 4];
        assertEq(uint64(uint256(vm.load(proxy, OZ_INITIALIZABLE_SLOT))), versions[stage], "initialized version");
        string[6] memory names = ["1.0.0", "1.5.0-bridge", "2.0.0", "2.0.0", "3.0.0", "3.0.0"];
        assertEq(SubscriptionRegistryV1(proxy).version(), names[stage], "version()");
        if (stage == handler.V3_PENDING()) {
            AccessManager manager = handler.manager();
            uint256 readyAt = handler.readyAt();
            bool expired = vm.getBlockTimestamp() >= readyAt + manager.expiration();
            assertEq(manager.getSchedule(handler.upgradeOperation()), expired ? 0 : readyAt, "pending upgrade");
        }
    }

    /// @notice Invariant 4: once the bridge ran, the OZ 4.x slots 0 and 51 are zero forever, and a UUPS proxy
    ///         never has an ERC-1967 admin.
    function invariant_retiredSlotsStayZeroAndNoAdmin() public view {
        if (handler.stage() >= handler.BRIDGE()) {
            assertEq(vm.load(proxy, LEGACY_INITIALIZABLE_SLOT), bytes32(0), "legacy slot 0");
            assertEq(vm.load(proxy, LEGACY_OWNER_SLOT), bytes32(0), "legacy slot 51");
        }
        assertEq(vm.load(proxy, ADMIN_SLOT), bytes32(0), "admin slot");
    }

    /// @notice Invariant 5: payments are configured exactly from `initializeV3` on, every payment reached the
    ///         treasury of its time, nothing stays in the registry, and every subscriber paid exactly its prices.
    function invariant_paymentsMatchTheModel() public view {
        uint256 stage = handler.stage();
        if (stage >= handler.V3_UNCONFIGURED()) {
            SubscriptionRegistryV3 v3 = SubscriptionRegistryV3(proxy);
            bool configured = stage == handler.V3();
            assertEq(v3.paymentToken(), configured ? address(token) : address(0), "paymentToken");
            assertEq(v3.treasury(), configured ? handler.treasuries(handler.ghostTreasury()) : address(0), "treasury");
            assertEq(v3.totalRevenue(), handler.ghostRevenue(), "totalRevenue");
        }
        for (uint256 i; i < 2; ++i) {
            address t = handler.treasuries(i);
            assertEq(token.balanceOf(t), handler.ghostReceived(t), "treasury balance");
        }
        for (uint256 i = 1; i < 5; ++i) {
            address who = handler.personAt(i);
            assertEq(token.balanceOf(who), 1e30 - handler.ghostPaid(who), "subscriber balance");
        }
        assertEq(token.balanceOf(proxy), 0, "the registry holds no funds");
    }
}
