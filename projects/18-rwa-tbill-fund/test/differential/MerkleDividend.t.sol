// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {MerkleProof} from "@openzeppelin-contracts/utils/cryptography/MerkleProof.sol";
import {FundFixture} from "../utils/FundFixture.sol";
import {StandardMerkleTree} from "../utils/StandardMerkleTree.sol";

/// @notice Differential test across languages: the Node builder (OpenZeppelin's JavaScript StandardMerkleTree)
///         produced the committed `test/fixtures/dividend-tree*.json` artefacts; here an independent Solidity
///         port rebuilds each root from the same entitlements, every proof is checked with OpenZeppelin's
///         on-chain `MerkleProof` and compared byte for byte with the port's, and every distribution is funded
///         and claimed through `DividendDistributor`. The fixtures have 1, 3, 4, 5 and 7 leaves, so the
///         array-backed layout is exercised where it is not a perfect binary tree.
contract MerkleDividendDifferentialTest is FundFixture {
    string[5] internal FIXTURES = [
        "dividend-tree.json",
        "dividend-tree-1.json",
        "dividend-tree-3.json",
        "dividend-tree-5.json",
        "dividend-tree-7.json"
    ];
    uint256[5] internal LEAVES = [uint256(4), 1, 3, 5, 7];

    function _load(uint256 k)
        internal
        view
        returns (string memory json, address[] memory accounts, uint256[] memory amounts)
    {
        json = vm.readFile(string.concat("test/fixtures/", FIXTURES[k]));
        uint256 count = vm.parseJsonUint(json, ".count");
        accounts = new address[](count);
        amounts = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            string memory base = string.concat(".claims[", vm.toString(i), "]");
            accounts[i] = vm.parseJsonAddress(json, string.concat(base, ".account"));
            amounts[i] = vm.parseJsonUint(json, string.concat(base, ".amount"));
        }
    }

    function _proof(string memory json, uint256 i) internal pure returns (bytes32[] memory) {
        return vm.parseJsonBytes32Array(json, string.concat(".claims[", vm.toString(i), "].proof"));
    }

    function test_fixtureAccountsAreTheOnboardedInvestors() public view {
        (, address[] memory accounts,) = _load(0);
        assertEq(accounts.length, 4);
        assertEq(accounts[0], bob);
        assertEq(accounts[1], alice);
        assertEq(accounts[2], dave);
        assertEq(accounts[3], carol);
    }

    function test_solidityPortRebuildsEveryJavaScriptRoot() public view {
        for (uint256 k; k < FIXTURES.length; ++k) {
            (string memory json, address[] memory accounts, uint256[] memory amounts) = _load(k);
            assertEq(accounts.length, LEAVES[k], FIXTURES[k]);
            (bytes32[] memory tree,) = StandardMerkleTree.build(accounts, amounts);
            assertEq(tree[0], vm.parseJsonBytes32(json, ".root"), FIXTURES[k]);
        }
    }

    function test_javascriptProofsVerifyOnChainAndMatchThePort() public view {
        for (uint256 k; k < FIXTURES.length; ++k) {
            (string memory json, address[] memory accounts, uint256[] memory amounts) = _load(k);
            bytes32 root = vm.parseJsonBytes32(json, ".root");
            (bytes32[] memory tree, uint256[] memory treeIndex) = StandardMerkleTree.build(accounts, amounts);
            for (uint256 i; i < accounts.length; ++i) {
                bytes32[] memory proof = _proof(json, i);
                bytes32 leaf = StandardMerkleTree.leafHash(accounts[i], amounts[i]);
                assertTrue(MerkleProof.verify(proof, root, leaf), "JS proof rejected by MerkleProof");
                assertEq(
                    keccak256(abi.encode(proof)),
                    keccak256(abi.encode(StandardMerkleTree.proof(tree, treeIndex[i]))),
                    FIXTURES[k]
                );
            }
        }
    }

    function test_allocatedAmountsSumAndDust() public view {
        for (uint256 k; k < FIXTURES.length; ++k) {
            (string memory json,, uint256[] memory amounts) = _load(k);
            uint256 sum;
            for (uint256 i; i < amounts.length; ++i) {
                sum += amounts[i];
            }
            assertEq(sum, vm.parseJsonUint(json, ".allocatedAmount"));
            assertEq(sum + vm.parseJsonUint(json, ".undistributedDust"), vm.parseJsonUint(json, ".requestedAmount"));
        }
    }

    function test_fundAndClaimEveryBuilderOutput() public {
        for (uint256 k; k < FIXTURES.length; ++k) {
            (string memory json, address[] memory accounts, uint256[] memory amounts) = _load(k);
            for (uint256 i; i < accounts.length; ++i) {
                if (!share.canReceive(accounts[i])) _onboard(accounts[i], keccak256(abi.encode(accounts[i])), FR);
            }
            uint256 allocated = vm.parseJsonUint(json, ".allocatedAmount");
            _fund(fundAdmin, allocated);
            vm.startPrank(fundAdmin);
            usdc.approve(address(distributor), allocated);
            uint256 id = distributor.createDistribution(
                vm.parseJsonBytes32(json, ".root"), allocated, uint64(vm.parseJsonUint(json, ".recordDate"))
            );
            vm.stopPrank();

            for (uint256 i; i < accounts.length; ++i) {
                uint256 before = usdc.balanceOf(accounts[i]);
                distributor.claim(id, accounts[i], amounts[i], _proof(json, i));
                assertEq(usdc.balanceOf(accounts[i]), before + amounts[i]);
            }
            assertEq(usdc.balanceOf(address(distributor)), 0, "exactly the allocated amount is paid out");
            assertEq(distributor.outstandingLiability(), 0);
        }
    }

    /// @dev The Solidity port itself, for any tree size: every proof it produces verifies with OpenZeppelin's
    ///      `MerkleProof` against its root, and no proof verifies a leaf with a changed amount.
    function testFuzz_portProofsVerifyForAnyTreeSize(uint256 n, uint256 seed) public pure {
        n = bound(n, 1, 33);
        address[] memory accounts = new address[](n);
        uint256[] memory amounts = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            accounts[i] = address(uint160(uint256(keccak256(abi.encode(seed, "account", i)))));
            amounts[i] = uint256(keccak256(abi.encode(seed, "amount", i))) % 1e15;
        }
        (bytes32[] memory tree, uint256[] memory treeIndex) = StandardMerkleTree.build(accounts, amounts);
        for (uint256 i; i < n; ++i) {
            bytes32[] memory proof = StandardMerkleTree.proof(tree, treeIndex[i]);
            assertTrue(MerkleProof.verify(proof, tree[0], StandardMerkleTree.leafHash(accounts[i], amounts[i])));
            assertFalse(MerkleProof.verify(proof, tree[0], StandardMerkleTree.leafHash(accounts[i], amounts[i] + 1)));
        }
    }
}
