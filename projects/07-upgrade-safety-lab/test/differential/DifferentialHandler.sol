// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ISubscriptionRegistry, RegistryLimits} from "../../src/interfaces/IRegistry.sol";
import {MockERC20} from "../utils/Mocks.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice Sends every fuzzed call to the UUPS registry and to the diamond, from the same caller with the same
///         calldata, and records any difference in success flag, (normalized) return/revert data, or (normalized)
///         event logs: same events, same order, same topics and data.
/// @dev Never reverts, so the invariant campaign can run with `fail_on_revert = true`: a handler revert would mean a
///      harness bug, not a registry bug.
contract DifferentialHandler is CommonBase, StdCheats, StdUtils {
    ISubscriptionRegistry public immutable uups;
    ISubscriptionRegistry public immutable diamond;
    MockERC20 public immutable tokenU;
    MockERC20 public immutable tokenD;

    address[] internal actors;
    address[2] internal treasuries;

    uint256 public calls;
    uint256 public successes;
    uint256 public mismatches;
    uint256 public logMismatches;
    bytes4 public firstMismatchSelector;
    uint256 public maxPlanId;

    constructor(
        ISubscriptionRegistry uups_,
        ISubscriptionRegistry diamond_,
        MockERC20 tokenU_,
        MockERC20 tokenD_,
        address owner_,
        address treasury_
    ) {
        uups = uups_;
        diamond = diamond_;
        tokenU = tokenU_;
        tokenD = tokenD_;
        actors.push(owner_);
        treasuries[0] = treasury_;
        treasuries[1] = address(0xBEEF0001);
        for (uint256 i; i < 4; ++i) {
            address actor = address(uint160(0xA11CE00 + i));
            actors.push(actor);
            // Two actors are funded and pre-approved, two are not: payments must fail identically for the others.
            if (i < 2) {
                tokenU.mint(actor, 1_000_000e6);
                tokenD.mint(actor, 1_000_000e6);
                vm.prank(actor);
                tokenU.approve(address(uups_), type(uint256).max);
                vm.prank(actor);
                tokenD.approve(address(diamond_), type(uint256).max);
            }
        }
    }

    // ------------------------------------------------------------------ views for the invariants

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function actorAt(uint256 i) external view returns (address) {
        return actors[i];
    }

    function treasuryAt(uint256 i) external view returns (address) {
        return treasuries[i];
    }

    // ------------------------------------------------------------------ actions

    function createPlan(uint256 actorSeed, uint64 duration) external {
        duration = uint64(_edgy(duration, RegistryLimits.MAX_DURATION));
        _both(_admin(actorSeed), abi.encodeCall(ISubscriptionRegistry.createPlan, (duration)));
        uint256 count = uups.planCount();
        if (count > maxPlanId) maxPlanId = count;
    }

    function setPlanActive(uint256 actorSeed, uint256 planId, bool active) external {
        _both(_admin(actorSeed), abi.encodeCall(ISubscriptionRegistry.setPlanActive, (_planId(planId), active)));
    }

    function setPlanPrice(uint256 actorSeed, uint256 planId, uint128 price) external {
        price = uint128(bound(price, 0, 1000e6));
        _both(_admin(actorSeed), abi.encodeCall(ISubscriptionRegistry.setPlanPrice, (_planId(planId), price)));
    }

    /// @notice The one-argument `subscribe`: free plans only (a priced plan must revert identically).
    function subscribe(uint256 actorSeed, uint256 planId) external {
        _both(_actor(actorSeed), abi.encodeCall(ISubscriptionRegistry.subscribe, (_planId(planId))));
    }

    /// @notice Paying subscription with a bound chosen around the current price (below, at, above, zero, random),
    ///         so the `price > maxPrice` boundary is exercised.
    function subscribeWithMaxPrice(uint256 actorSeed, uint256 planSeed, uint256 maxSeed) external {
        uint256 planId = _planId(planSeed);
        uint128 maxPrice = _maxPrice(uups.planPrice(planId), maxSeed);
        _both(_actor(actorSeed), abi.encodeCall(ISubscriptionRegistry.subscribeWithMaxPrice, (planId, maxPrice)));
    }

    function cancel(uint256 actorSeed) external {
        _both(_actor(actorSeed), abi.encodeCall(ISubscriptionRegistry.cancel, ()));
    }

    function setGracePeriod(uint256 actorSeed, uint64 grace) external {
        grace = uint64(_edgy(grace, RegistryLimits.MAX_GRACE_PERIOD));
        _both(_admin(actorSeed), abi.encodeCall(ISubscriptionRegistry.setGracePeriod, (grace)));
    }

    function setTreasury(uint256 actorSeed, uint256 treasurySeed) external {
        _both(_admin(actorSeed), abi.encodeCall(ISubscriptionRegistry.setTreasury, (treasuries[treasurySeed % 2])));
    }

    function pause(uint256 actorSeed) external {
        _both(_admin(actorSeed), abi.encodeCall(ISubscriptionRegistry.pause, ()));
    }

    function unpause(uint256 actorSeed) external {
        _both(_admin(actorSeed), abi.encodeCall(ISubscriptionRegistry.unpause, ()));
    }

    function transferOwnership(uint256 actorSeed, uint256 newOwnerSeed) external {
        _both(_admin(actorSeed), abi.encodeCall(ISubscriptionRegistry.transferOwnership, (_actor(newOwnerSeed))));
    }

    function acceptOwnership(uint256 actorSeed) external {
        _both(_actor(actorSeed), abi.encodeCall(ISubscriptionRegistry.acceptOwnership, ()));
    }

    function approve(uint256 actorSeed, uint256 amount) external {
        address actor = _actor(actorSeed);
        amount = bound(amount, 0, 10_000e6);
        vm.prank(actor);
        tokenU.approve(address(uups), amount);
        vm.prank(actor);
        tokenD.approve(address(diamond), amount);
    }

    function warp(uint256 secondsForward) external {
        vm.warp(vm.getBlockTimestamp() + bound(secondsForward, 0, 60 days));
    }

    /// @notice Jumps to the exact second where an actor's access ends (expiry plus grace), give or take one
    ///         second, so boundary comparisons (`<` versus `<=`) are exercised instead of left to chance.
    function warpToBoundary(uint256 actorSeed, uint256 offsetSeed) external {
        (, uint64 expiresAt) = uups.subscriptionOf(_actor(actorSeed));
        if (expiresAt == 0) return;
        uint256 target = uint256(expiresAt) + uups.gracePeriod() + (offsetSeed % 3) - 1;
        if (target > vm.getBlockTimestamp()) vm.warp(target);
    }

    /// @notice Warps to the second an actor's subscription expires (give or take one) and renews it right there:
    ///         the boundary between "renewal" (extend) and "fresh period" (restart from now).
    function renewAtBoundary(uint256 actorSeed, uint256 offsetSeed) external {
        address actor = _actor(actorSeed);
        (uint256 planId, uint64 expiresAt) = uups.subscriptionOf(actor);
        if (expiresAt == 0) return;
        uint256 target = uint256(expiresAt) + (offsetSeed % 3) - 1;
        if (target > vm.getBlockTimestamp()) vm.warp(target);
        _both(actor, abi.encodeCall(ISubscriptionRegistry.subscribeWithMaxPrice, (planId, uups.planPrice(planId))));
    }

    // ------------------------------------------------------------------ plumbing

    /// @dev Boundary-value selection: half of the time one of {0, 1, max - 1, max, max + 1}, otherwise a value
    ///      bounded to [0, max + 10]. Off-by-one mutants at the limits are then found in a few runs.
    function _edgy(uint256 seed, uint256 max) internal pure returns (uint256) {
        uint256 h = _mix(seed, 4);
        if (h % 2 == 0) {
            uint256 pick = (h >> 8) % 5;
            if (pick == 0) return 0;
            if (pick == 1) return 1;
            if (pick == 2) return max - 1;
            if (pick == 3) return max;
            return max + 1;
        }
        return bound(seed, 0, max + 10);
    }

    /// @dev A price bound around `price`: one below, exactly, one above, zero, or anything up to 2,000 USD.
    function _maxPrice(uint128 price, uint256 seed) internal pure returns (uint128) {
        uint256 h = _mix(seed, 5);
        uint256 pick = h % 5;
        if (pick == 0) return price == 0 ? 0 : price - 1;
        if (pick == 1) return price;
        if (pick == 2) return price + 1;
        if (pick == 3) return 0;
        return uint128(bound(h >> 8, 0, 2000e6));
    }

    /// @dev Spreads the fuzzer's seeds (which favour small and edge values) over every choice.
    function _mix(uint256 seed, uint256 salt) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, salt)));
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[_mix(seed, 1) % actors.length];
    }

    /// @dev Admin calls come from the current owner three times out of four, from a random actor otherwise, so
    ///      both the privileged paths and the `OwnableUnauthorizedAccount` paths are exercised.
    function _admin(uint256 seed) internal view returns (address) {
        return _mix(seed, 2) % 4 == 0 ? _actor(seed) : uups.owner();
    }

    /// @dev Mostly existing plan ids, sometimes 0 or one past the end, so unknown-plan reverts are exercised too.
    function _planId(uint256 seed) internal view returns (uint256) {
        uint256 count = uups.planCount();
        uint256 h = _mix(seed, 3);
        if (count == 0 || h % 8 == 0) return (h >> 8) % 2 == 0 ? 0 : count + 1;
        return 1 + (h >> 8) % count;
    }

    function _both(address caller, bytes memory data) internal {
        ++calls;
        vm.recordLogs(); // starts from an empty buffer (direct token approvals are not part of the comparison)
        vm.prank(caller);
        (bool okU, bytes memory retU) = address(uups).call(data);
        bytes memory logsU = _encodeLogs(vm.getRecordedLogs());
        vm.prank(caller);
        (bool okD, bytes memory retD) = address(diamond).call(data);
        bytes memory logsD = _encodeLogs(vm.getRecordedLogs());
        if (okU) ++successes;
        bool sameOutcome = okU == okD && keccak256(_normalize(retU, 4)) == keccak256(_normalize(retD, 4));
        bool sameLogs = keccak256(logsU) == keccak256(logsD);
        if (!sameLogs) ++logMismatches;
        if (!sameOutcome || !sameLogs) {
            if (mismatches == 0) firstMismatchSelector = bytes4(data);
            ++mismatches;
        }
    }

    /// @dev Every log as (emitter, topics, data), with the deployment-specific addresses normalized: the two
    ///      registries and the two payment tokens differ by construction, everything else must be identical.
    function _encodeLogs(Vm.Log[] memory logs) internal view returns (bytes memory out) {
        for (uint256 i; i < logs.length; ++i) {
            bytes32[] memory topics = logs[i].topics;
            for (uint256 t; t < topics.length; ++t) {
                topics[t] = _normalizeWord(topics[t]);
            }
            bytes32 emitter = _normalizeWord(_word(logs[i].emitter));
            out = bytes.concat(out, abi.encode(emitter, topics, _normalize(logs[i].data, 0)));
        }
    }

    /// @dev Replaces every ABI word (from byte `start` on) that is one of the deployment-specific addresses, so
    ///      for example `ERC20InsufficientAllowance(spender, ...)` compares equal across architectures.
    function _normalize(bytes memory ret, uint256 start) internal view returns (bytes memory out) {
        out = bytes.concat(ret);
        for (uint256 offset = start; offset + 32 <= out.length; offset += 32) {
            bytes32 word;
            // Reads one 32-byte word of `out` at `offset` (bounds checked by the loop condition).
            assembly ("memory-safe") {
                word := mload(add(add(out, 0x20), offset))
            }
            bytes32 normalized = _normalizeWord(word);
            if (normalized != word) {
                // Overwrites that word with its placeholder, in bounds for the same reason.
                assembly ("memory-safe") {
                    mstore(add(add(out, 0x20), offset), normalized)
                }
            }
        }
    }

    /// @dev Registry address -> 0x5e1f, payment-token address -> 0x70c3, anything else unchanged.
    function _normalizeWord(bytes32 word) internal view returns (bytes32) {
        if (word == _word(address(uups)) || word == _word(address(diamond))) return bytes32(uint256(0x5e1f));
        if (word == _word(address(tokenU)) || word == _word(address(tokenD))) return bytes32(uint256(0x70c3));
        return word;
    }

    function _word(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }
}
