// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {
    ERC20PermitUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {
    ERC3009Upgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/draft-ERC3009Upgradeable.sol";

import {MockERC1271Wallet} from "../mocks/MockERC1271Wallet.sol";
import {StablecoinTestBase} from "../utils/StablecoinTestBase.sol";

/// @notice EIP-712 signature fuzzing across permit, both ERC-3009 flavours, cancellation and reserve attestations:
///         wrong domain (every field), expiry, replay, a chain id change after a fork, and ERC-1271 signers.
contract SignatureFuzzTest is StablecoinTestBase {
    uint256 internal constant SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    uint256 internal va;
    uint256 internal vb;

    function setUp() public override {
        super.setUp();
        va = block.timestamp - 1;
        vb = block.timestamp + 1 hours;
    }

    function _key(uint256 seed) internal pure returns (uint256) {
        return bound(seed, 1, SECP256K1_N - 1);
    }

    /// @dev A domain that differs from the real one in exactly one field, chosen by `which`.
    function _wrongDomain(uint8 which, uint256 salt) internal view returns (bytes32) {
        which = uint8(bound(which, 0, 3));
        if (which == 0) return _domainSeparatorFor(string(abi.encode(salt)), "1", block.chainid, address(token));
        if (which == 1) return _domainSeparatorFor("Test Payment Dollar", "2", block.chainid, address(token));
        if (which == 2) {
            uint256 otherChain = bound(salt, 0, type(uint64).max);
            if (otherChain == block.chainid) otherChain++;
            return _domainSeparatorFor("Test Payment Dollar", "1", otherChain, address(token));
        }
        address other = address(uint160(bound(salt, 1, type(uint160).max)));
        if (other == address(token)) other = address(uint160(other) ^ 1);
        return _domainSeparatorFor("Test Payment Dollar", "1", block.chainid, other);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Permit
    // ------------------------------------------------------------------------------------------------------------

    function testFuzz_permit_validSignatureFromAnyKey(uint256 keySeed, address spender, uint256 value, uint32 ttl)
        public
    {
        uint256 key = _key(keySeed);
        address owner = vm.addr(key);
        vm.assume(spender != address(0));
        uint256 deadline = block.timestamp + ttl;
        bytes memory sig = _signPermit(key, owner, spender, value, deadline);
        token.permit(owner, spender, value, deadline, sig);
        assertEq(token.allowance(owner, spender), value);
        assertEq(token.nonces(owner), 1);
        // Replay: the nonce moved on.
        vm.expectRevert(abi.encodeWithSelector(InvalidPermitSignature.selector, owner));
        token.permit(owner, spender, value, deadline, sig);
    }

    function testFuzz_permit_wrongDomainRejected(uint256 keySeed, uint8 which, uint256 salt, uint256 value) public {
        uint256 key = _key(keySeed);
        address owner = vm.addr(key);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig =
            _sign(key, _digest(_wrongDomain(which, salt), _permitStructHash(owner, bob, value, 0, deadline)));
        vm.expectRevert(abi.encodeWithSelector(InvalidPermitSignature.selector, owner));
        token.permit(owner, bob, value, deadline, sig);
        _expectVrsPermitRejected(owner, value, deadline, sig);
        assertEq(token.nonces(owner), 0);
    }

    function _expectVrsPermitRejected(address owner, uint256 value, uint256 deadline, bytes memory sig) internal {
        (uint8 v, bytes32 r, bytes32 s) = _split(sig);
        vm.expectPartialRevert(ERC20PermitUpgradeable.ERC2612InvalidSigner.selector);
        token.permit(owner, bob, value, deadline, v, r, s);
    }

    function testFuzz_permit_expiredRejected(uint256 deadline, uint256 elapsed) public {
        deadline = bound(deadline, 0, block.timestamp);
        elapsed = bound(elapsed, 1, 365 days);
        vm.warp(deadline + elapsed);
        bytes memory sig = _signPermit(aliceKey, alice, bob, 1, deadline);
        vm.expectRevert(abi.encodeWithSelector(ERC20PermitUpgradeable.ERC2612ExpiredSignature.selector, deadline));
        token.permit(alice, bob, 1, deadline, sig);
    }

    function testFuzz_permit_chainIdChangeAfterFork(uint64 newChainId) public {
        vm.assume(newChainId != block.chainid);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sigOldChain = _signPermit(aliceKey, alice, bob, 5, deadline);
        bytes32 domainOld = token.DOMAIN_SEPARATOR();

        vm.chainId(newChainId);
        assertTrue(token.DOMAIN_SEPARATOR() != domainOld, "domain separator rebuilt for the new chain id");
        assertEq(token.DOMAIN_SEPARATOR(), _domainSeparator());
        vm.expectRevert(abi.encodeWithSelector(InvalidPermitSignature.selector, alice));
        token.permit(alice, bob, 5, deadline, sigOldChain);

        // A signature made for the new chain works there.
        token.permit(alice, bob, 5, deadline, _signPermit(aliceKey, alice, bob, 5, deadline));
        assertEq(token.allowance(alice, bob), 5);
    }

    function testFuzz_permit_erc1271(uint256 ownerKeySeed, uint256 otherKeySeed, uint256 value) public {
        uint256 ownerKey = _key(ownerKeySeed);
        uint256 otherKey = _key(otherKeySeed);
        vm.assume(ownerKey != otherKey);
        MockERC1271Wallet w = new MockERC1271Wallet(vm.addr(ownerKey));
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory forged = _signPermit(otherKey, address(w), bob, value, deadline);
        vm.expectRevert(abi.encodeWithSelector(InvalidPermitSignature.selector, address(w)));
        token.permit(address(w), bob, value, deadline, forged);
        token.permit(address(w), bob, value, deadline, _signPermit(ownerKey, address(w), bob, value, deadline));
        assertEq(token.allowance(address(w), bob), value);
    }

    // ------------------------------------------------------------------------------------------------------------
    // ERC-3009
    // ------------------------------------------------------------------------------------------------------------

    function testFuzz_3009_validityWindow(uint256 validAfter, uint256 validBefore, uint256 nowTs, bytes32 nonce)
        public
    {
        _mint(alice, 100e6);
        nowTs = bound(nowTs, block.timestamp, block.timestamp + 365 days);
        validAfter = bound(validAfter, 0, nowTs + 30 days);
        validBefore = bound(validBefore, 0, nowTs + 30 days);
        bytes memory sig = _signTransferAuth(aliceKey, alice, bob, 1e6, validAfter, validBefore, nonce);
        vm.warp(nowTs);
        bool shouldPass = nowTs > validAfter && nowTs < validBefore;
        _transferExpectingWindow(validAfter, validBefore, nonce, sig, shouldPass);
        assertEq(token.balanceOf(bob), shouldPass ? 1e6 : 0);
    }

    function _transferExpectingWindow(
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes memory sig,
        bool shouldPass
    ) internal {
        if (!shouldPass) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    ERC3009Upgradeable.ERC3009InvalidAuthorizationTime.selector, validAfter, validBefore
                )
            );
        }
        token.transferWithAuthorization(alice, bob, 1e6, validAfter, validBefore, nonce, sig);
    }

    function testFuzz_3009_replayAndCancelWithRandomNonces(bytes32 nonceA, bytes32 nonceB, uint256 value) public {
        vm.assume(nonceA != nonceB);
        _mint(alice, 100e6);
        value = bound(value, 1, 50e6);
        bytes memory sigA = _signTransferAuth(aliceKey, alice, bob, value, va, vb, nonceA);
        bytes memory sigB = _signReceiveAuth(aliceKey, alice, bob, value, va, vb, nonceB);

        token.transferWithAuthorization(alice, bob, value, va, vb, nonceA, sigA);
        vm.expectRevert(abi.encodeWithSelector(ERC3009Upgradeable.ERC3009UsedAuthorization.selector, alice, nonceA));
        token.transferWithAuthorization(alice, bob, value, va, vb, nonceA, sigA);

        // Out-of-order use of random nonces is fine; cancelling B makes its signed payment unusable.
        token.cancelAuthorization(alice, nonceB, _signCancelAuth(aliceKey, alice, nonceB));
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ERC3009Upgradeable.ERC3009UsedAuthorization.selector, alice, nonceB));
        token.receiveWithAuthorization(alice, bob, value, va, vb, nonceB, sigB);
        assertEq(token.balanceOf(bob), value);
    }

    function testFuzz_3009_wrongDomainRejected(uint8 which, uint256 salt, bytes32 nonce, uint8 flavour) public {
        _mint(alice, 100e6);
        bytes32 domain = _wrongDomain(which, salt);
        flavour = uint8(bound(flavour, 0, 2));
        if (flavour == 0) _expectTransferRejected(domain, nonce);
        else if (flavour == 1) _expectReceiveRejected(domain, nonce);
        else _expectCancelRejected(domain, nonce);
        assertFalse(token.authorizationState(alice, nonce));
    }

    function _expectTransferRejected(bytes32 domain, bytes32 nonce) internal {
        bytes memory sig =
            _sign(aliceKey, _digest(domain, _authStructHash(TRANSFER_AUTH_TYPEHASH, alice, bob, 1, va, vb, nonce)));
        vm.expectRevert(ERC3009Upgradeable.ERC3009InvalidSignature.selector);
        token.transferWithAuthorization(alice, bob, 1, va, vb, nonce, sig);
    }

    function _expectReceiveRejected(bytes32 domain, bytes32 nonce) internal {
        bytes memory sig =
            _sign(aliceKey, _digest(domain, _authStructHash(RECEIVE_AUTH_TYPEHASH, alice, bob, 1, va, vb, nonce)));
        vm.prank(bob);
        vm.expectRevert(ERC3009Upgradeable.ERC3009InvalidSignature.selector);
        token.receiveWithAuthorization(alice, bob, 1, va, vb, nonce, sig);
    }

    function _expectCancelRejected(bytes32 domain, bytes32 nonce) internal {
        bytes memory sig = _sign(aliceKey, _digest(domain, keccak256(abi.encode(CANCEL_AUTH_TYPEHASH, alice, nonce))));
        vm.expectRevert(ERC3009Upgradeable.ERC3009InvalidSignature.selector);
        token.cancelAuthorization(alice, nonce, sig);
    }

    function testFuzz_3009_chainIdChangeAfterFork(uint64 newChainId, bytes32 nonce) public {
        vm.assume(newChainId != block.chainid);
        _mint(alice, 100e6);
        bytes memory sig = _signTransferAuth(aliceKey, alice, bob, 1e6, va, vb, nonce);
        vm.chainId(newChainId);
        vm.expectRevert(ERC3009Upgradeable.ERC3009InvalidSignature.selector);
        token.transferWithAuthorization(alice, bob, 1e6, va, vb, nonce, sig);
        _expectVrsTransferRejected(sig, nonce);
        // Re-signed for the new chain id, the same payment goes through.
        _transferAliceToBob(_signTransferAuth(aliceKey, alice, bob, 1e6, va, vb, nonce), nonce);
        assertEq(token.balanceOf(bob), 1e6);
    }

    /// @dev The (v, r, s) entry point recovers some other address, which is not `alice`.
    function _expectVrsTransferRejected(bytes memory sig, bytes32 nonce) internal {
        (uint8 v, bytes32 r, bytes32 s) = _split(sig);
        vm.expectRevert(ERC3009Upgradeable.ERC3009InvalidSignature.selector);
        token.transferWithAuthorization(alice, bob, 1e6, va, vb, nonce, v, r, s);
    }

    function _transferAliceToBob(bytes memory sig, bytes32 nonce) internal {
        token.transferWithAuthorization(alice, bob, 1e6, va, vb, nonce, sig);
    }

    function testFuzz_3009_erc1271Signer(uint256 ownerKeySeed, uint256 otherKeySeed, bytes32 nonce) public {
        uint256 ownerKey = _key(ownerKeySeed);
        uint256 otherKey = _key(otherKeySeed);
        vm.assume(ownerKey != otherKey);
        address w = address(new MockERC1271Wallet(vm.addr(ownerKey)));
        _mint(w, 10e6);
        bytes memory forged = _signTransferAuth(otherKey, w, bob, 1e6, va, vb, nonce);
        vm.expectRevert(ERC3009Upgradeable.ERC3009InvalidSignature.selector);
        token.transferWithAuthorization(w, bob, 1e6, va, vb, nonce, forged);
        bytes memory genuine = _signTransferAuth(ownerKey, w, bob, 1e6, va, vb, nonce);
        token.transferWithAuthorization(w, bob, 1e6, va, vb, nonce, genuine);
        assertEq(token.balanceOf(bob), 1e6);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Reserve attestations
    // ------------------------------------------------------------------------------------------------------------

    function testFuzz_attestation_wrongDomainRejected(uint8 which, uint256 salt, uint256 reserves) public {
        vm.warp(block.timestamp + 1);
        uint64 asOf = uint64(block.timestamp);
        bytes32 structHash = keccak256(abi.encode(ATTESTATION_TYPEHASH, reserves, asOf, REPORT_HASH));
        bytes memory sig = _sign(attestorKey, _digest(_wrongDomain(which, salt), structHash));
        vm.expectRevert(abi.encodeWithSelector(InvalidAttestationSignature.selector, attestor));
        token.submitReserveAttestation(reserves, asOf, REPORT_HASH, sig);
    }

    function testFuzz_attestation_chainIdChangeAfterFork(uint64 newChainId, uint256 reserves) public {
        vm.assume(newChainId != block.chainid);
        vm.warp(block.timestamp + 1);
        uint64 asOf = uint64(block.timestamp);
        bytes memory sig = _signAttestation(attestorKey, reserves, asOf, REPORT_HASH);
        vm.chainId(newChainId);
        vm.expectRevert(abi.encodeWithSelector(InvalidAttestationSignature.selector, attestor));
        token.submitReserveAttestation(reserves, asOf, REPORT_HASH, sig);
        token.submitReserveAttestation(
            reserves, asOf, REPORT_HASH, _signAttestation(attestorKey, reserves, asOf, REPORT_HASH)
        );
    }

    function testFuzz_attestation_replayRejected(uint256 reserves, uint32 later) public {
        vm.warp(block.timestamp + 1);
        uint64 asOf = uint64(block.timestamp);
        bytes memory sig = _signAttestation(attestorKey, reserves, asOf, REPORT_HASH);
        token.submitReserveAttestation(reserves, asOf, REPORT_HASH, sig);
        vm.warp(block.timestamp + bound(later, 0, 26 hours));
        vm.expectRevert(abi.encodeWithSelector(AttestationNotNewer.selector, asOf, asOf));
        token.submitReserveAttestation(reserves, asOf, REPORT_HASH, sig);
    }

    function testFuzz_attestation_gatesMint(uint256 reserves, uint256 preMinted, uint256 amount) public {
        preMinted = bound(preMinted, 0, MINTER_DAILY / 2);
        amount = bound(amount, 1, MINTER_DAILY / 2);
        if (preMinted > 0) _mint(alice, preMinted);
        reserves = bound(reserves, 0, 2 * uint256(MINTER_DAILY));
        _reattest(reserves);
        bool fits = preMinted + amount <= reserves;
        if (!fits) {
            vm.expectRevert(abi.encodeWithSelector(InsufficientAttestedReserves.selector, preMinted, amount, reserves));
        }
        vm.prank(minter);
        token.mint(bob, amount);
        assertLe(token.totalSupply(), reserves > preMinted ? reserves : preMinted);
    }
}
