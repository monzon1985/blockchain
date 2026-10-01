// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {CumulativeMerkleDistributor} from "../../src/CumulativeMerkleDistributor.sol";
import {ICumulativeMerkleDistributor} from "../../src/interfaces/ICumulativeMerkleDistributor.sol";
import {MockERC1271Wallet} from "../mocks/MockERC1271Wallet.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MerkleBuilder} from "../utils/MerkleBuilder.sol";
import {
    BatchClaimer,
    EpochBitmapDistributor,
    EpochBoolDistributor,
    EpochDistributorBase
} from "./EpochDistributors.sol";
import {Test, Vm} from "forge-std/Test.sol";

/// @title GasBench
/// @notice Deterministic gas study behind the storage and proof choices of the distributor. Every figure is the gas of
///         a whole transaction, net of refunds: `isolate = true` runs each top-level call as its own transaction, so it
///         includes the 21,000 base cost, calldata (and the EIP-7623 floor where it binds) and cold storage access.
///         Results go to snapshots/GasBench.json (rendered into the README by `npm run gas-table`); per-test totals go
///         to .gas-snapshot (checked by `forge snapshot --check --match-contract GasBench`).
contract GasBench is Test {
    string internal constant G = "GasBench";
    uint256 internal constant FLAG_LEAVES = 256;
    uint256 internal constant BATCH_LEAVES = 4096; // a perfect tree: every single proof has exactly 12 hashes
    uint256 internal constant BATCH_DEPTH = 12;

    MockERC20 internal token;
    CumulativeMerkleDistributor internal cumulative;
    EpochBitmapDistributor internal epochBitmap;
    EpochBoolDistributor internal epochBool;
    BatchClaimer internal batcher;
    address internal updater = makeAddr("updater");

    function setUp() public {
        vm.warp(1_750_000_000);
        token = new MockERC20("Reward", "RWD");
        cumulative = new CumulativeMerkleDistributor(address(this), updater, makeAddr("guardian"));
        epochBitmap = new EpochBitmapDistributor();
        epochBool = new EpochBoolDistributor();
        batcher = new BatchClaimer();
        token.mint(address(cumulative), 1e30);
        token.mint(address(epochBitmap), 1e30);
        token.mint(address(epochBool), 1e30);
    }

    // ------------------------------------------------------------------------------------------------ helpers

    function _account(uint256 i) internal pure returns (address) {
        return address(uint160(0x10000 + i));
    }

    /// @dev Net gas (after refunds) of the last transaction; equals what `snapshotGasLastFrame` records.
    function _lastTxGas() internal view returns (uint256) {
        Vm.Gas memory g = vm.lastFrameGas();
        return uint256(g.gasTotalUsed) - uint256(int256(g.gasRefunded));
    }

    function _epochTree(uint256 n) internal view returns (bytes32[] memory) {
        bytes32[] memory leaves = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            leaves[i] = keccak256(bytes.concat(keccak256(abi.encode(i, _account(i), address(token), uint256(1e18)))));
        }
        return MerkleBuilder.build(leaves);
    }

    function _cumulativeTree(uint256 n, uint256 amount) internal view returns (bytes32[] memory) {
        bytes32[] memory leaves = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            leaves[i] = MerkleBuilder.leaf(_account(i), address(token), amount);
        }
        return MerkleBuilder.build(leaves);
    }

    function _proof(bytes32[] memory tree, uint256 n, uint256 i) internal pure returns (bytes32[] memory) {
        return MerkleBuilder.proof(tree, MerkleBuilder.treeIndexOf(n, i));
    }

    function _publish(bytes32 root) internal {
        vm.prank(updater);
        cumulative.proposeRoot(root, bytes32(0));
        vm.warp(block.timestamp + 24 hours);
        cumulative.acceptRoot();
    }

    function _key(string memory a, string memory b, string memory c) internal pure returns (string memory) {
        return string.concat(a, ".", b, ".", c);
    }

    // ------------------------------------------------------------------------------------------------ claimed flags

    /// @dev 100 claims of one epoch (indices 0..99, one bitmap word), then the first claim of the next epoch.
    function _epochFlags(EpochDistributorBase d, string memory name) internal {
        bytes32[] memory tree = _epochTree(FLAG_LEAVES);
        d.setRoot(1, tree[0]);
        uint256 total;
        for (uint256 i; i < 100; ++i) {
            d.claim(1, i, _account(i), address(token), 1e18, _proof(tree, FLAG_LEAVES, i));
            if (i == 0) total += vm.snapshotGasLastFrame(G, _key("flags", name, "first_claim"));
            else if (i == 1) total += vm.snapshotGasLastFrame(G, _key("flags", name, "second_claim"));
            else total += _lastTxGas();
        }
        vm.snapshotValue(G, _key("flags", name, "avg_of_100_claims"), total / 100);

        d.setRoot(2, tree[0]);
        d.claim(2, 0, _account(0), address(token), 1e18, _proof(tree, FLAG_LEAVES, 0));
        vm.snapshotGasLastFrame(G, _key("flags", name, "next_epoch_claim"));
    }

    function test_Flags_EpochBool() public {
        _epochFlags(epochBool, "epoch_bool");
    }

    function test_Flags_EpochBitmap() public {
        _epochFlags(epochBitmap, "epoch_bitmap");
    }

    function test_Flags_Cumulative() public {
        bytes32[] memory tree = _cumulativeTree(FLAG_LEAVES, 1e18);
        _publish(tree[0]);
        uint256 total;
        for (uint256 i; i < 100; ++i) {
            cumulative.claim(_account(i), address(token), 1e18, _proof(tree, FLAG_LEAVES, i));
            if (i == 0) {
                uint256 recorded = vm.snapshotGasLastFrame(G, "flags.cumulative.first_claim");
                assertEq(recorded, _lastTxGas(), "measurement methods agree");
                total += recorded;
            } else if (i == 1) {
                total += vm.snapshotGasLastFrame(G, "flags.cumulative.second_claim");
            } else {
                total += _lastTxGas();
            }
        }
        vm.snapshotValue(G, "flags.cumulative.avg_of_100_claims", total / 100);

        tree = _cumulativeTree(FLAG_LEAVES, 2e18);
        _publish(tree[0]);
        cumulative.claim(_account(0), address(token), 2e18, _proof(tree, FLAG_LEAVES, 0));
        vm.snapshotGasLastFrame(G, "flags.cumulative.next_epoch_claim");
    }

    // ------------------------------------------------------------------------------------------------ catch-up

    /// @notice One account collects four epochs of rewards: four claims in epoch mode, one in cumulative mode.
    function test_CatchUp_FourEpochs() public {
        bytes32[] memory tree = _epochTree(FLAG_LEAVES);
        bytes32[] memory proof = _proof(tree, FLAG_LEAVES, 7);
        EpochDistributorBase[2] memory ds = [EpochDistributorBase(epochBitmap), EpochDistributorBase(epochBool)];
        string[2] memory names = ["epoch_bitmap", "epoch_bool"];
        // Every variant starts from the same state (in particular, the account holds no tokens yet).
        uint256 snapshot = vm.snapshotState();
        for (uint256 k; k < 2; ++k) {
            uint256 total;
            for (uint256 e = 1; e <= 4; ++e) {
                ds[k].setRoot(e, tree[0]);
                ds[k].claim(e, 7, _account(7), address(token), 1e18, proof);
                total += _lastTxGas();
            }
            vm.snapshotValue(G, _key("catchup", names[k], "four_epochs"), total);
            vm.revertToState(snapshot);
        }

        bytes32[] memory cumulativeTree = _cumulativeTree(FLAG_LEAVES, 4e18);
        _publish(cumulativeTree[0]);
        cumulative.claim(_account(7), address(token), 4e18, _proof(cumulativeTree, FLAG_LEAVES, 7));
        vm.snapshotGasLastFrame(G, "catchup.cumulative.four_epochs");
    }

    // ------------------------------------------------------------------------------------------------ batches

    /// @dev Claims `k` pseudo-randomly spread leaves of a 4,096-leaf tree three ways, each from the same state.
    function _batch(uint256 k, string memory label) internal {
        bytes32[] memory tree = _cumulativeTree(BATCH_LEAVES, 1e18);
        _publish(tree[0]);

        ICumulativeMerkleDistributor.ClaimLeaf[] memory leaves = new ICumulativeMerkleDistributor.ClaimLeaf[](k);
        bytes32[][] memory proofs = new bytes32[][](k);
        uint256[] memory treeIndices = new uint256[](k);
        for (uint256 j; j < k; ++j) {
            // 2477 is odd, hence coprime with 4096: distinct, well-spread indices.
            uint256 i = (j * 2477 + 17) % BATCH_LEAVES;
            leaves[j] = ICumulativeMerkleDistributor.ClaimLeaf(_account(i), address(token), 1e18);
            proofs[j] = _proof(tree, BATCH_LEAVES, i);
            treeIndices[j] = MerkleBuilder.treeIndexOf(BATCH_LEAVES, i);
        }
        uint256 snapshot = vm.snapshotState();

        // (a) one transaction per claim
        uint256 total;
        for (uint256 j; j < k; ++j) {
            cumulative.claim(leaves[j].account, leaves[j].token, leaves[j].cumulativeAmount, proofs[j]);
            total += _lastTxGas();
        }
        vm.snapshotValue(G, _key("batch", label, "separate_txs"), total);
        vm.revertToState(snapshot);

        // (b) single proofs, one transaction
        batcher.claimAll(cumulative, leaves, proofs);
        vm.snapshotGasLastFrame(G, _key("batch", label, "single_proofs_one_tx"));
        vm.revertToState(snapshot);

        // (c) one multiproof
        MerkleBuilder.MultiProof memory mp = MerkleBuilder.multiProof(tree, treeIndices);
        ICumulativeMerkleDistributor.ClaimLeaf[] memory ordered = new ICumulativeMerkleDistributor.ClaimLeaf[](k);
        for (uint256 j; j < k; ++j) {
            ordered[j] = ICumulativeMerkleDistributor.ClaimLeaf(
                _account(2 * BATCH_LEAVES - 2 - mp.treeIndices[j]), address(token), 1e18
            );
        }
        cumulative.claimMany(ordered, mp.proof, mp.proofFlags);
        vm.snapshotGasLastFrame(G, _key("batch", label, "multiproof"));
        vm.snapshotValue(G, _key("batch", label, "single_proof_hashes"), k * BATCH_DEPTH);
        vm.snapshotValue(G, _key("batch", label, "multiproof_hashes"), mp.proof.length);
        for (uint256 j; j < k; ++j) {
            assertEq(token.balanceOf(leaves[j].account), 1e18);
        }
    }

    function test_Batch_001() public {
        _batch(1, "001");
    }

    function test_Batch_010() public {
        _batch(10, "010");
    }

    function test_Batch_100() public {
        _batch(100, "100");
    }

    // ------------------------------------------------------------------------------------------------ claim paths

    /// @notice The same leaf claimed directly, through an EOA signature and through an ERC-1271 wallet, plus the
    ///         root-lifecycle calls, on a 256-leaf tree.
    function test_ClaimPaths() public {
        (address signer, uint256 signerKey) = makeAddrAndKey("signer");
        MockERC1271Wallet wallet = new MockERC1271Wallet(signer);
        bytes32[] memory leaves = new bytes32[](FLAG_LEAVES);
        for (uint256 i; i < FLAG_LEAVES; ++i) {
            leaves[i] = MerkleBuilder.leaf(_account(i), address(token), 1e18);
        }
        leaves[0] = MerkleBuilder.leaf(signer, address(token), 1e18);
        leaves[1] = MerkleBuilder.leaf(address(wallet), address(token), 1e18);
        bytes32[] memory tree = MerkleBuilder.build(leaves);

        vm.prank(updater);
        cumulative.proposeRoot(tree[0], keccak256("manifest"));
        vm.snapshotGasLastFrame(G, "lifecycle.proposeRoot");
        vm.warp(block.timestamp + 24 hours);
        cumulative.acceptRoot();
        vm.snapshotGasLastFrame(G, "lifecycle.acceptRoot");
        vm.prank(updater);
        cumulative.proposeRoot(keccak256("next"), bytes32(0));
        vm.prank(makeAddr("guardian"));
        cumulative.revokePendingRoot();
        vm.snapshotGasLastFrame(G, "lifecycle.revokePendingRoot");

        cumulative.claim(_account(2), address(token), 1e18, _proof(tree, FLAG_LEAVES, 2));
        vm.snapshotGasLastFrame(G, "paths.claim");

        address recipient = makeAddr("recipient");
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = cumulative.hashClaimAuthorization(signer, address(token), 1e18, recipient, 0, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        cumulative.claimFor(
            signer, address(token), 1e18, _proof(tree, FLAG_LEAVES, 0), recipient, deadline, abi.encodePacked(r, s, v)
        );
        vm.snapshotGasLastFrame(G, "paths.claimFor_eoa");

        address recipient2 = makeAddr("recipient 2");
        digest = cumulative.hashClaimAuthorization(address(wallet), address(token), 1e18, recipient2, 0, deadline);
        (v, r, s) = vm.sign(signerKey, digest);
        cumulative.claimFor(
            address(wallet),
            address(token),
            1e18,
            _proof(tree, FLAG_LEAVES, 1),
            recipient2,
            deadline,
            abi.encodePacked(r, s, v)
        );
        vm.snapshotGasLastFrame(G, "paths.claimFor_erc1271");
    }
}
