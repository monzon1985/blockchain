// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {ZkGate} from "../../src/ZkGate.sol";
import {PUBLIC_SIGNALS} from "../../src/interfaces/IVerifiers.sol";

/// @title GateHandler
/// @notice Stateful invariant handler for ZkGate's nullifier/allowlist bookkeeping. It registers
///         through the real gate (behind an always-true mock verifier) with nullifiers drawn from a
///         deliberately SMALL pool so replays are frequent, advances time across epochs, and
///         deregisters accounts as the governor. Every outcome is checked against a ghost model:
///         a fresh nullifier must succeed, a burned one must revert with NullifierAlreadyUsed.
contract GateHandler is CommonBase, StdUtils {
    /// @notice Nullifiers are drawn from [1, NULLIFIER_POOL].
    uint256 public constant NULLIFIER_POOL = 6;

    ZkGate internal immutable gate;
    uint256[PUBLIC_SIGNALS] internal base;
    address[] internal actors;

    /// @notice Ghost: nullifiers this handler has seen burned.
    mapping(uint256 nullifier => bool burned) public ghostBurned;
    /// @notice Ghost: number of distinct nullifiers burned.
    uint256 public ghostBurnedCount;
    /// @notice Ghost: successful registrations.
    uint256 public ghostSuccesses;
    /// @notice Ghost: successful registrations whose nullifier was ALREADY burned (must stay 0).
    uint256 public ghostReplaySuccesses;
    /// @notice Ghost: attempts with an already-burned nullifier (non-vacuity of the replay check).
    uint256 public ghostReplayAttempts;
    /// @notice Ghost: total registration attempts.
    uint256 public ghostAttempts;
    /// @notice Ghost: reverts that the model did not predict (must stay 0).
    uint256 public ghostUnexpectedReverts;
    /// @notice Ghost: per-actor end of the expected registration (0 = not expected to be registered).
    mapping(address account => uint256 until) public ghostRegisteredUntil;

    constructor(ZkGate gate_, uint256[PUBLIC_SIGNALS] memory base_) {
        gate = gate_;
        base = base_;
        actors.push(address(0xA1));
        actors.push(address(0xA2));
        actors.push(address(0xA3));
        actors.push(address(0xA4));
    }

    /// @notice Attempt a registration with a pooled nullifier from a chosen actor.
    function register(uint256 nullifierSeed, uint256 actorSeed) external {
        address actor = actors[actorSeed % actors.length];
        uint256 nullifier = bound(nullifierSeed, 1, NULLIFIER_POOL);
        uint256[PUBLIC_SIGNALS] memory pub = base;
        pub[0] = nullifier;
        pub[20] = gate.appScope(); // valid scope for whatever epoch we are in
        pub[21] = uint256(uint160(actor));

        uint256[2] memory a;
        uint256[2][2] memory b;
        uint256[2] memory c;

        bool wasBurned = ghostBurned[nullifier];
        ++ghostAttempts;
        if (wasBurned) ++ghostReplayAttempts;

        vm.prank(actor);
        try gate.registerWithGroth16(a, b, c, pub) {
            ++ghostSuccesses;
            if (wasBurned) {
                ++ghostReplaySuccesses;
            } else {
                ghostBurned[nullifier] = true;
                ++ghostBurnedCount;
            }
            ghostRegisteredUntil[actor] = (gate.currentEpoch() + 1) * gate.epochDuration();
        } catch (bytes memory reason) {
            bool predicted = wasBurned
                && keccak256(reason)
                    == keccak256(abi.encodeWithSelector(ZkGate.NullifierAlreadyUsed.selector, nullifier));
            if (!predicted) ++ghostUnexpectedReverts;
        }
    }

    /// @notice Move time forward (possibly across several epochs).
    function warp(uint256 secondsAhead) external {
        vm.warp(block.timestamp + bound(secondsAhead, 1, 3 * gate.epochDuration()));
    }

    /// @notice Governor removes an actor if it is currently registered.
    function deregister(uint256 actorSeed) external {
        address actor = actors[actorSeed % actors.length];
        if (!gate.isRegistered(actor)) return;
        gate.deregister(actor); // the handler holds GOVERNOR_ROLE
        ghostRegisteredUntil[actor] = 0;
    }

    /// @notice Number of actors.
    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    /// @notice Actor at index `i`.
    function actorAt(uint256 i) external view returns (address) {
        return actors[i];
    }
}
