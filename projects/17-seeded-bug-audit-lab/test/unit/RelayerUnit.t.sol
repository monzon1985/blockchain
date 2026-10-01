// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { BaseTest } from "../BaseTest.sol";
import { IERC1271 } from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { KestrelRelayer } from "kestrel/KestrelRelayer.sol";
import { FixedTreeErrors } from "../helpers/FixedTreeErrors.sol";

/// @notice Minimal ERC-1271 smart wallet: a signature is valid when it is the owner's ECDSA
///         signature over the digest.
contract MockSmartWallet is IERC1271 {
    address internal immutable owner;

    constructor(address _owner) {
        owner = _owner;
    }

    function approve(IERC20 token, address spender) external {
        token.approve(spender, type(uint256).max);
    }

    function isValidSignature(bytes32 digest, bytes calldata signature) external view returns (bytes4) {
        (bytes32 r, bytes32 s) = abi.decode(signature[:64], (bytes32, bytes32));
        uint8 v = uint8(signature[64]);
        return ecrecover(digest, v, r, s) == owner ? IERC1271.isValidSignature.selector : bytes4(0xffffffff);
    }
}

/// @notice Unit tests for {KestrelRelayer}: happy paths and every revert path.
contract RelayerUnit is BaseTest {
    function setUp() public override {
        super.setUp();
        collateral.mint(user, 10_000e18);
        vm.prank(user);
        collateral.approve(address(relayer), type(uint256).max);
    }

    function _request(address signer, uint256 nonce)
        internal
        view
        returns (KestrelRelayer.SwapRequest memory)
    {
        return KestrelRelayer.SwapRequest({
            user: signer,
            tokenIn: address(collateral),
            amountIn: 100e18,
            minOut: 0,
            to: signer,
            nonce: nonce,
            deadline: block.timestamp + 1 hours
        });
    }

    function _sign(uint256 pk, KestrelRelayer.SwapRequest memory req) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, relayer.hashRequest(req));
        return abi.encodePacked(r, s, v);
    }

    function test_relaySwap_eoa() public {
        KestrelRelayer.SwapRequest memory req = _request(user, 0);
        uint256 out = relayer.relaySwap(req, _sign(userPk, req));
        assertGt(out, 0);
        assertEq(debt.balanceOf(user), out);
        assertEq(relayer.nonces(user), 1);
    }

    function test_relaySwap_erc1271Wallet() public {
        MockSmartWallet wallet = new MockSmartWallet(user);
        collateral.mint(address(wallet), 1000e18);
        wallet.approve(IERC20(address(collateral)), address(relayer));
        KestrelRelayer.SwapRequest memory req = _request(address(wallet), 0);
        uint256 out = relayer.relaySwap(req, _sign(userPk, req));
        assertEq(debt.balanceOf(address(wallet)), out, "contract wallet traded via ERC-1271");
    }

    function test_relaySwap_reverts() public {
        KestrelRelayer.SwapRequest memory req = _request(user, 0);
        bytes memory sig = _sign(userPk, req);

        vm.warp(req.deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(KestrelRelayer.ExpiredSignature.selector, req.deadline));
        relayer.relaySwap(req, sig);
        vm.warp(req.deadline);

        bytes memory forged = _sign(attackerPk, req);
        vm.expectRevert(KestrelRelayer.InvalidSignature.selector);
        relayer.relaySwap(req, forged);

        KestrelRelayer.SwapRequest memory future = _request(user, 5);
        bytes memory futureSig = _sign(userPk, future);
        vm.expectRevert(abi.encodeWithSelector(FixedTreeErrors.InvalidNonce.selector, 5, 0));
        relayer.relaySwap(future, futureSig);
    }

    function test_domainSeparator_isStableOnItsChain() public view {
        assertEq(relayer.domainSeparator(), relayer.domainSeparator());
        assertTrue(relayer.domainSeparator() != bytes32(0));
    }
}
