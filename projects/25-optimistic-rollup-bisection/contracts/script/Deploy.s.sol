// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Script} from "forge-std/Script.sol";
import {OneStepVM} from "../src/OneStepVM.sol";
import {ForcedInclusionQueue} from "../src/ForcedInclusionQueue.sol";
import {BatchInbox} from "../src/BatchInbox.sol";
import {OutputOracle} from "../src/OutputOracle.sol";
import {DisputeGame} from "../src/DisputeGame.sol";
import {Bridge} from "../src/Bridge.sol";

/// @notice Deploys the six contracts with precomputed CREATE addresses (they reference each other immutably).
/// @dev Keystore-based, no raw keys:
///      forge script script/Deploy.s.sol --rpc-url $RPC --account deployer --broadcast
///      Required env: SEQUENCER, CODE_ROOT, CODE_SIZE (print them with `cargo run -p rollup-node --bin rollup-cli --
///      program`). Optional env (devnet defaults): OWNER, INCLUSION_WINDOW, PROPOSER_BOND, CHALLENGER_BOND,
///      CHALLENGE_WINDOW, CLOCK, MAX_DEPTH (14..40). The genesis state is always empty: the Rust node derives from an
///      empty tree, so any other genesis root would make every honest party lose its games.
///      This script writes no descriptor for the Rust services; `rollup-cli deploy --keystore <file>` does both.
contract Deploy is Script {
    /// @notice VM steps of the most expensive batch the inbox accepts (32 forced and 64 signed withdrawals), measured
    ///         and cross-checked against this file by `worst_case_batch_fits_the_trace` in crates/stf.
    uint256 public constant WORST_CASE_TRACE_STEPS = 11_832;
    /// @notice Smallest bisection depth whose `2^depth`-step trace holds the worst-case batch.
    uint8 public constant MIN_MAX_DEPTH = 14;
    /// @notice Largest depth `DisputeGame` accepts.
    uint8 public constant MAX_MAX_DEPTH = 40;

    struct Params {
        address owner;
        address sequencer;
        uint64 inclusionWindow;
        uint256 proposerBond;
        uint256 challengerBond;
        uint64 challengeWindow;
        uint64 clock;
        uint8 maxDepth;
        bytes32 genesisStateRoot;
        bytes32 codeRoot;
        uint32 codeSize;
    }

    struct Deployed {
        OneStepVM osvm;
        ForcedInclusionQueue queue;
        BatchInbox inbox;
        OutputOracle oracle;
        DisputeGame game;
        Bridge bridge;
    }

    /// @notice The deployed contracts do not reference each other as precomputed.
    error WiringMismatch();
    /// @notice `2^maxDepth` steps cannot hold the worst-case trace, or the game would reject the depth.
    error MaxDepthOutOfRange(uint256 maxDepth, uint256 min, uint256 max);
    /// @notice Only the empty genesis state is supported by the node.
    error UnsupportedGenesis(bytes32 genesisStateRoot);

    function run() external returns (Deployed memory d) {
        vm.startBroadcast();
        (, address sender,) = vm.readCallers();
        d = deployWith(paramsFromEnv(sender), sender);
        vm.stopBroadcast();
    }

    function paramsFromEnv(address defaultOwner) public view returns (Params memory p) {
        p.owner = vm.envOr("OWNER", defaultOwner);
        p.sequencer = vm.envAddress("SEQUENCER");
        p.inclusionWindow = uint64(vm.envOr("INCLUSION_WINDOW", uint256(10)));
        p.proposerBond = vm.envOr("PROPOSER_BOND", uint256(1 ether));
        p.challengerBond = vm.envOr("CHALLENGER_BOND", uint256(0.5 ether));
        p.challengeWindow = uint64(vm.envOr("CHALLENGE_WINDOW", uint256(3600)));
        p.clock = uint64(vm.envOr("CLOCK", uint256(1800)));
        p.maxDepth = checkedDepth(vm.envOr("MAX_DEPTH", uint256(16)));
        p.genesisStateRoot = bytes32(0);
        p.codeRoot = vm.envBytes32("CODE_ROOT");
        p.codeSize = uint32(vm.envUint("CODE_SIZE"));
    }

    /// @notice Validates a bisection depth before it is narrowed to `uint8`.
    /// @param raw Requested depth.
    /// @return depth The same depth, known to be in `MIN_MAX_DEPTH..MAX_MAX_DEPTH`.
    function checkedDepth(uint256 raw) public pure returns (uint8 depth) {
        require(raw >= MIN_MAX_DEPTH && raw <= MAX_MAX_DEPTH, MaxDepthOutOfRange(raw, MIN_MAX_DEPTH, MAX_MAX_DEPTH));
        // In range 14..40 (checked above), so the narrowing is exact.
        // forge-lint: disable-next-line(unsafe-typecast)
        depth = uint8(raw);
    }

    /// @param p Parameters.
    /// @param creator Account whose next six nonces create the contracts (the broadcaster, or this contract in tests).
    function deployWith(Params memory p, address creator) public returns (Deployed memory d) {
        checkedDepth(p.maxDepth);
        require(p.genesisStateRoot == bytes32(0), UnsupportedGenesis(p.genesisStateRoot));
        uint64 nonce = vm.getNonce(creator);
        address predictedGame = vm.computeCreateAddress(creator, nonce + 4);
        address predictedBridge = vm.computeCreateAddress(creator, nonce + 5);

        d.osvm = new OneStepVM();
        d.queue = new ForcedInclusionQueue(predictedBridge, p.inclusionWindow);
        d.inbox = new BatchInbox(d.queue, p.owner, p.sequencer);
        d.oracle = new OutputOracle(d.inbox, predictedGame, p.genesisStateRoot, p.proposerBond, p.challengeWindow);
        d.game =
            new DisputeGame(d.oracle, d.inbox, d.osvm, p.codeRoot, p.codeSize, p.maxDepth, p.clock, p.challengerBond);
        d.bridge = new Bridge(d.queue, d.oracle);

        require(
            address(d.game) == predictedGame && address(d.bridge) == predictedBridge
                && d.queue.BRIDGE() == address(d.bridge) && d.oracle.DISPUTE_GAME() == address(d.game),
            WiringMismatch()
        );
    }
}
