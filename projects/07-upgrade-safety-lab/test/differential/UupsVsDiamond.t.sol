// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {RegistryDiamond} from "../../src/diamond/RegistryDiamond.sol";
import {ISubscriptionRegistry} from "../../src/interfaces/IRegistry.sol";
import {LabBase} from "../utils/LabBase.sol";
import {MockERC20} from "../utils/Mocks.sol";
import {DifferentialHandler} from "./DifferentialHandler.sol";

/// @notice Shared setup: the UUPS registry after the full V1 -> bridge -> V2 -> V3 lineage, and a fresh diamond,
///         both owned by `owner`, both paying into `treasury`, each with its own (identical) payment token.
abstract contract DifferentialBase is LabBase {
    ISubscriptionRegistry internal uups;
    ISubscriptionRegistry internal diamond;
    MockERC20 internal tokenU;
    MockERC20 internal tokenD;
    DifferentialHandler internal handler;

    function _setUpBoth() internal {
        vm.warp(1_750_000_000);
        tokenU = new MockERC20("USD (uups)", "USDU");
        tokenD = new MockERC20("USD (diamond)", "USDD");
        (address proxy,) = _deployV3ThroughChain(tokenU);
        uups = ISubscriptionRegistry(proxy);
        (RegistryDiamond d,) = _deployDiamond(owner, tokenD, treasury);
        diamond = ISubscriptionRegistry(address(d));
        handler = new DifferentialHandler(uups, diamond, tokenU, tokenD, owner, treasury);
        // A common starting catalogue, issued through the handler so it is identical on both sides:
        // plan 1 is free (30 days), plan 2 costs 5 USD per week.
        handler.createPlan(_actorSeed(0, false), 30 days);
        handler.createPlan(_actorSeed(0, false), 7 days);
        handler.setPlanPrice(_actorSeed(0, false), _planSeed(2), 5e6);
    }

    /// @dev Finds a seed that makes the handler pick actor `index` (and, for admin calls, not the owner override).
    function _actorSeed(uint256 index, bool asRandomActor) internal view returns (uint256 seed) {
        for (seed = 0;; ++seed) {
            bool actorMatches = uint256(keccak256(abi.encode(seed, uint256(1)))) % handler.actorCount() == index;
            bool randomBranch = uint256(keccak256(abi.encode(seed, uint256(2)))) % 4 == 0;
            if (actorMatches && randomBranch == asRandomActor) return seed;
        }
    }

    /// @dev Finds a seed that makes the handler pick plan `planId` (1-based, existing).
    function _planSeed(uint256 planId) internal view returns (uint256 seed) {
        uint256 count = uups.planCount();
        for (seed = 0;; ++seed) {
            uint256 h = uint256(keccak256(abi.encode(seed, uint256(3))));
            if (h % 8 != 0 && 1 + (h >> 8) % count == planId) return seed;
        }
    }

    /// @dev Finds a seed that makes the handler bound a payment by `pick` (0 below the price, 1 the price, 2 above).
    function _maxSeed(uint256 pick) internal pure returns (uint256 seed) {
        for (seed = 0;; ++seed) {
            if (uint256(keccak256(abi.encode(seed, uint256(5)))) % 5 == pick) return seed;
        }
    }

    /// @dev Every observable of the two deployments must be equal.
    function _assertSameState() internal view {
        assertEq(handler.logMismatches(), 0, "a call emitted different events");
        assertEq(handler.mismatches(), 0, "a call behaved differently");
        assertEq(uups.owner(), diamond.owner(), "owner");
        assertEq(uups.pendingOwner(), diamond.pendingOwner(), "pendingOwner");
        assertEq(uups.paused(), diamond.paused(), "paused");
        assertEq(uups.gracePeriod(), diamond.gracePeriod(), "gracePeriod");
        assertEq(uups.treasury(), diamond.treasury(), "treasury");
        assertEq(uups.totalRevenue(), diamond.totalRevenue(), "totalRevenue");
        assertEq(uups.totalSubscriptions(), diamond.totalSubscriptions(), "totalSubscriptions");
        uint256 count = uups.planCount();
        assertEq(count, diamond.planCount(), "planCount");
        for (uint256 id; id <= count + 1; ++id) {
            (uint64 du, bool au) = uups.plan(id);
            (uint64 dd, bool ad) = diamond.plan(id);
            assertEq(du, dd, "plan.duration");
            assertEq(au, ad, "plan.active");
            assertEq(uups.planPrice(id), diamond.planPrice(id), "planPrice");
        }
        for (uint256 i; i < handler.actorCount(); ++i) {
            address a = handler.actorAt(i);
            (uint256 pu, uint64 eu) = uups.subscriptionOf(a);
            (uint256 pd, uint64 ed) = diamond.subscriptionOf(a);
            assertEq(pu, pd, "subscription.planId");
            assertEq(eu, ed, "subscription.expiresAt");
            assertEq(uups.isActive(a), diamond.isActive(a), "isActive");
            assertEq(uups.renewalsOf(a), diamond.renewalsOf(a), "renewals");
            assertEq(tokenU.balanceOf(a), tokenD.balanceOf(a), "actor balance");
        }
        for (uint256 i; i < 2; ++i) {
            address t = handler.treasuryAt(i);
            assertEq(tokenU.balanceOf(t), tokenD.balanceOf(t), "treasury balance");
        }
        assertEq(tokenU.balanceOf(address(uups)), 0, "UUPS holds no funds");
        assertEq(tokenD.balanceOf(address(diamond)), 0, "diamond holds no funds");
    }
}

/// @notice Stateless differential fuzzing: one fuzzed program of 32 operations, replayed on both architectures.
contract UupsVsDiamondSequenceTest is DifferentialBase {
    function setUp() public {
        _setUpBoth();
    }

    function testFuzz_identicalCallSequencesEndInIdenticalState(uint256[32] calldata program) public {
        for (uint256 i; i < program.length; ++i) {
            uint256 op = program[i];
            uint256 a = uint256(keccak256(abi.encode(op, "a")));
            uint256 b = uint256(keccak256(abi.encode(op, "b")));
            uint256 kind = op % 18;
            if (kind == 0) handler.createPlan(a, uint64(b));
            else if (kind == 1) handler.setPlanActive(a, b, b % 3 != 0);
            else if (kind == 2) handler.setPlanPrice(a, b, uint128(b >> 128));
            else if (kind <= 4) handler.subscribe(a, b);
            else if (kind <= 6) handler.subscribeWithMaxPrice(a, b, uint256(keccak256(abi.encode(op, "c"))));
            else if (kind == 7) handler.cancel(a);
            else if (kind == 8) handler.setGracePeriod(a, uint64(b));
            else if (kind == 9) handler.setTreasury(a, b);
            else if (kind == 10) handler.pause(a);
            else if (kind == 11) handler.unpause(a);
            else if (kind == 12) handler.transferOwnership(a, b);
            else if (kind == 13) handler.acceptOwnership(a);
            else if (kind == 14) handler.approve(a, b);
            else if (kind == 15) handler.warpToBoundary(a, b);
            else if (kind == 16) handler.renewAtBoundary(a, b);
            else handler.warp(b);
        }
        _assertSameState();
    }

    /// @notice A hand-written program that walks every branch once (sanity check of the harness itself).
    function test_scriptedProgramCoversEveryBranch() public {
        uint256 ownerCall = _actorSeed(0, false); // any seed on the "current owner" branch
        uint256 stranger = _actorSeed(3, true); // actor 3: not the owner, unfunded
        uint256 funded = _actorSeed(1, false); // actor 1: funded and pre-approved
        uint256 unfunded = _actorSeed(3, false);
        uint256 newOwner = _actorSeed(2, false);
        uint256 paidPlan = _planSeed(2);
        uint256 belowPrice = _maxSeed(0);
        uint256 atPrice = _maxSeed(1);
        uint256 abovePrice = _maxSeed(2);

        handler.createPlan(ownerCall, 0); // invalid duration: both revert
        handler.createPlan(stranger, 30 days); // non-owner: both revert
        handler.subscribe(funded, paidPlan); // the one-argument subscribe never pays: both revert
        handler.subscribeWithMaxPrice(funded, paidPlan, belowPrice); // bound below the price: both revert
        handler.subscribeWithMaxPrice(funded, paidPlan, atPrice); // pays for plan 2
        handler.subscribeWithMaxPrice(funded, paidPlan, abovePrice); // renewal, pays the price (not the bound)
        handler.subscribeWithMaxPrice(unfunded, paidPlan, atPrice); // no allowance: both revert
        handler.approve(unfunded, 1000e6);
        handler.subscribeWithMaxPrice(unfunded, paidPlan, atPrice); // allowance but no balance: both revert
        handler.warpToBoundary(funded, 1); // exactly at expiry: access has just ended
        assertFalse(uups.isActive(handler.actorAt(1)));
        handler.setGracePeriod(ownerCall, 5 days);
        handler.pause(ownerCall);
        handler.subscribeWithMaxPrice(funded, paidPlan, atPrice); // paused: both revert
        handler.unpause(ownerCall);
        handler.cancel(funded);
        handler.cancel(funded); // nothing to cancel: both revert
        handler.setTreasury(ownerCall, 1);
        handler.transferOwnership(ownerCall, newOwner);
        handler.acceptOwnership(newOwner);
        handler.createPlan(ownerCall, 7 days); // admin selection follows the new owner
        assertEq(uups.owner(), handler.actorAt(2));
        assertEq(uups.planCount(), 3);
        assertEq(uups.renewalsOf(handler.actorAt(1)), 1, "a paid renewal happened");
        assertEq(uups.totalRevenue(), 10e6, "two payments happened");
        assertEq(handler.calls(), 3 + 18);
        _assertSameState();
    }
}

/// @notice Stateful differential fuzzing: the invariant engine drives the handler with arbitrary interleavings.
contract UupsVsDiamondInvariantTest is DifferentialBase {
    function setUp() public {
        _setUpBoth();
        targetContract(address(handler));
        // Only the actions: the handler's view getters would otherwise dilute the campaign.
        bytes4[] memory actions = new bytes4[](16);
        actions[0] = DifferentialHandler.createPlan.selector;
        actions[1] = DifferentialHandler.setPlanActive.selector;
        actions[2] = DifferentialHandler.setPlanPrice.selector;
        actions[3] = DifferentialHandler.subscribe.selector;
        actions[4] = DifferentialHandler.subscribeWithMaxPrice.selector;
        actions[5] = DifferentialHandler.cancel.selector;
        actions[6] = DifferentialHandler.setGracePeriod.selector;
        actions[7] = DifferentialHandler.setTreasury.selector;
        actions[8] = DifferentialHandler.pause.selector;
        actions[9] = DifferentialHandler.unpause.selector;
        actions[10] = DifferentialHandler.transferOwnership.selector;
        actions[11] = DifferentialHandler.acceptOwnership.selector;
        actions[12] = DifferentialHandler.approve.selector;
        actions[13] = DifferentialHandler.warp.selector;
        actions[14] = DifferentialHandler.warpToBoundary.selector;
        actions[15] = DifferentialHandler.renewAtBoundary.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: actions}));
    }

    function invariant_sameOutcomeForEveryCall() public view {
        assertEq(handler.mismatches(), 0);
    }

    function invariant_sameEventsForEveryCall() public view {
        assertEq(handler.logMismatches(), 0);
    }

    function invariant_sameObservableState() public view {
        _assertSameState();
    }
}
