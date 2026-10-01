// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {TestUSD} from "../../src/token/TestUSD.sol";
import {Fixture} from "../utils/Fixture.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC3009} from "@openzeppelin/contracts/token/ERC20/extensions/draft-ERC3009.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

contract TestUSDTest is Fixture {
    bytes32 internal constant NONCE = bytes32(uint256(0xabcdef) << 64);

    function setUp() public override {
        super.setUp();
        _mint(payer, 100 * ONE);
    }

    function test_Metadata() public view {
        assertEq(token.name(), "TestUSD (local only)");
        assertEq(token.symbol(), "tUSD");
        assertEq(token.decimals(), 6);
        assertEq(token.owner(), deployer);
    }

    function test_RevertWhen_DeployedOffLocalChain() public {
        vm.chainId(1);
        vm.expectRevert(abi.encodeWithSelector(TestUSD.TestUSDNotLocalChain.selector, 1));
        new TestUSD(deployer);
    }

    function test_RevertWhen_MintByNonOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, payer));
        vm.prank(payer);
        token.mint(payer, 1);
    }

    function test_RevertWhen_MintAboveCap() public {
        uint256 cap = token.MAX_SUPPLY();
        uint256 supply = token.totalSupply();
        vm.expectRevert(abi.encodeWithSelector(TestUSD.TestUSDSupplyCapExceeded.selector, cap + 1, cap));
        vm.prank(deployer);
        token.mint(payer, cap - supply + 1);
    }

    function test_MintUpToCap() public {
        uint256 room = token.MAX_SUPPLY() - token.totalSupply();
        _mint(payee, room);
        assertEq(token.totalSupply(), token.MAX_SUPPLY());
    }

    function test_TransferWithAuthorization() public {
        bytes memory sig = _sign(
            payerKey, _authDigest(TRANSFER_WITH_AUTHORIZATION_TYPEHASH, payer, payee, ONE, T0 - 1, T0 + 60, NONCE)
        );
        vm.prank(relayer);
        token.transferWithAuthorization(payer, payee, ONE, T0 - 1, T0 + 60, NONCE, sig);
        assertEq(token.balanceOf(payee), ONE);
        assertTrue(token.authorizationState(payer, NONCE));
    }

    function test_RevertWhen_AuthorizationReplayed() public {
        bytes memory sig = _sign(
            payerKey, _authDigest(TRANSFER_WITH_AUTHORIZATION_TYPEHASH, payer, payee, ONE, T0 - 1, T0 + 60, NONCE)
        );
        token.transferWithAuthorization(payer, payee, ONE, T0 - 1, T0 + 60, NONCE, sig);
        vm.expectRevert(abi.encodeWithSelector(Nonces.InvalidAccountNonce.selector, payer, uint256(NONCE) + 1));
        token.transferWithAuthorization(payer, payee, ONE, T0 - 1, T0 + 60, NONCE, sig);
    }

    function test_RevertWhen_AuthorizationUsesReservedKeyZero() public {
        bytes32 nonce = bytes32(0);
        bytes memory sig = _sign(
            payerKey, _authDigest(TRANSFER_WITH_AUTHORIZATION_TYPEHASH, payer, payee, ONE, T0 - 1, T0 + 60, nonce)
        );
        vm.expectRevert(abi.encodeWithSelector(TestUSD.TestUSDReservedNonceKey.selector, nonce));
        token.transferWithAuthorization(payer, payee, ONE, T0 - 1, T0 + 60, nonce, sig);
    }

    function test_RevertWhen_AuthorizationSequenceNotZero() public {
        bytes32 nonce = bytes32((uint256(0xabcdef) << 64) | 7);
        bytes memory sig = _sign(
            payerKey, _authDigest(TRANSFER_WITH_AUTHORIZATION_TYPEHASH, payer, payee, ONE, T0 - 1, T0 + 60, nonce)
        );
        vm.expectRevert(abi.encodeWithSelector(Nonces.InvalidAccountNonce.selector, payer, uint256(NONCE)));
        token.transferWithAuthorization(payer, payee, ONE, T0 - 1, T0 + 60, nonce, sig);
    }

    function test_RevertWhen_AuthorizationExpiredOrEarly() public {
        bytes memory sig = _sign(
            payerKey, _authDigest(TRANSFER_WITH_AUTHORIZATION_TYPEHASH, payer, payee, ONE, T0 + 10, T0 + 60, NONCE)
        );
        vm.expectRevert(abi.encodeWithSelector(ERC3009.ERC3009InvalidAuthorizationTime.selector, T0 + 10, T0 + 60));
        token.transferWithAuthorization(payer, payee, ONE, T0 + 10, T0 + 60, NONCE, sig);

        vm.warp(T0 + 60);
        vm.expectRevert(abi.encodeWithSelector(ERC3009.ERC3009InvalidAuthorizationTime.selector, T0 + 10, T0 + 60));
        token.transferWithAuthorization(payer, payee, ONE, T0 + 10, T0 + 60, NONCE, sig);
    }

    function test_RevertWhen_AuthorizationFieldsTampered() public {
        bytes memory sig = _sign(
            payerKey, _authDigest(TRANSFER_WITH_AUTHORIZATION_TYPEHASH, payer, payee, ONE, T0 - 1, T0 + 60, NONCE)
        );
        vm.expectRevert(ERC3009.ERC3009InvalidSignature.selector);
        token.transferWithAuthorization(payer, payee, 2 * ONE, T0 - 1, T0 + 60, NONCE, sig);
        vm.expectRevert(ERC3009.ERC3009InvalidSignature.selector);
        token.transferWithAuthorization(payer, relayer, ONE, T0 - 1, T0 + 60, NONCE, sig);
    }

    function test_ReceiveWithAuthorization_OnlyByRecipient() public {
        bytes memory sig = _sign(
            payerKey, _authDigest(RECEIVE_WITH_AUTHORIZATION_TYPEHASH, payer, payee, ONE, T0 - 1, T0 + 60, NONCE)
        );
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, payee));
        vm.prank(relayer);
        token.receiveWithAuthorization(payer, payee, ONE, T0 - 1, T0 + 60, NONCE, sig);

        vm.prank(payee);
        token.receiveWithAuthorization(payer, payee, ONE, T0 - 1, T0 + 60, NONCE, sig);
        assertEq(token.balanceOf(payee), ONE);
    }

    function test_CancelAuthorization() public {
        bytes32 digest = MessageHashUtils.toTypedDataHash(
            token.DOMAIN_SEPARATOR(),
            keccak256(abi.encode(keccak256("CancelAuthorization(address authorizer,bytes32 nonce)"), payer, NONCE))
        );
        token.cancelAuthorization(payer, NONCE, _sign(payerKey, digest));
        assertTrue(token.authorizationState(payer, NONCE));
    }

    // ------------------------------------------------------------------ fuzz

    function _transferSig(address to, uint256 value, bytes32 nonce) internal view returns (bytes memory) {
        return
            _sign(payerKey, _authDigest(TRANSFER_WITH_AUTHORIZATION_TYPEHASH, payer, to, value, T0 - 1, T0 + 60, nonce));
    }

    function _cancelSig(bytes32 nonce) internal view returns (bytes memory) {
        return _sign(
            payerKey,
            MessageHashUtils.toTypedDataHash(
                token.DOMAIN_SEPARATOR(),
                keccak256(abi.encode(keccak256("CancelAuthorization(address authorizer,bytes32 nonce)"), payer, nonce))
            )
        );
    }

    /// @notice A nonce is a 192-bit key plus a 64-bit sequence: sequence 0 of any non-zero key authorizes exactly
    ///         once (then that key moves to sequence 1), any other sequence is refused, and the ERC-2612 permit
    ///         counter (key 0) never moves.
    function testFuzz_NonceKeyLayout(uint192 key, uint64 sequence, uint256 value) public {
        key = uint192(bound(key, 1, type(uint192).max));
        value = bound(value, 1, 100 * ONE);
        bytes32 nonce = bytes32((uint256(key) << 64) | sequence);
        bytes memory sig = _transferSig(payee, value, nonce);
        if (sequence != 0) {
            vm.expectRevert(abi.encodeWithSelector(Nonces.InvalidAccountNonce.selector, payer, uint256(key) << 64));
            token.transferWithAuthorization(payer, payee, value, T0 - 1, T0 + 60, nonce, sig);
            assertFalse(token.authorizationState(payer, nonce));
            return;
        }
        token.transferWithAuthorization(payer, payee, value, T0 - 1, T0 + 60, nonce, sig);
        assertEq(token.balanceOf(payee), value);
        assertTrue(token.authorizationState(payer, nonce));
        assertEq(token.nonces(payer, key), (uint256(key) << 64) | 1);
        assertEq(token.nonces(payer), 0, "permit counter untouched");
        vm.expectRevert(abi.encodeWithSelector(Nonces.InvalidAccountNonce.selector, payer, (uint256(key) << 64) | 1));
        token.transferWithAuthorization(payer, payee, value, T0 - 1, T0 + 60, nonce, sig);
    }

    /// @notice Key 0 aliases the permit counter, so every nonce on it is refused, whatever its sequence.
    function testFuzz_RevertWhen_ReservedKeyZero(uint64 sequence) public {
        bytes32 nonce = bytes32(uint256(sequence));
        bytes memory sig = _transferSig(payee, ONE, nonce);
        vm.expectRevert(abi.encodeWithSelector(TestUSD.TestUSDReservedNonceKey.selector, nonce));
        token.transferWithAuthorization(payer, payee, ONE, T0 - 1, T0 + 60, nonce, sig);
        bytes memory cancelSig = _cancelSig(nonce);
        vm.expectRevert(abi.encodeWithSelector(TestUSD.TestUSDReservedNonceKey.selector, nonce));
        token.cancelAuthorization(payer, nonce, cancelSig);
        assertEq(token.nonces(payer), 0);
    }

    /// @notice Minting succeeds exactly up to the supply cap and fails one unit above it.
    function testFuzz_SupplyCapBoundary(uint256 amount) public {
        uint256 cap = token.MAX_SUPPLY();
        uint256 room = cap - token.totalSupply();
        amount = bound(amount, 0, 2 * room);
        if (amount > room) {
            vm.expectRevert(
                abi.encodeWithSelector(TestUSD.TestUSDSupplyCapExceeded.selector, token.totalSupply() + amount, cap)
            );
        }
        vm.prank(deployer);
        token.mint(payee, amount);
        assertLe(token.totalSupply(), cap);
    }

    /// @notice A cancelled authorization can never be used afterwards, and moves nothing.
    function testFuzz_CancelledAuthorizationCannotBeUsed(uint192 key, uint256 value) public {
        key = uint192(bound(key, 1, type(uint192).max));
        value = bound(value, 1, 100 * ONE);
        bytes32 nonce = bytes32(uint256(key) << 64);
        bytes memory sig = _transferSig(payee, value, nonce);
        bytes memory cancelSig = _cancelSig(nonce);
        token.cancelAuthorization(payer, nonce, cancelSig);
        assertTrue(token.authorizationState(payer, nonce));
        vm.expectRevert(abi.encodeWithSelector(Nonces.InvalidAccountNonce.selector, payer, (uint256(key) << 64) | 1));
        vm.prank(relayer);
        token.transferWithAuthorization(payer, payee, value, T0 - 1, T0 + 60, nonce, sig);
        assertEq(token.balanceOf(payee), 0);
        assertEq(token.balanceOf(payer), 100 * ONE);
    }

    function test_PermitNonceIndependentFromAuthorizationKeys() public {
        bytes memory sig = _sign(
            payerKey, _authDigest(TRANSFER_WITH_AUTHORIZATION_TYPEHASH, payer, payee, ONE, T0 - 1, T0 + 60, NONCE)
        );
        token.transferWithAuthorization(payer, payee, ONE, T0 - 1, T0 + 60, NONCE, sig);
        assertEq(token.nonces(payer), 0, "permit nonce untouched by keyed authorization");

        bytes32 permitHash = MessageHashUtils.toTypedDataHash(
            token.DOMAIN_SEPARATOR(),
            keccak256(
                abi.encode(
                    keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                    payer,
                    relayer,
                    ONE,
                    0,
                    T0 + 60
                )
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(payerKey, permitHash);
        token.permit(payer, relayer, ONE, T0 + 60, v, r, s);
        assertEq(token.allowance(payer, relayer), ONE);
        assertEq(token.nonces(payer), 1);
    }
}
