// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {CumulativeMerkleDistributor} from "../../src/CumulativeMerkleDistributor.sol";
import {ICumulativeMerkleDistributor} from "../../src/interfaces/ICumulativeMerkleDistributor.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MerkleBuilder} from "./MerkleBuilder.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Shared fixture: a distributor with distinct owner / updater / guardian, two reward tokens and three EOAs.
abstract contract DistributorBase is Test {
    struct Allocation {
        address account;
        address token;
        uint256 cumulativeAmount;
    }

    uint256 internal constant START = 1_750_000_000;
    bytes32 internal constant MANIFEST = keccak256("manifest v1");

    CumulativeMerkleDistributor internal distributor;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;

    address internal owner = makeAddr("owner");
    address internal updater = makeAddr("updater");
    address internal guardian = makeAddr("guardian");
    address internal relayer = makeAddr("relayer");
    address internal stranger = makeAddr("stranger");

    address internal alice;
    uint256 internal aliceKey;
    address internal bob;
    uint256 internal bobKey;
    address internal carol;
    uint256 internal carolKey;

    function setUp() public virtual {
        vm.warp(START);
        (alice, aliceKey) = makeAddrAndKey("alice");
        (bob, bobKey) = makeAddrAndKey("bob");
        (carol, carolKey) = makeAddrAndKey("carol");
        tokenA = new MockERC20("Reward A", "RWA");
        tokenB = new MockERC20("Reward B", "RWB");
        distributor = new CumulativeMerkleDistributor(owner, updater, guardian);
    }

    // ------------------------------------------------------------------------------------------------ trees

    function _leaves(Allocation[] memory allocs) internal pure returns (bytes32[] memory leaves) {
        leaves = new bytes32[](allocs.length);
        for (uint256 i; i < allocs.length; ++i) {
            leaves[i] = MerkleBuilder.leaf(allocs[i].account, allocs[i].token, allocs[i].cumulativeAmount);
        }
    }

    function _tree(Allocation[] memory allocs) internal pure returns (bytes32[] memory) {
        return MerkleBuilder.build(_leaves(allocs));
    }

    function _proof(bytes32[] memory tree, uint256 leafCount, uint256 leafIndex)
        internal
        pure
        returns (bytes32[] memory)
    {
        return MerkleBuilder.proof(tree, MerkleBuilder.treeIndexOf(leafCount, leafIndex));
    }

    /// @notice The default three-account, two-token allocation used by most unit tests.
    function _allocs(uint256 a, uint256 b, uint256 c) internal view returns (Allocation[] memory allocs) {
        allocs = new Allocation[](4);
        allocs[0] = Allocation(alice, address(tokenA), a);
        allocs[1] = Allocation(bob, address(tokenA), b);
        allocs[2] = Allocation(carol, address(tokenB), c);
        allocs[3] = Allocation(alice, address(tokenB), c / 2 + 1);
    }

    // ------------------------------------------------------------------------------------------------ root lifecycle

    function _propose(bytes32 newRoot) internal {
        vm.prank(updater);
        distributor.proposeRoot(newRoot, MANIFEST);
    }

    function _proposeAndAccept(bytes32 newRoot) internal {
        _propose(newRoot);
        vm.warp(block.timestamp + distributor.ROOT_TIMELOCK());
        distributor.acceptRoot();
    }

    /// @notice Publishes a tree for `allocs` and funds the distributor with every token's full cumulative total.
    function _publish(Allocation[] memory allocs) internal returns (bytes32[] memory tree) {
        tree = _tree(allocs);
        _proposeAndAccept(tree[0]);
        address[] memory tokens = _distinctTokens(allocs);
        for (uint256 t; t < tokens.length; ++t) {
            uint256 funded = MockERC20(tokens[t]).balanceOf(address(distributor)) + _totalClaimed(allocs, tokens[t]);
            uint256 needed = _total(allocs, tokens[t]);
            if (needed > funded) MockERC20(tokens[t]).mint(address(distributor), needed - funded);
        }
    }

    function _distinctTokens(Allocation[] memory allocs) internal pure returns (address[] memory tokens) {
        tokens = new address[](allocs.length);
        uint256 n;
        for (uint256 i; i < allocs.length; ++i) {
            bool seen;
            for (uint256 j; j < n && !seen; ++j) {
                seen = tokens[j] == allocs[i].token;
            }
            if (!seen) tokens[n++] = allocs[i].token;
        }
        // Shrink to the number of distinct tokens. Memory-safe: lowers the length of an array allocated above.
        assembly ("memory-safe") {
            mstore(tokens, n)
        }
    }

    function _total(Allocation[] memory allocs, address token) internal pure returns (uint256 sum) {
        for (uint256 i; i < allocs.length; ++i) {
            if (allocs[i].token == token) sum += allocs[i].cumulativeAmount;
        }
    }

    function _totalClaimed(Allocation[] memory allocs, address token) internal view returns (uint256 sum) {
        for (uint256 i; i < allocs.length; ++i) {
            if (allocs[i].token == token) sum += distributor.claimed(allocs[i].account, token);
        }
    }

    // ------------------------------------------------------------------------------------------------ signatures

    function _sign(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function _authorization(
        uint256 key,
        address account,
        address token,
        uint256 cumulativeAmount,
        address recipient,
        uint256 deadline
    ) internal view returns (bytes memory) {
        bytes32 digest = distributor.hashClaimAuthorization(
            account, token, cumulativeAmount, recipient, distributor.nonces(account), deadline
        );
        return _sign(key, digest);
    }

    /// @notice Independent EIP-712 digest, computed from the spec rather than through the contract.
    function _expectedDigest(
        address verifyingContract,
        address account,
        address token,
        uint256 cumulativeAmount,
        address recipient,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes32) {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("CumulativeMerkleDistributor"),
                keccak256("1"),
                block.chainid,
                verifyingContract
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "ClaimAuthorization(address account,address token,uint256 cumulativeAmount,address recipient,uint256 nonce,uint256 deadline)"
                ),
                account,
                token,
                cumulativeAmount,
                recipient,
                nonce,
                deadline
            )
        );
        return keccak256(abi.encodePacked(hex"1901", domain, structHash));
    }

    function _claimLeaves(Allocation[] memory allocs)
        internal
        pure
        returns (ICumulativeMerkleDistributor.ClaimLeaf[] memory claims)
    {
        claims = new ICumulativeMerkleDistributor.ClaimLeaf[](allocs.length);
        for (uint256 i; i < allocs.length; ++i) {
            claims[i] =
                ICumulativeMerkleDistributor.ClaimLeaf(allocs[i].account, allocs[i].token, allocs[i].cumulativeAmount);
        }
    }
}
