// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {RegistryLimits} from "../../src/interfaces/IRegistry.sol";
import {SubscriptionRegistryBridge} from "../../src/uups/bridge/SubscriptionRegistryBridge.sol";
import {SubscriptionRegistryV1} from "../../src/uups/v1/SubscriptionRegistryV1.sol";
import {SubscriptionRegistryV2} from "../../src/uups/v2/SubscriptionRegistryV2.sol";
import {SubscriptionRegistryV3} from "../../src/uups/v3/SubscriptionRegistryV3.sol";
import {IUUPS} from "../utils/LabBase.sol";
import {MockERC20} from "../utils/Mocks.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

/// @notice Interleaves application traffic (free and paid subscriptions, plan administration, pause, ownership
///         transfers, time) with every upgrade sub-step of the lineage, and keeps a ghost model of what the registry
///         must contain. Every call's success flag is predicted by the model; any disagreement is recorded (the
///         handler itself never reverts).
/// @dev Stages: V1, BRIDGE (maintenance: reads only), V2, V3_PENDING (V2 code, V3 upgrade scheduled, traffic goes
///      on), V3_UNCONFIGURED (V3 code executed by the manager, payments not configured yet, Initializable version
///      still 3) and V3 (`initializeV3` done, version 4). A scheduled upgrade can be cancelled by the guardian or
///      expire, both of which return to V2.
contract UpgradeChainHandler is CommonBase, StdUtils {
    uint256 public constant V1 = 0;
    uint256 public constant BRIDGE = 1;
    uint256 public constant V2 = 2;
    uint256 public constant V3_PENDING = 3;
    uint256 public constant V3_UNCONFIGURED = 4;
    uint256 public constant V3 = 5;

    struct GhostPlan {
        uint64 duration;
        bool active;
        uint128 price;
    }

    struct GhostSub {
        uint256 planId;
        uint64 expiresAt;
    }

    address public immutable proxy;
    address public immutable upgrader;
    address public immutable guardian;
    AccessManager public immutable manager;
    MockERC20 public immutable token;
    uint32 public immutable upgradeDelay;
    /// @notice Logic by code generation: V1, bridge, V2, V3.
    address[4] public implementations;
    /// @notice The two accounts `setTreasury` alternates between (index 0 is the one `initializeV3` sets).
    address[2] public treasuries;

    uint256 public stage;
    uint256 public mismatches;
    uint256 public calls;
    uint256 public stageVisits; // bit i set once stage i was reached

    address public ghostOwner;
    address public ghostPendingOwner;
    bool public ghostPaused;
    uint256 public ghostPlanCount;
    mapping(uint256 => GhostPlan) public ghostPlans;
    mapping(address => GhostSub) internal ghostSubs;
    mapping(address => uint32) public ghostRenewals;
    mapping(address => uint256) public ghostPaid;
    uint64 public ghostTotalSubscriptions;
    uint64 public ghostGracePeriod;
    uint256 public ghostRevenue;
    uint256 public ghostTreasury; // index into `treasuries`
    mapping(address => uint256) public ghostReceived;
    uint48 public readyAt; // when the scheduled V3 upgrade becomes executable (V3_PENDING only)

    address[5] internal people; // the initial owner and four subscribers; any of them may come to own the proxy

    uint256 internal constant FUNDING = 1e30;

    constructor(
        address proxy_,
        address owner_,
        address upgrader_,
        address guardian_,
        AccessManager manager_,
        MockERC20 token_,
        address[2] memory treasuries_,
        uint32 upgradeDelay_,
        address[4] memory implementations_
    ) {
        proxy = proxy_;
        upgrader = upgrader_;
        guardian = guardian_;
        manager = manager_;
        token = token_;
        treasuries = treasuries_;
        upgradeDelay = upgradeDelay_;
        implementations = implementations_;
        ghostOwner = owner_;
        people[0] = owner_;
        for (uint256 i = 1; i < 5; ++i) {
            address actor = address(uint160(0x5AB5C0 + i));
            people[i] = actor;
            token_.mint(actor, FUNDING);
            vm.prank(actor);
            token_.approve(proxy_, type(uint256).max);
        }
        stageVisits = 1;
    }

    function personAt(uint256 i) external view returns (address) {
        return people[i];
    }

    function ghostSubscription(address who) external view returns (uint256 planId, uint64 expiresAt) {
        GhostSub memory g = ghostSubs[who];
        return (g.planId, g.expiresAt);
    }

    /// @notice The implementation the proxy must run at the current stage.
    function expectedImplementation() external view returns (address) {
        uint256[6] memory code = [uint256(0), 1, 2, 2, 3, 3];
        return implementations[code[stage]];
    }

    /// @notice The scheduled V3 upgrade's operation id.
    function upgradeOperation() public view returns (bytes32) {
        return manager.hashOperation(upgrader, proxy, _v3UpgradeCall());
    }

    // ------------------------------------------------------------------ application traffic

    function createPlan(uint256 adminSeed, uint64 duration) external {
        address caller = _admin(adminSeed);
        duration = uint64(bound(duration, 0, uint256(RegistryLimits.MAX_DURATION) + 1));
        bool expected = _writable() && caller == ghostOwner && duration != 0 && duration <= RegistryLimits.MAX_DURATION;
        if (_call(caller, abi.encodeCall(SubscriptionRegistryV1.createPlan, (duration)), expected)) {
            ghostPlans[++ghostPlanCount] = GhostPlan(duration, true, 0);
        }
    }

    function setPlanActive(uint256 adminSeed, uint256 planSeed, bool active) external {
        address caller = _admin(adminSeed);
        uint256 planId = _planId(planSeed);
        bool expected = _writable() && caller == ghostOwner && _known(planId);
        if (_call(caller, abi.encodeCall(SubscriptionRegistryV1.setPlanActive, (planId, active)), expected)) {
            ghostPlans[planId].active = active;
        }
    }

    function setPlanPrice(uint256 adminSeed, uint256 planSeed, uint128 price) external {
        address caller = _admin(adminSeed);
        uint256 planId = _planId(planSeed);
        price = uint128(bound(price, 0, 500e6));
        bool expected = stage == V3 && caller == ghostOwner && _known(planId);
        if (_call(caller, abi.encodeCall(SubscriptionRegistryV3.setPlanPrice, (planId, price)), expected)) {
            ghostPlans[planId].price = price;
        }
    }

    /// @notice The one-argument `subscribe` of every version: free plans only from V3 on.
    function subscribe(uint256 actorSeed, uint256 planSeed) external {
        address actor = _subscriber(actorSeed);
        uint256 planId = _planId(planSeed);
        GhostPlan memory p = ghostPlans[planId];
        bool expected = _writable() && _known(planId) && p.active && !_pausedNow() && p.price == 0;
        if (_call(actor, abi.encodeCall(SubscriptionRegistryV1.subscribe, (planId)), expected)) {
            _recordSubscription(actor, planId, 0);
        }
    }

    /// @notice Paid subscription (V3 code only), bounded around the current price.
    function subscribeWithMaxPrice(uint256 actorSeed, uint256 planSeed, uint256 maxSeed) external {
        address actor = _subscriber(actorSeed);
        uint256 planId = _planId(planSeed);
        GhostPlan memory p = ghostPlans[planId];
        uint256 pick = maxSeed % 3;
        uint128 maxPrice = pick == 0 ? p.price : pick == 1 ? p.price + 1 : (p.price == 0 ? 0 : p.price - 1);
        bool expected = stage >= V3_UNCONFIGURED && _known(planId) && p.active && !_pausedNow() && p.price <= maxPrice;
        bytes memory data = abi.encodeCall(SubscriptionRegistryV3.subscribeWithMaxPrice, (planId, maxPrice));
        if (_call(actor, data, expected)) _recordSubscription(actor, planId, p.price);
    }

    function cancel(uint256 actorSeed) external {
        address actor = _subscriber(actorSeed);
        bool expected = _writable() && ghostSubs[actor].planId != 0;
        if (_call(actor, abi.encodeCall(SubscriptionRegistryV1.cancel, ()), expected)) {
            delete ghostSubs[actor];
        }
    }

    function setGracePeriod(uint256 adminSeed, uint64 grace) external {
        address caller = _admin(adminSeed);
        grace = uint64(bound(grace, 0, uint256(RegistryLimits.MAX_GRACE_PERIOD) + 1));
        bool expected = stage >= V2 && caller == ghostOwner && grace <= RegistryLimits.MAX_GRACE_PERIOD;
        if (_call(caller, abi.encodeCall(SubscriptionRegistryV2.setGracePeriod, (grace)), expected)) {
            ghostGracePeriod = grace;
        }
    }

    function setTreasury(uint256 adminSeed, uint256 treasurySeed) external {
        address caller = _admin(adminSeed);
        uint256 index = treasurySeed % 2;
        bool expected = stage == V3 && caller == ghostOwner;
        if (_call(caller, abi.encodeCall(SubscriptionRegistryV3.setTreasury, (treasuries[index])), expected)) {
            ghostTreasury = index;
        }
    }

    function pause(uint256 adminSeed) external {
        address caller = _admin(adminSeed);
        bool expected = stage >= V2 && caller == ghostOwner && !ghostPaused;
        if (_call(caller, abi.encodeCall(SubscriptionRegistryV2.pause, ()), expected)) ghostPaused = true;
    }

    function unpause(uint256 adminSeed) external {
        address caller = _admin(adminSeed);
        bool expected = stage >= V2 && caller == ghostOwner && ghostPaused;
        if (_call(caller, abi.encodeCall(SubscriptionRegistryV2.unpause, ()), expected)) ghostPaused = false;
    }

    /// @notice One step on V1 (OZ 4.x `Ownable`), a nomination from the bridge on (OZ 5.x `Ownable2Step`).
    function transferOwnership(uint256 adminSeed, uint256 newOwnerSeed) external {
        address caller = _admin(adminSeed);
        address nominee = people[newOwnerSeed % 5];
        bool expected = caller == ghostOwner;
        if (_call(caller, abi.encodeCall(Ownable2StepUpgradeable.transferOwnership, (nominee)), expected)) {
            if (stage == V1) ghostOwner = nominee;
            else ghostPendingOwner = nominee;
        }
    }

    function acceptOwnership(uint256 personSeed) external {
        address caller = people[personSeed % 5];
        bool expected = stage >= BRIDGE && ghostPendingOwner != address(0) && caller == ghostPendingOwner;
        if (_call(caller, abi.encodeCall(Ownable2StepUpgradeable.acceptOwnership, ()), expected)) {
            ghostOwner = caller;
            ghostPendingOwner = address(0);
        }
    }

    function warp(uint256 secondsForward) external {
        vm.warp(vm.getBlockTimestamp() + bound(secondsForward, 0, 90 days));
    }

    // ------------------------------------------------------------------ upgrade sub-steps

    /// @notice Step 1: V1 -> bridge with `migrateFromV4`, by the V1 owner (anyone else must fail).
    function upgradeToBridge(uint256 adminSeed) external {
        if (stage != V1) return;
        address caller = _admin(adminSeed);
        bytes memory data = abi.encodeCall(
            IUUPS.upgradeToAndCall, (implementations[1], abi.encodeCall(SubscriptionRegistryBridge.migrateFromV4, ()))
        );
        if (_call(caller, data, caller == ghostOwner)) _enter(BRIDGE);
    }

    /// @notice Step 2: bridge -> V2 with `initializeV2(manager)`, by the migrated owner.
    function upgradeToV2(uint256 adminSeed) external {
        if (stage != BRIDGE) return;
        address caller = _admin(adminSeed);
        bytes memory data = abi.encodeCall(
            IUUPS.upgradeToAndCall,
            (implementations[2], abi.encodeCall(SubscriptionRegistryV2.initializeV2, (address(manager))))
        );
        if (_call(caller, data, caller == ghostOwner)) _enter(V2);
    }

    /// @notice Step 3a: the UPGRADER schedules V2 -> V3 (scheduling it again must fail, unless the first one expired).
    function scheduleV3() external {
        if (stage != V2 && stage != V3_PENDING) return;
        bool expiredPending = stage == V3_PENDING && vm.getBlockTimestamp() >= uint256(readyAt) + manager.expiration();
        bool expected = stage == V2 || expiredPending;
        bytes memory data = abi.encodeCall(AccessManager.schedule, (proxy, _v3UpgradeCall(), uint48(0)));
        if (_callManager(upgrader, data, expected)) {
            readyAt = uint48(vm.getBlockTimestamp()) + upgradeDelay;
            _enter(V3_PENDING);
        }
    }

    /// @notice The guardian cancels the scheduled upgrade: back to V2.
    function cancelV3() external {
        if (stage != V3_PENDING) return;
        bytes memory data = abi.encodeCall(AccessManager.cancel, (upgrader, proxy, _v3UpgradeCall()));
        if (_callManager(guardian, data, true)) _enter(V2);
    }

    /// @notice Step 3b: the UPGRADER executes, optionally after jumping to (or one second before) the ready time.
    ///         Too early fails and keeps the schedule; too late (expired) fails and returns to V2.
    function executeV3(uint256 timingSeed) external {
        if (stage != V3_PENDING) return;
        uint256 timing = timingSeed % 3;
        if (timing == 1 && readyAt > vm.getBlockTimestamp()) vm.warp(readyAt);
        if (timing == 2 && readyAt - 1 > vm.getBlockTimestamp()) vm.warp(readyAt - 1);
        uint256 nowTs = vm.getBlockTimestamp();
        bool expired = nowTs >= uint256(readyAt) + manager.expiration();
        bool expected = nowTs >= readyAt && !expired;
        bytes memory data = abi.encodeCall(AccessManager.execute, (proxy, _v3UpgradeCall()));
        if (_callManager(upgrader, data, expected)) _enter(V3_UNCONFIGURED);
        else if (expired) _enter(V2);
    }

    /// @notice Step 3c: the owner enables payments (`initializeV3`, once, owner only; nothing else may succeed).
    function initializeV3(uint256 adminSeed) external {
        address caller = _admin(adminSeed);
        bool expected = stage == V3_UNCONFIGURED && caller == ghostOwner;
        bytes memory data = abi.encodeCall(SubscriptionRegistryV3.initializeV3, (token, treasuries[0]));
        if (_call(caller, data, expected)) {
            ghostTreasury = 0;
            _enter(V3);
        }
    }

    // ------------------------------------------------------------------ plumbing

    function _v3UpgradeCall() internal view returns (bytes memory) {
        return abi.encodeCall(IUUPS.upgradeToAndCall, (implementations[3], ""));
    }

    function _enter(uint256 next) internal {
        stage = next;
        stageVisits |= 1 << next;
    }

    /// @dev Application writes exist on every stage except the bridge (maintenance mode).
    function _writable() internal view returns (bool) {
        return stage != BRIDGE;
    }

    /// @dev Pausing exists from V2 on, and its flag survives the V3 upgrade (OpenZeppelin `Pausable` namespace).
    function _pausedNow() internal view returns (bool) {
        return stage >= V2 && ghostPaused;
    }

    function _known(uint256 planId) internal view returns (bool) {
        return planId != 0 && planId <= ghostPlanCount;
    }

    function _planId(uint256 seed) internal view returns (uint256) {
        return seed % (ghostPlanCount + 2);
    }

    function _subscriber(uint256 seed) internal view returns (address) {
        return people[1 + seed % 4];
    }

    /// @dev Three times out of four the current owner, otherwise anyone (which may still be the owner).
    function _admin(uint256 seed) internal view returns (address) {
        return seed % 4 == 0 ? people[(seed >> 8) % 5] : ghostOwner;
    }

    function _recordSubscription(address actor, uint256 planId, uint128 price) internal {
        GhostSub storage g = ghostSubs[actor];
        uint64 nowTs = uint64(vm.getBlockTimestamp());
        bool renewal = g.planId == planId && g.expiresAt > nowTs;
        g.expiresAt = (renewal ? g.expiresAt : nowTs) + ghostPlans[planId].duration;
        g.planId = planId;
        ++ghostTotalSubscriptions;
        if (renewal && stage >= V2) ++ghostRenewals[actor]; // the renewal counter exists from V2 on
        if (price != 0) {
            ghostRevenue += price;
            ghostPaid[actor] += price;
            ghostReceived[treasuries[ghostTreasury]] += price;
        }
    }

    function _call(address caller, bytes memory data, bool expected) internal returns (bool ok) {
        ++calls;
        vm.prank(caller);
        (ok,) = proxy.call(data);
        if (ok != expected) ++mismatches;
    }

    function _callManager(address caller, bytes memory data, bool expected) internal returns (bool ok) {
        ++calls;
        vm.prank(caller);
        (ok,) = address(manager).call(data);
        if (ok != expected) ++mismatches;
    }
}
