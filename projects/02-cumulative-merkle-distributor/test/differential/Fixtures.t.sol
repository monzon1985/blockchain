// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {CumulativeMerkleDistributor} from "../../src/CumulativeMerkleDistributor.sol";
import {ICumulativeMerkleDistributor} from "../../src/interfaces/ICumulativeMerkleDistributor.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MerkleBuilder} from "../utils/MerkleBuilder.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {Test} from "forge-std/Test.sol";

/// @notice TypeScript-to-Solidity differential: replays, on-chain, every tree, proof, multiproof and EIP-712 signature
///         that tree-builder wrote to test/fixtures (`npm run fixtures`; `npm run fixtures -- --check` in CI fails if
///         the committed files drift from what the builder produces). Nothing here is hand-written: if the builder and
///         the contract disagree on a leaf encoding, a sort order, a node hash or a type hash, these tests fail.
contract FixturesTest is Test {
    struct FixtureClaim {
        address account;
        address token;
        uint256 cumulativeAmount;
        bytes32 leaf;
        bytes32[] proof;
    }

    string internal constant CLAIM_TYPE =
        "FixtureClaim(address account,address token,uint256 cumulativeAmount,bytes32 leaf,bytes32[] proof)";
    string internal constant LEAF_TYPE = "ClaimLeaf(address account,address token,uint256 cumulativeAmount)";
    string internal constant MOCK_ERC20 = "MockERC20.sol:MockERC20";

    address internal owner = makeAddr("owner");
    address internal updater = makeAddr("updater");
    address internal guardian = makeAddr("guardian");

    CumulativeMerkleDistributor internal distributor;

    function setUp() public {
        vm.warp(1_750_000_000);
    }

    // ------------------------------------------------------------------------------------------------ helpers

    function _read(string memory name) internal view returns (string memory) {
        return vm.readFile(string.concat(vm.projectRoot(), "/test/fixtures/", name));
    }

    function _epochKey(uint256 i) internal pure returns (string memory) {
        return string.concat(".epochs[", vm.toString(i), "]");
    }

    function _epochCount(string memory json) internal view returns (uint256 n) {
        while (vm.keyExistsJson(json, _epochKey(n))) ++n;
    }

    function _claims(string memory json, uint256 i) internal pure returns (FixtureClaim[] memory) {
        return
            abi.decode(
                vm.parseJsonTypeArray(json, string.concat(_epochKey(i), ".claims"), CLAIM_TYPE), (FixtureClaim[])
            );
    }

    /// @dev Deploys a fresh distributor and a mock ERC-20 at every token address of the fixture, funded with the
    ///      final cumulative totals (exactly what the last root allocates, nothing more).
    function _deploy(string memory json) internal {
        distributor = new CumulativeMerkleDistributor(owner, updater, guardian);
        address[] memory tokens = vm.parseJsonAddressArray(json, ".tokens");
        string[] memory totals = vm.parseJsonStringArray(json, ".finalTotals");
        assertEq(tokens.length, totals.length);
        for (uint256 t; t < tokens.length; ++t) {
            deployCodeTo(MOCK_ERC20, abi.encode("Fixture token", "FIX"), tokens[t]);
            MockERC20(tokens[t]).mint(address(distributor), vm.parseUint(totals[t]));
        }
    }

    function _activate(string memory json, uint256 i) internal {
        bytes32 root = vm.parseJsonBytes32(json, string.concat(_epochKey(i), ".root"));
        bytes32 meta = vm.parseJsonBytes32(json, string.concat(_epochKey(i), ".metadataHash"));
        vm.prank(updater);
        distributor.proposeRoot(root, meta);
        vm.warp(block.timestamp + distributor.ROOT_TIMELOCK());
        distributor.acceptRoot();
        assertEq(distributor.root(), root);
        assertEq(distributor.metadataHash(), meta);
    }

    function _sortAscending(bytes32[] memory a) internal pure {
        for (uint256 i = 1; i < a.length; ++i) {
            bytes32 v = a[i];
            uint256 j = i;
            while (j > 0 && a[j - 1] > v) {
                a[j] = a[j - 1];
                --j;
            }
            a[j] = v;
        }
    }

    // ------------------------------------------------------------------------------------------------ tree + proofs

    /// @notice Every leaf hash, every proof and every root of every epoch agree with the contract, and claiming every
    ///         leaf of every epoch in turn pays exactly the per-epoch deltas and empties the vault.
    function _replayEveryClaim(string memory name) internal {
        string memory json = _read(name);
        _deploy(json);
        uint256 epochs = _epochCount(json);
        assertGt(epochs, 1, "fixture must span several epochs");

        FixtureClaim[] memory claims;
        for (uint256 e; e < epochs; ++e) {
            _activate(json, e);
            claims = _claims(json, e);
            assertEq(claims.length, vm.parseJsonUint(json, string.concat(_epochKey(e), ".leafCount")));

            // The in-EVM builder reproduces the TypeScript root from the sorted leaves (StandardMerkleTree layout).
            bytes32[] memory leaves = new bytes32[](claims.length);
            for (uint256 k; k < claims.length; ++k) {
                leaves[k] = claims[k].leaf;
            }
            _sortAscending(leaves);
            assertEq(MerkleBuilder.root(leaves), distributor.root(), "in-EVM rebuild != builder root");

            for (uint256 k; k < claims.length; ++k) {
                FixtureClaim memory c = claims[k];
                assertEq(distributor.leafHash(c.account, c.token, c.cumulativeAmount), c.leaf, "leaf encoding");
                assertTrue(MerkleProof.verify(c.proof, distributor.root(), c.leaf), "proof");

                uint256 already = distributor.claimed(c.account, c.token);
                // Cumulative amounts never go down from one epoch to the next.
                assertGe(c.cumulativeAmount, already, "non-monotonic cumulative amount");
                if (c.cumulativeAmount == already) {
                    vm.expectRevert(
                        abi.encodeWithSelector(
                            ICumulativeMerkleDistributor.NothingToClaim.selector,
                            c.account,
                            c.token,
                            c.cumulativeAmount,
                            already
                        )
                    );
                    distributor.claim(c.account, c.token, c.cumulativeAmount, c.proof);
                } else {
                    uint256 paid = distributor.claim(c.account, c.token, c.cumulativeAmount, c.proof);
                    assertEq(paid, c.cumulativeAmount - already, "paid != delta");
                }
            }
        }

        // After the last epoch every account holds exactly its final cumulative amount and the vault is empty.
        for (uint256 k; k < claims.length; ++k) {
            assertEq(distributor.claimed(claims[k].account, claims[k].token), claims[k].cumulativeAmount);
        }
        address[] memory tokens = vm.parseJsonAddressArray(json, ".tokens");
        for (uint256 t; t < tokens.length; ++t) {
            assertEq(MockERC20(tokens[t]).balanceOf(address(distributor)), 0, "vault not emptied exactly");
        }
    }

    /// @notice Every epoch's TypeScript multiproof is accepted by `claimMany` against that epoch's root.
    function _replayMultiproofs(string memory name) internal {
        string memory json = _read(name);
        _deploy(json);
        uint256 epochs = _epochCount(json);
        for (uint256 e; e < epochs; ++e) {
            _activate(json, e);
            string memory key = string.concat(_epochKey(e), ".multiproof");
            ICumulativeMerkleDistributor.ClaimLeaf[] memory batch = abi.decode(
                vm.parseJsonTypeArray(json, string.concat(key, ".claims"), LEAF_TYPE),
                (ICumulativeMerkleDistributor.ClaimLeaf[])
            );
            bytes32[] memory proof = vm.parseJsonBytes32Array(json, string.concat(key, ".proof"));
            bool[] memory flags = vm.parseJsonBoolArray(json, string.concat(key, ".proofFlags"));
            assertGt(batch.length, 1);

            uint256[] memory expected = new uint256[](batch.length);
            for (uint256 k; k < batch.length; ++k) {
                expected[k] = batch[k].cumulativeAmount - distributor.claimed(batch[k].account, batch[k].token);
            }
            uint256[] memory paid = distributor.claimMany(batch, proof, flags);
            for (uint256 k; k < batch.length; ++k) {
                assertEq(paid[k], expected[k]);
                assertEq(distributor.claimed(batch[k].account, batch[k].token), batch[k].cumulativeAmount);
            }
        }
    }

    /// @notice Skipping every intermediate epoch: only the last root is ever accepted and each account claims its
    ///         whole history with one proof.
    function _replayLastEpochOnly(string memory name) internal {
        string memory json = _read(name);
        _deploy(json);
        uint256 last = _epochCount(json) - 1;
        _activate(json, last);
        FixtureClaim[] memory claims = _claims(json, last);
        for (uint256 k; k < claims.length; ++k) {
            FixtureClaim memory c = claims[k];
            assertEq(distributor.claim(c.account, c.token, c.cumulativeAmount, c.proof), c.cumulativeAmount);
            assertEq(MockERC20(c.token).balanceOf(c.account), c.cumulativeAmount);
        }
    }

    function test_example_everyEpochEveryClaim() public {
        _replayEveryClaim("example.json");
    }

    function test_random_everyEpochEveryClaim() public {
        _replayEveryClaim("random.json");
    }

    function test_example_multiproofs() public {
        _replayMultiproofs("example.json");
    }

    function test_random_multiproofs() public {
        _replayMultiproofs("random.json");
    }

    function test_example_lastEpochOnly() public {
        _replayLastEpochOnly("example.json");
    }

    function test_random_lastEpochOnly() public {
        _replayLastEpochOnly("random.json");
    }

    // ------------------------------------------------------------------------------------------------ EIP-712

    struct Authorization {
        address account;
        address token;
        uint256 amount;
        address recipient;
        uint256 nonce;
        uint256 deadline;
        bytes32[] proof;
        bytes signature;
    }

    function _authorization(string memory auth) internal pure returns (Authorization memory a) {
        a.account = vm.parseJsonAddress(auth, ".message.account");
        a.token = vm.parseJsonAddress(auth, ".message.token");
        a.amount = vm.parseUint(vm.parseJsonString(auth, ".message.cumulativeAmount"));
        a.recipient = vm.parseJsonAddress(auth, ".message.recipient");
        a.nonce = vm.parseUint(vm.parseJsonString(auth, ".message.nonce"));
        a.deadline = vm.parseUint(vm.parseJsonString(auth, ".message.deadline"));
        a.proof = vm.parseJsonBytes32Array(auth, ".proof");
        a.signature = vm.parseJsonBytes(auth, ".signature");
    }

    function _digest(Authorization memory a) internal view returns (bytes32) {
        return distributor.hashClaimAuthorization(a.account, a.token, a.amount, a.recipient, a.nonce, a.deadline);
    }

    function _claimFor(Authorization memory a) internal returns (uint256) {
        return distributor.claimFor(a.account, a.token, a.amount, a.proof, a.recipient, a.deadline, a.signature);
    }

    /// @notice A claim authorization typed, hashed and signed by viem is accepted by `claimFor`, at the address and on
    ///         the chain it was signed for, and rejected on any other chain.
    function test_claimAuthorization_signedByViem() public {
        string memory auth = _read("claim-authorization.json");
        string memory example = _read("example.json");
        address verifying = vm.parseJsonAddress(auth, ".verifyingContract");
        vm.chainId(vm.parseJsonUint(auth, ".chainId"));

        deployCodeTo(
            "CumulativeMerkleDistributor.sol:CumulativeMerkleDistributor",
            abi.encode(owner, updater, guardian),
            verifying
        );
        distributor = CumulativeMerkleDistributor(verifying);
        address[] memory tokens = vm.parseJsonAddressArray(example, ".tokens");
        string[] memory totals = vm.parseJsonStringArray(example, ".finalTotals");
        for (uint256 t; t < tokens.length; ++t) {
            deployCodeTo(MOCK_ERC20, abi.encode("Fixture token", "FIX"), tokens[t]);
            MockERC20(tokens[t]).mint(verifying, vm.parseUint(totals[t]));
        }
        _activate(example, vm.parseJsonUint(auth, ".epoch") - 1);
        assertEq(distributor.root(), vm.parseJsonBytes32(auth, ".root"));

        Authorization memory a = _authorization(auth);
        (address labelled,) = makeAddrAndKey(vm.parseJsonString(auth, ".signerLabel"));
        assertEq(a.account, labelled, "signer is Foundry's makeAddrAndKey(label)");
        assertEq(distributor.DOMAIN_SEPARATOR(), vm.parseJsonBytes32(auth, ".domainSeparator"), "domain separator");
        assertEq(_digest(a), vm.parseJsonBytes32(auth, ".digest"), "EIP-712 digest");

        // Same bytes on another chain: the domain separator differs, so the signature does not verify.
        uint256 chain = block.chainid;
        vm.chainId(chain + 1);
        vm.expectRevert(
            abi.encodeWithSelector(ICumulativeMerkleDistributor.InvalidSignature.selector, a.account, _digest(a))
        );
        _claimFor(a);
        vm.chainId(chain);

        vm.prank(makeAddr("relayer"));
        assertEq(_claimFor(a), a.amount);
        assertEq(MockERC20(a.token).balanceOf(a.recipient), a.amount);
        assertEq(distributor.nonces(a.account), a.nonce + 1);
    }
}
