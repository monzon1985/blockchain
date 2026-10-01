// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {OneStepVM} from "../../src/OneStepVM.sol";
import {BatchInbox} from "../../src/BatchInbox.sol";
import {OutputOracle} from "../../src/OutputOracle.sol";
import {DisputeGame} from "../../src/DisputeGame.sol";
import {IDisputeGame} from "../../src/interfaces/IDisputeGame.sol";
import {IOutputOracle} from "../../src/interfaces/IOutputOracle.sol";
import {Machine, StepProof, Record} from "../../src/lib/Types.sol";
import {VmSpec} from "../../src/lib/VmSpec.sol";
import {VmBuilder} from "../utils/VmBuilder.sol";

/// @notice Drives proposers and challengers through random but well-formed protocol actions: proposals (honest or
///         not), challenges, bisection moves (honest or random), one-step proofs, time warps, timeouts,
///         cancellations, finalization, orphan refunds and credit claims. Ghost variables track every wei in and out.
contract ProtocolHandler is CommonBase, StdCheats, StdUtils {
    using VmBuilder for VmBuilder.Program;

    OneStepVM public immutable OSVM;
    BatchInbox public immutable INBOX;
    OutputOracle public immutable ORACLE;
    DisputeGame public immutable GAME;
    address public immutable SEQUENCER;

    VmBuilder.Program internal tiny;
    bytes32 public r42;

    /// @dev Honest traces keyed by the pre-state root they start from (empty tree, or {1: 42}).
    mapping(bytes32 preRoot => Machine[5]) internal trace;
    mapping(bytes32 preRoot => bool) internal known;

    address[3] internal proposers;
    address[3] internal challengers;
    uint256[] public gameIds;

    uint256 public ghostDeposited;
    uint256 public ghostPaidOut;
    uint256 public ghostStepsExecuted;
    uint256 public ghostTimeouts;
    uint256 public ghostFinalized;
    mapping(bytes32 => uint256) public calls;

    constructor(OneStepVM osvm, BatchInbox inbox, OutputOracle oracle, DisputeGame game, address sequencer) {
        OSVM = osvm;
        INBOX = inbox;
        ORACLE = oracle;
        GAME = game;
        SEQUENCER = sequencer;
        tiny.ops = new uint8[](4);
        tiny.imms = new uint256[](4);
        (tiny.ops[0], tiny.imms[0]) = (VmSpec.OP_PUSH, 42);
        (tiny.ops[1], tiny.imms[1]) = (VmSpec.OP_PUSH, 1);
        tiny.ops[2] = VmSpec.OP_SSTORE;
        tiny.ops[3] = VmSpec.OP_HALT;
        r42 = VmBuilder.singleLeafRoot(bytes32(uint256(1)), bytes32(uint256(42)));
        for (uint256 i = 0; i < 3; ++i) {
            proposers[i] = makeAddr(string.concat("proposer", vm.toString(i)));
            challengers[i] = makeAddr(string.concat("challenger", vm.toString(i)));
            vm.deal(proposers[i], 1_000 ether);
            vm.deal(challengers[i], 1_000 ether);
        }
    }

    function gameCount() external view returns (uint256) {
        return gameIds.length;
    }

    // ---- honest traces ----------------------------------------------------------------------------------------------

    function _witness(bytes32 preRoot, uint256 i) internal view returns (StepProof memory w) {
        bytes32[] memory stack;
        if (i == 1) {
            stack = new bytes32[](1);
            stack[0] = bytes32(uint256(42));
        } else if (i == 2) {
            stack = new bytes32[](2);
            (stack[0], stack[1]) = (bytes32(uint256(42)), bytes32(uint256(1)));
        } else {
            stack = new bytes32[](0);
        }
        w = tiny.witness(i, stack, i == 2 ? 2 : 0);
        if (i == 2 && preRoot == r42) w.leafValue = bytes32(uint256(42));
    }

    function _ensureTrace(uint64 epoch, bytes32 preRoot) internal returns (bool) {
        if (preRoot != bytes32(0) && preRoot != r42) return false;
        if (known[preRoot]) return true;
        Machine memory m = GAME.initialMachine(epoch, preRoot);
        trace[preRoot][0] = m;
        for (uint256 i = 0; i < 4; ++i) {
            m = OSVM.step(m, _witness(preRoot, i));
            trace[preRoot][i + 1] = m;
        }
        known[preRoot] = true;
        return true;
    }

    function _honestHash(bytes32 preRoot, uint256 i) internal view returns (bytes32) {
        return VmSpec.hash(trace[preRoot][i > 4 ? 4 : i]);
    }

    function _preRoot(uint64 epoch) internal view returns (bytes32) {
        return epoch == 1 ? bytes32(0) : ORACLE.getProposal(ORACLE.proposalIdAt(epoch - 1)).stateRoot;
    }

    // ---- actions ------------------------------------------------------------------------------------------------

    function propose(uint256 actorSeed, bool honest, bytes32 fake) external {
        calls["propose"]++;
        uint64 epoch = ORACLE.nextEpoch();
        if (epoch > 20) return;
        if (epoch > INBOX.batchCount()) {
            vm.prank(SEQUENCER);
            INBOX.submitBatch("", new Record[](0));
        }
        bytes32 root = honest ? r42 : (fake == r42 ? bytes32(uint256(1)) : fake);
        address who = proposers[actorSeed % 3];
        uint256 bond = ORACLE.PROPOSER_BOND();
        vm.prank(who);
        ORACLE.propose{value: bond}(epoch, root);
        ghostDeposited += bond;
    }

    function challenge(uint256 actorSeed, uint256 epochSeed) external {
        calls["challenge"]++;
        uint64 next = ORACLE.nextEpoch();
        uint64 first = ORACLE.lastFinalizedEpoch() + 1;
        if (next <= first) return;
        uint64 epoch = uint64(bound(epochSeed, first, next - 1));
        uint256 pid = ORACLE.proposalIdAt(epoch);
        IOutputOracle.Proposal memory p = ORACLE.getProposal(pid);
        if (!ORACLE.isLive(pid) || vm.getBlockTimestamp() >= uint256(p.proposedAt) + ORACLE.CHALLENGE_WINDOW()) return;
        uint256 bond = GAME.CHALLENGER_BOND();
        vm.prank(challengers[actorSeed % 3]);
        gameIds.push(GAME.challenge{value: bond}(epoch));
        ghostDeposited += bond;
    }

    /// @dev First unresolved game at or after `seed` (wrapping), or 0 when none.
    function _openGame(uint256 seed) internal view returns (uint256) {
        uint256 n = gameIds.length;
        for (uint256 k = 0; k < n; ++k) {
            uint256 id = gameIds[(seed % n + k) % n];
            if (GAME.getGame(id).phase != IDisputeGame.Phase.Resolved) return id;
        }
        return 0;
    }

    function move(uint256 gameSeed, bool honest, bytes32 noise) external {
        calls["move"]++;
        uint256 id = _openGame(gameSeed);
        if (id != 0) _move(id, honest, noise);
    }

    /// @dev Plays up to eight moves of one game back to back; bit `i` of `honestMask` decides move `i`.
    function playOut(uint256 gameSeed, uint256 honestMask) external {
        calls["playOut"]++;
        uint256 id = _openGame(gameSeed);
        if (id == 0) return;
        for (uint256 i = 0; i < 8; ++i) {
            if (GAME.getGame(id).phase == IDisputeGame.Phase.Resolved) return;
            _move(id, (honestMask >> i) & 1 == 1, keccak256(abi.encode(honestMask, i)));
        }
    }

    function _move(uint256 id, bool honest, bytes32 noise) internal {
        DisputeGame.Game memory g = GAME.getGame(id);
        if (vm.getBlockTimestamp() > GAME.deadline(id)) return;
        bytes32 preRoot = _preRoot(g.epoch);
        bool traced = _ensureTrace(g.epoch, preRoot);
        uint64 mid = g.lo + (g.hi - g.lo) / 2;

        if (g.phase == IDisputeGame.Phase.AwaitingEnd) {
            IOutputOracle.Proposal memory p = ORACLE.getProposal(g.proposalId);
            Machine memory end = traced ? trace[preRoot][4] : trace[bytes32(0)][4];
            end.status = VmSpec.STATUS_HALTED;
            end.stateRoot = p.stateRoot;
            vm.prank(g.defender);
            GAME.commitEnd(id, end);
        } else if (g.phase == IDisputeGame.Phase.AwaitingMid) {
            bytes32 claimed = honest && traced ? _honestHash(preRoot, mid) : noise;
            vm.prank(g.defender);
            GAME.bisect(id, claimed);
        } else if (g.phase == IDisputeGame.Phase.AwaitingChoice) {
            bool agree = honest && traced ? g.midHash == _honestHash(preRoot, mid) : uint256(noise) & 1 == 1;
            vm.prank(g.challenger);
            GAME.choose(id, agree);
        } else if (g.phase == IDisputeGame.Phase.AwaitingStep) {
            if (!traced || g.loHash != _honestHash(preRoot, g.lo)) return;
            StepProof memory w;
            if (g.lo < 4) w = _witness(preRoot, g.lo);
            GAME.step(id, trace[preRoot][g.lo > 4 ? 4 : g.lo], w);
            ghostStepsExecuted++;
        }
    }

    function warp(uint256 secs) external {
        calls["warp"]++;
        vm.warp(vm.getBlockTimestamp() + bound(secs, 0, 30 minutes));
        vm.roll(vm.getBlockNumber() + 1);
    }

    /// @dev Jumps past the challenge window (lets outputs finalize and every running clock expire).
    function warpPastWindow() external {
        calls["warpPastWindow"]++;
        vm.warp(vm.getBlockTimestamp() + ORACLE.CHALLENGE_WINDOW() + 1);
        vm.roll(vm.getBlockNumber() + 1);
    }

    function timeout(uint256 gameSeed) external {
        calls["timeout"]++;
        if (gameIds.length == 0) return;
        uint256 id = gameIds[gameSeed % gameIds.length];
        if (GAME.getGame(id).phase == IDisputeGame.Phase.Resolved || vm.getBlockTimestamp() <= GAME.deadline(id)) {
            return;
        }
        GAME.claimTimeout(id);
        ghostTimeouts++;
    }

    function cancel(uint256 gameSeed) external {
        calls["cancel"]++;
        if (gameIds.length == 0) return;
        uint256 id = gameIds[gameSeed % gameIds.length];
        DisputeGame.Game memory g = GAME.getGame(id);
        if (g.phase == IDisputeGame.Phase.Resolved || ORACLE.isLive(g.proposalId)) return;
        GAME.cancel(id);
    }

    function finalize() external {
        calls["finalize"]++;
        uint64 epoch = ORACLE.lastFinalizedEpoch() + 1;
        if (epoch >= ORACLE.nextEpoch()) return;
        IOutputOracle.Proposal memory p = ORACLE.getProposal(ORACLE.proposalIdAt(epoch));
        if (p.activeGames != 0 || vm.getBlockTimestamp() < uint256(p.proposedAt) + ORACLE.CHALLENGE_WINDOW()) return;
        ORACLE.finalize(epoch);
        ghostFinalized++;
    }

    function reclaim(uint256 idSeed) external {
        calls["reclaim"]++;
        uint256 count = ORACLE.proposalCount();
        if (count == 0) return;
        uint256 id = bound(idSeed, 1, count);
        IOutputOracle.Proposal memory p = ORACLE.getProposal(id);
        if (p.status != IOutputOracle.ProposalStatus.Proposed || ORACLE.isLive(id)) return;
        ORACLE.reclaimOrphanedBond(id);
    }

    function claim(uint256 actorSeed) external {
        calls["claim"]++;
        address who = actorSeed % 2 == 0 ? proposers[actorSeed % 3] : challengers[actorSeed % 3];
        uint256 amount = ORACLE.credit(who);
        if (amount == 0) return;
        vm.prank(who);
        ORACLE.claimCredit();
        ghostPaidOut += amount;
    }
}
