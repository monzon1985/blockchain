// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC3009, IERC3009Cancel} from "@openzeppelin/contracts/interfaces/draft-IERC3009.sol";
import {
    ERC20PermitUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {
    ERC3009Upgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/draft-ERC3009Upgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {StablecoinTestBase} from "../utils/StablecoinTestBase.sol";

/// @notice EIP-2612 permit and ERC-3009 authorizations, ECDSA and ERC-1271 flavours, with every revert path.
contract GaslessTest is StablecoinTestBase {
    uint256 internal validAfter;
    uint256 internal validBefore;

    function setUp() public override {
        super.setUp();
        _mint(alice, 1000e6);
        _mint(address(wallet), 1000e6);
        validAfter = block.timestamp - 1;
        validBefore = block.timestamp + 1 hours;
    }

    // ------------------------------------------------------------------------------------------------------------
    // EIP-2612 permit
    // ------------------------------------------------------------------------------------------------------------

    function test_permit_vrs() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _split(_signPermit(aliceKey, alice, bob, 50e6, deadline));
        vm.prank(relayer);
        token.permit(alice, bob, 50e6, deadline, v, r, s);
        assertEq(token.allowance(alice, bob), 50e6);
        assertEq(token.nonces(alice), 1);
        vm.prank(bob);
        token.transferFrom(alice, carol, 50e6);
        assertEq(token.balanceOf(carol), 50e6);
    }

    function test_permit_vrs_revertsOnReplayAndExpiry() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _split(_signPermit(aliceKey, alice, bob, 50e6, deadline));
        token.permit(alice, bob, 50e6, deadline, v, r, s);
        vm.expectPartialRevert(ERC20PermitUpgradeable.ERC2612InvalidSigner.selector);
        token.permit(alice, bob, 50e6, deadline, v, r, s);

        (v, r, s) = _split(_signPermit(aliceKey, alice, bob, 1, deadline));
        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(ERC20PermitUpgradeable.ERC2612ExpiredSignature.selector, deadline));
        token.permit(alice, bob, 1, deadline, v, r, s);
    }

    function test_permit_bytes_eoa() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signPermit(aliceKey, alice, bob, 70e6, deadline);
        token.permit(alice, bob, 70e6, deadline, sig);
        assertEq(token.allowance(alice, bob), 70e6);
        assertEq(token.nonces(alice), 1);
    }

    function test_permit_bytes_erc1271Wallet() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signPermit(walletOwnerKey, address(wallet), bob, 80e6, deadline);
        token.permit(address(wallet), bob, 80e6, deadline, sig);
        assertEq(token.allowance(address(wallet), bob), 80e6);
        vm.prank(bob);
        token.transferFrom(address(wallet), carol, 80e6);
        assertEq(token.balanceOf(carol), 80e6);
    }

    function test_permit_bytes_reverts() public {
        uint256 deadline = block.timestamp + 1 hours;
        // Signed by the wrong key.
        bytes memory bad = _signPermit(bobKey, alice, bob, 1, deadline);
        vm.expectRevert(abi.encodeWithSelector(InvalidPermitSignature.selector, alice));
        token.permit(alice, bob, 1, deadline, bad);
        // Expired.
        bytes memory sig = _signPermit(aliceKey, alice, bob, 1, deadline);
        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(ERC20PermitUpgradeable.ERC2612ExpiredSignature.selector, deadline));
        token.permit(alice, bob, 1, deadline, sig);
    }

    function test_permit_bytes_walletRevocation() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signPermit(walletOwnerKey, address(wallet), bob, 1, deadline);
        vm.prank(walletOwner);
        wallet.setRejectAll(true);
        vm.expectRevert(abi.encodeWithSelector(InvalidPermitSignature.selector, address(wallet)));
        token.permit(address(wallet), bob, 1, deadline, sig);
    }

    function test_permit_restrictedAndPaused() public {
        uint256 deadline = block.timestamp + 1 hours;
        vm.prank(blocklister);
        token.blocklist(bob);
        bytes memory sig = _signPermit(aliceKey, alice, bob, 1, deadline);
        vm.expectRevert(abi.encodeWithSelector(AccountBlocklisted.selector, bob));
        token.permit(alice, bob, 1, deadline, sig);

        vm.prank(compliance);
        token.freeze(alice, ORDER_REF);
        sig = _signPermit(aliceKey, alice, carol, 1, deadline);
        vm.expectRevert(abi.encodeWithSelector(AccountFrozen.selector, alice));
        token.permit(alice, carol, 1, deadline, sig);

        vm.prank(compliance);
        token.unfreeze(alice, ORDER_REF);
        vm.prank(pauser);
        token.pause();
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        token.permit(alice, carol, 1, deadline, sig);
    }

    // ------------------------------------------------------------------------------------------------------------
    // ERC-3009 transferWithAuthorization
    // ------------------------------------------------------------------------------------------------------------

    function test_transferWithAuthorization_vrs() public {
        bytes32 nonce = keccak256("n1");
        (uint8 v, bytes32 r, bytes32 s) =
            _split(_signTransferAuth(aliceKey, alice, bob, 30e6, validAfter, validBefore, nonce));
        vm.expectEmit(true, true, false, false);
        emit IERC3009.AuthorizationUsed(alice, nonce);
        vm.prank(relayer);
        token.transferWithAuthorization(alice, bob, 30e6, validAfter, validBefore, nonce, v, r, s);
        assertEq(token.balanceOf(bob), 30e6);
        assertTrue(token.authorizationState(alice, nonce));

        vm.expectRevert(abi.encodeWithSelector(ERC3009Upgradeable.ERC3009UsedAuthorization.selector, alice, nonce));
        token.transferWithAuthorization(alice, bob, 30e6, validAfter, validBefore, nonce, v, r, s);
    }

    function test_transferWithAuthorization_bytes_eoaAndWallet() public {
        bytes32 nonce = keccak256("n2");
        bytes memory sig = _signTransferAuth(aliceKey, alice, bob, 10e6, validAfter, validBefore, nonce);
        token.transferWithAuthorization(alice, bob, 10e6, validAfter, validBefore, nonce, sig);
        assertEq(token.balanceOf(bob), 10e6);

        sig = _signTransferAuth(walletOwnerKey, address(wallet), bob, 20e6, validAfter, validBefore, nonce);
        token.transferWithAuthorization(address(wallet), bob, 20e6, validAfter, validBefore, nonce, sig);
        assertEq(token.balanceOf(bob), 30e6);
        // Nonces are per authorizer: the same random nonce was fine for both.
        assertTrue(token.authorizationState(alice, nonce));
        assertTrue(token.authorizationState(address(wallet), nonce));
    }

    function test_transferWithAuthorization_timeWindow() public {
        bytes32 nonce = keccak256("n3");
        uint256 after_ = block.timestamp + 10;
        uint256 before_ = block.timestamp + 20;
        bytes memory sig = _signTransferAuth(aliceKey, alice, bob, 1, after_, before_, nonce);
        vm.expectRevert(
            abi.encodeWithSelector(ERC3009Upgradeable.ERC3009InvalidAuthorizationTime.selector, after_, before_)
        );
        token.transferWithAuthorization(alice, bob, 1, after_, before_, nonce, sig);
        vm.warp(before_);
        vm.expectRevert(
            abi.encodeWithSelector(ERC3009Upgradeable.ERC3009InvalidAuthorizationTime.selector, after_, before_)
        );
        token.transferWithAuthorization(alice, bob, 1, after_, before_, nonce, sig);
        vm.warp(before_ - 1);
        token.transferWithAuthorization(alice, bob, 1, after_, before_, nonce, sig);
    }

    function test_transferWithAuthorization_blockNumberWindow() public {
        // OpenZeppelin's dual clock: bit 47 set on both bounds selects block numbers.
        uint256 flag = 1 << 47;
        bytes32 nonce = keccak256("n4");
        uint256 after_ = flag | (block.number - 1);
        uint256 before_ = flag | (block.number + 5);
        bytes memory sig = _signTransferAuth(aliceKey, alice, bob, 1, after_, before_, nonce);
        token.transferWithAuthorization(alice, bob, 1, after_, before_, nonce, sig);
        assertEq(token.balanceOf(bob), 1);
    }

    function test_transferWithAuthorization_invalidSignature() public {
        bytes32 nonce = keccak256("n5");
        bytes memory sig = _signTransferAuth(bobKey, alice, bob, 1, validAfter, validBefore, nonce);
        vm.expectRevert(ERC3009Upgradeable.ERC3009InvalidSignature.selector);
        token.transferWithAuthorization(alice, bob, 1, validAfter, validBefore, nonce, sig);
        // Value tampering.
        sig = _signTransferAuth(aliceKey, alice, bob, 1, validAfter, validBefore, nonce);
        vm.expectRevert(ERC3009Upgradeable.ERC3009InvalidSignature.selector);
        token.transferWithAuthorization(alice, bob, 2, validAfter, validBefore, nonce, sig);
        // Signature of the receive flavour cannot be used for the transfer flavour.
        sig = _signReceiveAuth(aliceKey, alice, bob, 1, validAfter, validBefore, nonce);
        vm.expectRevert(ERC3009Upgradeable.ERC3009InvalidSignature.selector);
        token.transferWithAuthorization(alice, bob, 1, validAfter, validBefore, nonce, sig);
    }

    function test_transferWithAuthorization_restrictedAndPaused() public {
        bytes32 nonce = keccak256("n6");
        bytes memory sig = _signTransferAuth(aliceKey, alice, bob, 1, validAfter, validBefore, nonce);
        vm.prank(compliance);
        token.freeze(bob, ORDER_REF);
        vm.expectRevert(abi.encodeWithSelector(AccountFrozen.selector, bob));
        token.transferWithAuthorization(alice, bob, 1, validAfter, validBefore, nonce, sig);
        assertFalse(token.authorizationState(alice, nonce), "nonce not consumed by a reverted payment");

        vm.prank(compliance);
        token.unfreeze(bob, ORDER_REF);
        vm.prank(pauser);
        token.pause();
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        token.transferWithAuthorization(alice, bob, 1, validAfter, validBefore, nonce, sig);
    }

    // ------------------------------------------------------------------------------------------------------------
    // ERC-3009 receiveWithAuthorization
    // ------------------------------------------------------------------------------------------------------------

    function test_receiveWithAuthorization_vrsAndBytes() public {
        bytes32 nonce = keccak256("r1");
        (uint8 v, bytes32 r, bytes32 s) =
            _split(_signReceiveAuth(aliceKey, alice, bob, 5e6, validAfter, validBefore, nonce));
        vm.prank(bob);
        token.receiveWithAuthorization(alice, bob, 5e6, validAfter, validBefore, nonce, v, r, s);
        assertEq(token.balanceOf(bob), 5e6);

        bytes32 nonce2 = keccak256("r2");
        bytes memory sig = _signReceiveAuth(walletOwnerKey, address(wallet), bob, 6e6, validAfter, validBefore, nonce2);
        vm.prank(bob);
        token.receiveWithAuthorization(address(wallet), bob, 6e6, validAfter, validBefore, nonce2, sig);
        assertEq(token.balanceOf(bob), 11e6);
    }

    function test_receiveWithAuthorization_callerMustBePayee() public {
        bytes32 nonce = keccak256("r3");
        bytes memory sig = _signReceiveAuth(aliceKey, alice, bob, 5e6, validAfter, validBefore, nonce);
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, bob));
        token.receiveWithAuthorization(alice, bob, 5e6, validAfter, validBefore, nonce, sig);
        (uint8 v, bytes32 r, bytes32 s) = _split(sig);
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, bob));
        token.receiveWithAuthorization(alice, bob, 5e6, validAfter, validBefore, nonce, v, r, s);
    }

    function test_receiveWithAuthorization_invalidSignature() public {
        bytes32 nonce = keccak256("r4");
        bytes memory sig = _signTransferAuth(aliceKey, alice, bob, 5e6, validAfter, validBefore, nonce);
        vm.prank(bob);
        vm.expectRevert(ERC3009Upgradeable.ERC3009InvalidSignature.selector);
        token.receiveWithAuthorization(alice, bob, 5e6, validAfter, validBefore, nonce, sig);
    }

    function test_receiveWithAuthorization_restrictedPayee() public {
        bytes32 nonce = keccak256("r5");
        bytes memory sig = _signReceiveAuth(aliceKey, alice, bob, 5e6, validAfter, validBefore, nonce);
        vm.prank(blocklister);
        token.blocklist(bob);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(AccountBlocklisted.selector, bob));
        token.receiveWithAuthorization(alice, bob, 5e6, validAfter, validBefore, nonce, sig);
    }

    // ------------------------------------------------------------------------------------------------------------
    // ERC-3009 cancelAuthorization
    // ------------------------------------------------------------------------------------------------------------

    function test_cancelAuthorization_vrs() public {
        bytes32 nonce = keccak256("c1");
        bytes memory payment = _signTransferAuth(aliceKey, alice, bob, 1, validAfter, validBefore, nonce);
        (uint8 v, bytes32 r, bytes32 s) = _split(_signCancelAuth(aliceKey, alice, nonce));
        vm.expectEmit(true, true, false, false);
        emit IERC3009Cancel.AuthorizationCanceled(alice, nonce);
        token.cancelAuthorization(alice, nonce, v, r, s);
        assertTrue(token.authorizationState(alice, nonce));
        vm.expectRevert(abi.encodeWithSelector(ERC3009Upgradeable.ERC3009UsedAuthorization.selector, alice, nonce));
        token.transferWithAuthorization(alice, bob, 1, validAfter, validBefore, nonce, payment);
        vm.expectRevert(abi.encodeWithSelector(ERC3009Upgradeable.ERC3009UsedAuthorization.selector, alice, nonce));
        token.cancelAuthorization(alice, nonce, v, r, s);
    }

    function test_cancelAuthorization_bytes() public {
        bytes32 nonce = keccak256("c2");
        token.cancelAuthorization(address(wallet), nonce, _signCancelAuth(walletOwnerKey, address(wallet), nonce));
        assertTrue(token.authorizationState(address(wallet), nonce));
        bytes memory bad = _signCancelAuth(bobKey, alice, nonce);
        vm.expectRevert(ERC3009Upgradeable.ERC3009InvalidSignature.selector);
        token.cancelAuthorization(alice, nonce, bad);
    }

    function test_permitAndAuthorizationNoncesAreIndependent() public {
        bytes32 nonce = bytes32(0); // a "sequential looking" 3009 nonce does not interact with permit nonces
        bytes memory sig = _signTransferAuth(aliceKey, alice, bob, 1, validAfter, validBefore, nonce);
        token.transferWithAuthorization(alice, bob, 1, validAfter, validBefore, nonce, sig);
        assertEq(token.nonces(alice), 0);
        uint256 deadline = block.timestamp + 1;
        token.permit(alice, bob, 1, deadline, _signPermit(aliceKey, alice, bob, 1, deadline));
        assertEq(token.nonces(alice), 1);
    }
}
