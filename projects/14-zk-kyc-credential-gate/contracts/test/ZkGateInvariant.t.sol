// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {FixtureLoader} from "./base/FixtureLoader.sol";
import {GateHandler} from "./handlers/GateHandler.sol";
import {ZkGate} from "../src/ZkGate.sol";
import {MockVerifier} from "./mocks/MockVerifier.sol";

/// @title ZkGateInvariantTest
/// @notice Stateful invariants for the gate's nullifier registry and allowlist. Registration runs
///         behind a mock verifier so the invariants exercise the gate's bookkeeping, not the SNARK.
///         The handler replays nullifiers from a 6-element pool, so the replay guard is exercised in
///         every run (deleting it makes invariant_NoNullifierAcceptedTwice fail).
contract ZkGateInvariantTest is FixtureLoader {
    ZkGate internal gate;
    GateHandler internal handler;

    function setUp() public {
        GateFixture memory g = loadGate();
        useFixtureChain(g);
        MockVerifier mock = new MockVerifier();
        gate = deployGateAt(g.gateAddress, fixtureConfig(g, address(mock), address(mock), address(this)));
        handler = new GateHandler(gate, loadGroth16("valid_groth16.json").pub);
        gate.grantRole(gate.GOVERNOR_ROLE(), address(handler));

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = GateHandler.register.selector;
        selectors[1] = GateHandler.warp.selector;
        selectors[2] = GateHandler.deregister.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @notice INVARIANT 1: a nullifier is accepted at most once, ever (no registration succeeds with
    ///         an already-burned nullifier), and every nullifier the model burned is burned on-chain.
    function invariant_NoNullifierAcceptedTwice() public view {
        assertEq(handler.ghostReplaySuccesses(), 0, "a burned nullifier was accepted again");
        for (uint256 n = 1; n <= handler.NULLIFIER_POOL(); n++) {
            assertEq(gate.isNullifierUsed(n), handler.ghostBurned(n), "on-chain burn set != model");
        }
    }

    /// @notice INVARIANT 2: registrationCount == successful registrations == distinct nullifiers burned.
    function invariant_RegistrationCountEqualsBurnedNullifiers() public view {
        assertEq(gate.registrationCount(), handler.ghostSuccesses());
        assertEq(gate.registrationCount(), handler.ghostBurnedCount());
    }

    /// @notice INVARIANT 3: an account is on the allowlist iff it registered in the CURRENT epoch and
    ///         was not deregistered since (registrations lapse at the epoch boundary).
    function invariant_AllowlistMatchesEpochModel() public view {
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address actor = handler.actorAt(i);
            bool expected = block.timestamp < handler.ghostRegisteredUntil(actor);
            assertEq(gate.isRegistered(actor), expected, "allowlist != epoch model");
            assertEq(gate.registeredUntil(actor), handler.ghostRegisteredUntil(actor));
        }
    }

    /// @notice INVARIANT 4: every revert was one the model predicted (a replayed nullifier); a valid
    ///         fresh registration never fails.
    function invariant_OnlyPredictedReverts() public view {
        assertEq(handler.ghostUnexpectedReverts(), 0, "unexpected revert");
    }

    /// @notice Non-vacuity: with a 6-nullifier pool, more than 6 attempts force at least one replay.
    function afterInvariant() public view {
        if (handler.ghostAttempts() > handler.NULLIFIER_POOL()) {
            assertGt(handler.ghostReplayAttempts(), 0, "handler never replayed a nullifier");
        }
    }
}
