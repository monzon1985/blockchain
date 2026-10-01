// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {OneStepVM} from "../../src/OneStepVM.sol";
import {ForcedInclusionQueue} from "../../src/ForcedInclusionQueue.sol";
import {BatchInbox} from "../../src/BatchInbox.sol";
import {OutputOracle} from "../../src/OutputOracle.sol";
import {DisputeGame} from "../../src/DisputeGame.sol";
import {Bridge} from "../../src/Bridge.sol";
import {Machine, StepProof, Record} from "../../src/lib/Types.sol";
import {VmSpec} from "../../src/lib/VmSpec.sol";
import {VmBuilder} from "./VmBuilder.sol";

/// @notice Deploys the whole system with a tiny state-transition program whose honest trace the tests can compute:
///
///     0: PUSH 42
///     1: PUSH 1
///     2: SSTORE        // state[1] = 42
///     3: HALT
///
///     Starting from the empty tree (or from {1: 42}), the honest post-state root is always `R42`.
abstract contract SystemFixture is Test {
    using VmBuilder for VmBuilder.Program;

    uint64 internal constant INCLUSION_WINDOW = 10;
    uint256 internal constant PROPOSER_BOND = 1 ether;
    uint256 internal constant CHALLENGER_BOND = 0.5 ether;
    uint64 internal constant CHALLENGE_WINDOW = 1 days;
    uint64 internal constant CLOCK = 1 hours;
    uint8 internal constant MAX_DEPTH = 3; // traces of 8 steps; the tiny program halts after 4

    OneStepVM internal osvm;
    ForcedInclusionQueue internal queue;
    BatchInbox internal inbox;
    OutputOracle internal oracle;
    DisputeGame internal game;
    Bridge internal bridge;

    address internal owner = makeAddr("owner");
    address internal sequencer = makeAddr("sequencer");
    address internal proposer = makeAddr("proposer");
    address internal challenger = makeAddr("challenger");

    VmBuilder.Program internal tiny;
    bytes32 internal r42;
    /// @dev Honest machines after 0..4 steps from the empty tree (index 4 = halted).
    Machine[5] internal honest;
    /// @dev Stack contents (bottom first) before each step, for building witnesses.
    bytes32[][4] internal stacks;

    function setUp() public virtual {
        tiny.ops = new uint8[](4);
        tiny.imms = new uint256[](4);
        (tiny.ops[0], tiny.imms[0]) = (VmSpec.OP_PUSH, 42);
        (tiny.ops[1], tiny.imms[1]) = (VmSpec.OP_PUSH, 1);
        tiny.ops[2] = VmSpec.OP_SSTORE;
        tiny.ops[3] = VmSpec.OP_HALT;
        r42 = VmBuilder.singleLeafRoot(bytes32(uint256(1)), bytes32(uint256(42)));

        _deploy(tiny.root(), uint32(tiny.ops.length));
        vm.deal(proposer, 100 ether);
        vm.deal(challenger, 100 ether);
    }

    function _deploy(bytes32 codeRoot, uint32 codeSize) internal {
        address deployer = address(this);
        uint256 nonce = vm.getNonce(deployer);
        address predictedGame = vm.computeCreateAddress(deployer, nonce + 4);
        address predictedBridge = vm.computeCreateAddress(deployer, nonce + 5);
        osvm = new OneStepVM();
        queue = new ForcedInclusionQueue(predictedBridge, INCLUSION_WINDOW);
        inbox = new BatchInbox(queue, owner, sequencer);
        oracle = new OutputOracle(inbox, predictedGame, bytes32(0), PROPOSER_BOND, CHALLENGE_WINDOW);
        game = new DisputeGame(oracle, inbox, osvm, codeRoot, codeSize, MAX_DEPTH, CLOCK, CHALLENGER_BOND);
        bridge = new Bridge(queue, oracle);
        assertEq(address(game), predictedGame);
        assertEq(address(bridge), predictedBridge);
    }

    /// @dev Posts an empty batch (tape = [0]) and returns its epoch.
    function _postEmptyBatch() internal returns (uint256 epoch) {
        vm.prank(sequencer);
        epoch = inbox.submitBatch("", new Record[](0));
    }

    function _propose(address who, uint64 epoch, bytes32 root) internal returns (uint256 id) {
        vm.prank(who);
        id = oracle.propose{value: PROPOSER_BOND}(epoch, root);
    }

    function _challenge(address who, uint64 epoch) internal returns (uint256 id) {
        vm.prank(who);
        id = game.challenge{value: CHALLENGER_BOND}(epoch);
    }

    /// @dev Computes the honest trace of the tiny program for `epoch` starting from the empty tree.
    function _computeHonestTrace(uint64 epoch) internal {
        Machine memory m = game.initialMachine(epoch, bytes32(0));
        bytes32[] memory s0 = new bytes32[](0);
        bytes32[] memory s1 = new bytes32[](1);
        s1[0] = bytes32(uint256(42));
        bytes32[] memory s2 = new bytes32[](2);
        (s2[0], s2[1]) = (bytes32(uint256(42)), bytes32(uint256(1)));
        stacks[0] = s0;
        stacks[1] = s1;
        stacks[2] = s2;
        stacks[3] = s0;
        honest[0] = m;
        for (uint256 i = 0; i < 4; ++i) {
            m = osvm.step(m, _honestWitness(i));
            honest[i + 1] = m;
        }
        assertEq(honest[4].status, VmSpec.STATUS_HALTED);
        assertEq(honest[4].stateRoot, r42);
    }

    function _reads(uint256 i) internal pure returns (uint256) {
        return i == 2 ? 2 : 0;
    }

    function _honestWitness(uint256 i) internal view returns (StepProof memory w) {
        w = tiny.witness(i, stacks[i], _reads(i));
    }

    /// @dev Honest state hash after `i` steps (padded with the halted state).
    function _honestHash(uint256 i) internal view returns (bytes32) {
        return VmSpec.hash(honest[i > 4 ? 4 : i]);
    }

    /// @dev A halted end state carrying `root` (anything else equal to the honest end).
    function _endWithRoot(bytes32 root) internal view returns (Machine memory m) {
        m = honest[4];
        m.stateRoot = root;
    }

    /// @dev Plays the full bisection with the defender posting `defenderHash(mid)` and an honest challenger.
    function _playHonestChallenger(uint256 gameId, bool defenderHonest) internal {
        for (uint256 round = 0; round < MAX_DEPTH; ++round) {
            (uint64 lo, uint64 hi) = _range(gameId);
            uint64 mid = lo + (hi - lo) / 2;
            bytes32 claimed = defenderHonest ? _honestHash(mid) : keccak256(abi.encode("lie", mid));
            vm.prank(proposer);
            game.bisect(gameId, claimed);
            vm.prank(challenger);
            game.choose(gameId, claimed == _honestHash(mid));
        }
    }

    function _range(uint256 gameId) internal view returns (uint64 lo, uint64 hi) {
        DisputeGame.Game memory g = game.getGame(gameId);
        return (g.lo, g.hi);
    }

    function _stepAtLeaf(uint256 gameId) internal {
        (uint64 lo,) = _range(gameId);
        StepProof memory w;
        if (lo < 4) w = _honestWitness(lo);
        game.step(gameId, honest[lo > 4 ? 4 : lo], w);
    }
}
