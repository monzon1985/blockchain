// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {RegistryDiamond} from "../src/diamond/RegistryDiamond.sol";
import {IRegistryErrors, IRegistryEvents, ISubscriptionRegistry, RegistryLimits} from "../src/interfaces/IRegistry.sol";
import {SubscriptionRegistryV3} from "../src/uups/v3/SubscriptionRegistryV3.sol";
import {IUUPS, LabBase} from "./utils/LabBase.sol";
import {MockERC20, ReentrantERC20} from "./utils/Mocks.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/// @notice One behaviour suite, two architectures. The core tests run against a V2 proxy, a V3 proxy (both
///         reached through the V1 -> bridge -> ... lineage) and the diamond; the payment tests against V3 and the
///         diamond. Expectations are identical, revert data included: this is the unit-level half of the
///         UUPS-vs-diamond equivalence claim.
abstract contract CoreBehaviourTest is LabBase, IRegistryEvents {
    ISubscriptionRegistry internal reg;
    MockERC20 internal token;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    // OpenZeppelin error and event signatures reused by both architectures.
    error OwnableUnauthorizedAccount(address account);
    error EnforcedPause();
    error ExpectedPause();

    event Paused(address account);
    event Unpaused(address account);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /// @dev Deploys the architecture under test with payments configured for `paymentToken`.
    function _deploy(IERC20 paymentToken) internal virtual returns (ISubscriptionRegistry);

    function setUp() public virtual {
        vm.warp(1_750_000_000);
        token = _newToken();
        reg = _deploy(token);
    }

    function _plan(uint64 duration) internal returns (uint256 id) {
        vm.prank(owner);
        id = reg.createPlan(duration);
    }

    function _fund(address who, uint256 amount) internal {
        token.mint(who, amount);
        vm.prank(who);
        token.approve(address(reg), type(uint256).max);
    }

    // ---------------------------------------------------------------- plans

    function test_createPlan_assignsSequentialIdsAndEmits() public {
        vm.expectEmit(address(reg));
        emit PlanCreated(1, 30 days);
        assertEq(_plan(30 days), 1);
        assertEq(_plan(365 days), 2);
        assertEq(reg.planCount(), 2);
        (uint64 duration, bool active) = reg.plan(2);
        assertEq(duration, 365 days);
        assertTrue(active);
    }

    function testFuzz_createPlan_acceptsEveryDurationInRange(uint64 duration) public {
        duration = uint64(bound(duration, 1, RegistryLimits.MAX_DURATION));
        uint256 id = _plan(duration);
        (uint64 stored,) = reg.plan(id);
        assertEq(stored, duration);
    }

    function testFuzz_createPlan_rejectsDurationAboveMax(uint64 duration) public {
        duration = uint64(bound(duration, uint256(RegistryLimits.MAX_DURATION) + 1, type(uint64).max));
        vm.expectRevert(
            abi.encodeWithSelector(IRegistryErrors.InvalidDuration.selector, duration, RegistryLimits.MAX_DURATION)
        );
        vm.prank(owner);
        reg.createPlan(duration);
    }

    function test_createPlan_rejectsZeroDuration() public {
        vm.expectRevert(
            abi.encodeWithSelector(IRegistryErrors.InvalidDuration.selector, uint64(0), RegistryLimits.MAX_DURATION)
        );
        vm.prank(owner);
        reg.createPlan(0);
    }

    function test_createPlan_onlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        reg.createPlan(30 days);
    }

    function test_setPlanActive_togglesAndEmits() public {
        uint256 id = _plan(30 days);
        vm.expectEmit(address(reg));
        emit PlanStatusChanged(id, false);
        vm.prank(owner);
        reg.setPlanActive(id, false);
        (, bool active) = reg.plan(id);
        assertFalse(active);
    }

    function test_setPlanActive_rejectsUnknownPlan() public {
        _plan(30 days);
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(IRegistryErrors.UnknownPlan.selector, 0, 1));
        reg.setPlanActive(0, false);
        vm.expectRevert(abi.encodeWithSelector(IRegistryErrors.UnknownPlan.selector, 2, 1));
        reg.setPlanActive(2, false);
        vm.stopPrank();
    }

    function test_setPlanActive_onlyOwner() public {
        uint256 id = _plan(30 days);
        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, bob));
        vm.prank(bob);
        reg.setPlanActive(id, false);
    }

    // ---------------------------------------------------------------- subscriptions

    function test_subscribe_startsFreshPeriod() public {
        uint256 id = _plan(30 days);
        uint64 expected = uint64(vm.getBlockTimestamp() + 30 days);
        vm.expectEmit(address(reg));
        emit Subscribed(alice, id, expected, false);
        vm.prank(alice);
        assertEq(reg.subscribe(id), expected);
        (uint256 planId, uint64 expiresAt) = reg.subscriptionOf(alice);
        assertEq(planId, id);
        assertEq(expiresAt, expected);
        assertTrue(reg.isActive(alice));
        assertEq(reg.totalSubscriptions(), 1);
        assertEq(reg.renewalsOf(alice), 0);
    }

    function test_subscribe_renewalStacksOnUnexpiredPeriod() public {
        uint256 id = _plan(30 days);
        vm.prank(alice);
        uint64 first = reg.subscribe(id);
        vm.warp(vm.getBlockTimestamp() + 10 days);
        vm.expectEmit(address(reg));
        emit Subscribed(alice, id, first + 30 days, true);
        vm.prank(alice);
        assertEq(reg.subscribe(id), first + 30 days);
        assertEq(reg.renewalsOf(alice), 1);
        assertEq(reg.totalSubscriptions(), 2);
    }

    function test_subscribe_expiredSamePlanRestartsFromNow() public {
        uint256 id = _plan(30 days);
        vm.prank(alice);
        uint64 first = reg.subscribe(id);
        vm.warp(first); // expiresAt is exclusive: at `first` the subscription is over
        vm.prank(alice);
        assertEq(reg.subscribe(id), first + 30 days);
        assertEq(reg.renewalsOf(alice), 0);
    }

    function test_subscribe_switchingPlanForfeitsRemainingTime() public {
        uint256 monthly = _plan(30 days);
        uint256 weekly = _plan(7 days);
        vm.prank(alice);
        reg.subscribe(monthly);
        vm.prank(alice);
        assertEq(reg.subscribe(weekly), uint64(vm.getBlockTimestamp() + 7 days));
        (uint256 planId,) = reg.subscriptionOf(alice);
        assertEq(planId, weekly);
        assertEq(reg.renewalsOf(alice), 0);
    }

    function test_subscribe_rejectsUnknownPlan() public {
        vm.expectRevert(abi.encodeWithSelector(IRegistryErrors.UnknownPlan.selector, 1, 0));
        vm.prank(alice);
        reg.subscribe(1);
    }

    function test_subscribe_rejectsInactivePlan() public {
        uint256 id = _plan(30 days);
        vm.prank(owner);
        reg.setPlanActive(id, false);
        vm.expectRevert(abi.encodeWithSelector(IRegistryErrors.PlanInactive.selector, id));
        vm.prank(alice);
        reg.subscribe(id);
    }

    function test_subscribe_rejectedWhilePaused() public {
        uint256 id = _plan(30 days);
        vm.prank(owner);
        reg.pause();
        vm.expectRevert(EnforcedPause.selector);
        vm.prank(alice);
        reg.subscribe(id);
    }

    function test_cancel_deletesAndEmits() public {
        uint256 id = _plan(30 days);
        vm.prank(alice);
        reg.subscribe(id);
        vm.expectEmit(address(reg));
        emit SubscriptionCancelled(alice, id);
        vm.prank(alice);
        reg.cancel();
        (uint256 planId, uint64 expiresAt) = reg.subscriptionOf(alice);
        assertEq(planId, 0);
        assertEq(expiresAt, 0);
        assertFalse(reg.isActive(alice));
    }

    function test_cancel_worksWhilePaused() public {
        uint256 id = _plan(30 days);
        vm.prank(alice);
        reg.subscribe(id);
        vm.prank(owner);
        reg.pause();
        vm.prank(alice);
        reg.cancel();
        assertFalse(reg.isActive(alice));
    }

    function test_cancel_rejectsWithoutSubscription() public {
        vm.expectRevert(abi.encodeWithSelector(IRegistryErrors.NoSubscription.selector, alice));
        vm.prank(alice);
        reg.cancel();
    }

    // ---------------------------------------------------------------- grace period

    function test_isActive_honoursGracePeriod() public {
        uint256 id = _plan(30 days);
        vm.prank(alice);
        uint64 expiresAt = reg.subscribe(id);
        vm.expectEmit(address(reg));
        emit GracePeriodUpdated(0, 3 days);
        vm.prank(owner);
        reg.setGracePeriod(3 days);
        assertEq(reg.gracePeriod(), 3 days);

        vm.warp(expiresAt + 3 days - 1);
        assertTrue(reg.isActive(alice));
        vm.warp(expiresAt + 3 days);
        assertFalse(reg.isActive(alice));
    }

    function test_setGracePeriod_rejectsAboveMax() public {
        uint64 tooLong = RegistryLimits.MAX_GRACE_PERIOD + 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                IRegistryErrors.InvalidGracePeriod.selector, tooLong, RegistryLimits.MAX_GRACE_PERIOD
            )
        );
        vm.prank(owner);
        reg.setGracePeriod(tooLong);
    }

    function test_setGracePeriod_onlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        reg.setGracePeriod(1 days);
    }

    // ---------------------------------------------------------------- pause

    function test_pauseAndUnpause() public {
        vm.expectEmit(address(reg));
        emit Paused(owner);
        vm.prank(owner);
        reg.pause();
        assertTrue(reg.paused());

        vm.expectRevert(EnforcedPause.selector);
        vm.prank(owner);
        reg.pause();

        vm.expectEmit(address(reg));
        emit Unpaused(owner);
        vm.prank(owner);
        reg.unpause();
        assertFalse(reg.paused());

        vm.expectRevert(ExpectedPause.selector);
        vm.prank(owner);
        reg.unpause();
    }

    function test_pause_onlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        reg.pause();
        vm.prank(owner);
        reg.pause();
        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        reg.unpause();
    }

    // ---------------------------------------------------------------- ownership

    function test_twoStepOwnershipTransfer() public {
        vm.expectEmit(address(reg));
        emit OwnershipTransferStarted(owner, alice);
        vm.prank(owner);
        reg.transferOwnership(alice);
        assertEq(reg.pendingOwner(), alice);
        assertEq(reg.owner(), owner);

        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, bob));
        vm.prank(bob);
        reg.acceptOwnership();

        vm.expectEmit(address(reg));
        emit OwnershipTransferred(owner, alice);
        vm.prank(alice);
        reg.acceptOwnership();
        assertEq(reg.owner(), alice);
        assertEq(reg.pendingOwner(), address(0));
    }

    function test_transferOwnership_onlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        reg.transferOwnership(alice);
    }

    function test_renounceOwnership_isDisabled() public {
        vm.expectRevert(IRegistryErrors.RenounceDisabled.selector);
        vm.prank(owner);
        reg.renounceOwnership();
        assertEq(reg.owner(), owner);
    }
}

/// @notice Paid tiers, on top of the core suite (V3 and the diamond only).
abstract contract PaymentsBehaviourTest is CoreBehaviourTest {
    /// @dev Deploys the architecture under test without payment configuration.
    function _deployUnconfigured() internal virtual returns (ISubscriptionRegistry);

    // ---------------------------------------------------------------- payments

    function test_newPlansAreFree() public {
        uint256 id = _plan(30 days);
        assertEq(reg.planPrice(id), 0);
        vm.prank(alice);
        reg.subscribe(id);
        assertEq(reg.totalRevenue(), 0);
    }

    function test_paidSubscription_pullsPriceIntoTreasury() public {
        uint256 id = _plan(30 days);
        vm.expectEmit(address(reg));
        emit PlanPriceUpdated(id, 25e6);
        vm.prank(owner);
        reg.setPlanPrice(id, 25e6);
        assertEq(reg.planPrice(id), 25e6);
        _fund(alice, 100e6);

        vm.expectEmit(address(reg));
        emit PaymentCollected(alice, id, treasury, 25e6);
        vm.prank(alice);
        reg.subscribeWithMaxPrice(id, 25e6);
        vm.prank(alice);
        reg.subscribeWithMaxPrice(id, 30e6); // a higher bound still pays the current price only

        assertEq(token.balanceOf(treasury), 50e6);
        assertEq(token.balanceOf(alice), 50e6);
        assertEq(token.balanceOf(address(reg)), 0);
        assertEq(reg.totalRevenue(), 50e6);
        assertEq(reg.paymentToken(), address(token));
        assertEq(reg.treasury(), treasury);
    }

    function test_paidSubscription_revertsWithoutAllowance() public {
        uint256 id = _plan(30 days);
        vm.prank(owner);
        reg.setPlanPrice(id, 25e6);
        token.mint(alice, 100e6);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(reg), 0, 25e6));
        vm.prank(alice);
        reg.subscribeWithMaxPrice(id, 25e6);
        (uint256 planId,) = reg.subscriptionOf(alice);
        assertEq(planId, 0, "state rolled back");
    }

    function test_subscribe_neverPaysForAPricedPlan() public {
        uint256 id = _plan(30 days);
        vm.prank(owner);
        reg.setPlanPrice(id, 25e6);
        _fund(alice, 100e6);
        vm.expectRevert(abi.encodeWithSelector(IRegistryErrors.PriceAboveMax.selector, id, uint128(25e6), uint128(0)));
        vm.prank(alice);
        reg.subscribe(id);
        assertEq(token.balanceOf(alice), 100e6);
    }

    /// @notice Regression test for the review finding: a repricing mined before a pending subscription (while the
    ///         subscriber holds a standing allowance) must not charge more than the subscriber accepted.
    function test_subscribeWithMaxPrice_rejectsARepricingThatLandsFirst() public {
        uint256 id = _plan(30 days);
        vm.prank(owner);
        reg.setPlanPrice(id, 25e6);
        _fund(alice, 1000e6); // unlimited allowance, as most wallets grant it
        vm.prank(owner);
        reg.setPlanPrice(id, 900e6); // front-runs alice's transaction
        vm.expectRevert(
            abi.encodeWithSelector(IRegistryErrors.PriceAboveMax.selector, id, uint128(900e6), uint128(25e6))
        );
        vm.prank(alice);
        reg.subscribeWithMaxPrice(id, 25e6);
        assertEq(token.balanceOf(alice), 1000e6);
        assertEq(reg.totalRevenue(), 0);
    }

    function testFuzz_subscribeWithMaxPrice_paysThePriceOnlyWithinTheBound(uint128 price, uint128 maxPrice) public {
        price = uint128(bound(price, 0, 1000e6));
        maxPrice = uint128(bound(maxPrice, 0, 2000e6));
        uint256 id = _plan(30 days);
        vm.prank(owner);
        reg.setPlanPrice(id, price);
        _fund(alice, 2000e6);
        if (price > maxPrice) {
            vm.expectRevert(abi.encodeWithSelector(IRegistryErrors.PriceAboveMax.selector, id, price, maxPrice));
        }
        vm.prank(alice);
        reg.subscribeWithMaxPrice(id, maxPrice);
        uint256 paid = price > maxPrice ? 0 : price;
        assertEq(token.balanceOf(treasury), paid);
        assertEq(token.balanceOf(alice), 2000e6 - paid);
        assertEq(reg.totalRevenue(), paid);
    }

    function test_setPlanPrice_rejectsUnknownPlanAndNonOwner() public {
        vm.expectRevert(abi.encodeWithSelector(IRegistryErrors.UnknownPlan.selector, 1, 0));
        vm.prank(owner);
        reg.setPlanPrice(1, 1);
        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        reg.setPlanPrice(1, 1);
    }

    function test_setTreasury_updatesAndValidates() public {
        address newTreasury = makeAddr("newTreasury");
        vm.expectEmit(address(reg));
        emit TreasuryUpdated(treasury, newTreasury);
        vm.prank(owner);
        reg.setTreasury(newTreasury);
        assertEq(reg.treasury(), newTreasury);

        vm.expectRevert(abi.encodeWithSelector(IRegistryErrors.InvalidTreasury.selector, address(0)));
        vm.prank(owner);
        reg.setTreasury(address(0));

        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        reg.setTreasury(alice);
    }

    function test_unconfiguredPayments_rejectPricingAndTreasury() public {
        ISubscriptionRegistry fresh = _deployUnconfigured();
        vm.startPrank(owner);
        fresh.createPlan(30 days);
        vm.expectRevert(IRegistryErrors.PaymentsNotConfigured.selector);
        fresh.setPlanPrice(1, 1);
        vm.expectRevert(IRegistryErrors.PaymentsNotConfigured.selector);
        fresh.setTreasury(treasury);
        vm.stopPrank();
        assertEq(fresh.paymentToken(), address(0));
    }

    function test_subscribe_blocksReentrancyFromPaymentToken() public {
        ReentrantERC20 evil = new ReentrantERC20();
        ISubscriptionRegistry r = _deploy(IERC20(address(evil)));
        vm.startPrank(owner);
        uint256 id = r.createPlan(30 days);
        r.setPlanPrice(id, 1e6);
        vm.stopPrank();
        evil.mint(alice, 10e6);
        vm.prank(alice);
        evil.approve(address(r), type(uint256).max);
        evil.arm(address(r), abi.encodeCall(ISubscriptionRegistry.subscribeWithMaxPrice, (id, 1e6)));

        vm.prank(alice);
        r.subscribeWithMaxPrice(id, 1e6);

        assertFalse(evil.reentered(), "nested subscribe must fail");
        assertEq(
            evil.reentryError(), abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector)
        );
        assertEq(r.totalSubscriptions(), 1);
    }
}

/// @notice The core suite against a V2 proxy reached through V1 -> bridge -> V2.
contract UupsV2CoreBehaviourTest is CoreBehaviourTest {
    function _deploy(IERC20) internal override returns (ISubscriptionRegistry) {
        address proxy = _deployV1(owner);
        AccessManager manager = _deployManager(governance, proxy);
        _migrateToV2(proxy, manager);
        return ISubscriptionRegistry(proxy);
    }
}

/// @notice The behaviour suite against the UUPS proxy after V1 -> bridge -> V2 -> V3.
contract UupsV3BehaviourTest is PaymentsBehaviourTest {
    function _deploy(IERC20 paymentToken) internal override returns (ISubscriptionRegistry) {
        (address proxy,) = _deployV3ThroughChain(paymentToken);
        return ISubscriptionRegistry(proxy);
    }

    function _deployUnconfigured() internal override returns (ISubscriptionRegistry) {
        address proxy = _deployV1(owner);
        AccessManager manager = _deployManager(governance, proxy);
        _migrateToV2(proxy, manager);
        SubscriptionRegistryV3 v3 = new SubscriptionRegistryV3();
        bytes memory call = abi.encodeCall(IUUPS.upgradeToAndCall, (address(v3), ""));
        vm.prank(upgrader);
        manager.schedule(proxy, call, 0);
        vm.warp(vm.getBlockTimestamp() + UPGRADE_DELAY);
        vm.prank(upgrader);
        manager.execute(proxy, call);
        return ISubscriptionRegistry(proxy);
    }
}

/// @notice The behaviour suite against the diamond.
contract DiamondBehaviourTest is PaymentsBehaviourTest {
    function _deploy(IERC20 paymentToken) internal override returns (ISubscriptionRegistry) {
        (RegistryDiamond diamond,) = _deployDiamond(owner, paymentToken, treasury);
        return ISubscriptionRegistry(address(diamond));
    }

    function _deployUnconfigured() internal override returns (ISubscriptionRegistry) {
        DiamondFacets memory f = _deployFacets();
        return ISubscriptionRegistry(address(new RegistryDiamond(owner, _facetCuts(f), address(0), "")));
    }
}
