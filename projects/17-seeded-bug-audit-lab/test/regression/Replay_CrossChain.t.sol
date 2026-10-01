// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { BaseTest } from "../BaseTest.sol";
import { KestrelRelayer } from "kestrel/KestrelRelayer.sol";
import { SignatureReplayer } from "../attacks/SignatureReplayer.sol";
import { FixedTreeErrors } from "../helpers/FixedTreeErrors.sol";

/// @notice REPLAY regression (fixed profile): the nonce is consumed and the domain binds the
///         chain id, so a captured signature cannot be replayed, and a fresh signature made on
///         one chain is invalid on another.
contract ReplayCrossChainRegression is BaseTest {
    uint256 internal constant AMOUNT_IN = 1000e18;
    uint256 internal constant CHAIN_B = 424_242;

    function setUp() public override {
        super.setUp();
        collateral.mint(user, 10_000e18);
        vm.prank(user);
        collateral.approve(address(relayer), type(uint256).max);
    }

    function _request(uint256 nonce) internal view returns (KestrelRelayer.SwapRequest memory req) {
        req = KestrelRelayer.SwapRequest({
            user: user,
            tokenIn: address(collateral),
            amountIn: AMOUNT_IN,
            minOut: 0,
            to: user,
            nonce: nonce,
            deadline: block.timestamp + 1 days
        });
    }

    function _sign(KestrelRelayer.SwapRequest memory req) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPk, relayer.hashRequest(req));
        return abi.encodePacked(r, s, v);
    }

    function test_regression_capturedSignatureCannotBeReplayed() public {
        KestrelRelayer.SwapRequest memory req = _request(0);
        bytes memory sig = _sign(req);
        relayer.relaySwap(req, sig);
        assertEq(relayer.nonces(user), 1, "nonce consumed");

        SignatureReplayer replayer = new SignatureReplayer(relayer);
        replayer.capture(req, sig);
        vm.expectRevert(abi.encodeWithSelector(FixedTreeErrors.InvalidNonce.selector, 0, 1));
        replayer.replay();
    }

    function test_regression_signatureDoesNotCrossChains() public {
        // Signed on chain A for the user's CURRENT nonce, so only the domain can reject it.
        KestrelRelayer.SwapRequest memory req = _request(relayer.nonces(user));
        bytes memory sig = _sign(req);
        bytes32 sepA = relayer.domainSeparator();

        vm.chainId(CHAIN_B);
        assertTrue(relayer.domainSeparator() != sepA, "domain separator binds the chain id");
        vm.expectRevert(KestrelRelayer.InvalidSignature.selector);
        relayer.relaySwap(req, sig);

        // Positive control: back on chain A the very same signature is valid.
        vm.chainId(31_337);
        relayer.relaySwap(req, sig);
        assertEq(relayer.nonces(user), 1, "relayed once, on its own chain");
    }
}
