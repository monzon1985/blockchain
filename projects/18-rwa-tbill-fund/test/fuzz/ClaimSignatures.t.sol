// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IdentityRegistry} from "../../src/identity/IdentityRegistry.sol";
import {FundFixture} from "../utils/FundFixture.sol";

/// @notice Fuzzed EIP-712 claim handling: replay, expiry, wrong issuer, tampering, cross-chain / cross-domain.
contract ClaimSignaturesFuzzTest is FundFixture {
    uint256 internal constant SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    function _randomClaim(bytes32 identity, uint256 topicSeed, uint32 dataSeed, uint64 lifetime, uint256 nonce)
        internal
        view
        returns (IdentityRegistry.Claim memory c)
    {
        uint256 topic = bound(topicSeed, 1, 3);
        uint32 data = topic == 3 ? uint32(bound(dataSeed, 1, 999)) : dataSeed;
        c = IdentityRegistry.Claim({
            identity: identity == bytes32(0) ? bytes32(uint256(1)) : identity,
            topic: topic,
            data: data,
            issuer: issuer,
            issuedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp) + uint64(bound(lifetime, 1, 10 * 365 days)),
            nonce: nonce
        });
    }

    function testFuzz_validClaimAcceptedOnceAndExpiresExactly(
        bytes32 identity,
        uint256 topicSeed,
        uint32 dataSeed,
        uint64 lifetime,
        uint256 nonce
    ) public {
        vm.warp(block.timestamp + 1); // newer than any onboarding claim the fuzzer may target
        IdentityRegistry.Claim memory c = _randomClaim(identity, topicSeed, dataSeed, lifetime, nonce);
        bytes memory sig = _sign(c, issuerKey);
        bytes32 digest = registry.addClaim(c, sig);
        assertTrue(registry.isClaimValid(c.identity, c.topic));

        vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.ClaimAlreadyUsed.selector, digest));
        registry.addClaim(c, sig);

        vm.warp(c.expiresAt - 1);
        assertTrue(registry.isClaimValid(c.identity, c.topic));
        vm.warp(c.expiresAt);
        assertFalse(registry.isClaimValid(c.identity, c.topic));
    }

    function testFuzz_expiredOrNotYetValidClaimsRejected(uint64 issuedBack, uint64 expiresBack) public {
        IdentityRegistry.Claim memory c = _claim(keccak256("x"), 1, 1);
        c.issuedAt = uint64(block.timestamp - bound(issuedBack, 1, 30 days));
        c.expiresAt = uint64(block.timestamp - bound(expiresBack, 0, block.timestamp - c.issuedAt - 1));
        bytes memory sig = _sign(c, issuerKey);
        vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.ClaimExpired.selector, c.expiresAt, block.timestamp));
        registry.addClaim(c, sig);
    }

    function testFuzz_signatureFromAnyOtherKeyRejected(uint256 otherKey) public {
        otherKey = bound(otherKey, 1, SECP256K1_N - 1);
        vm.assume(otherKey != issuerKey);
        IdentityRegistry.Claim memory c = _claim(keccak256("x"), 1, 1);
        bytes memory sig = _sign(c, otherKey);
        vm.expectRevert(
            abi.encodeWithSelector(IdentityRegistry.InvalidClaimSignature.selector, issuer, registry.claimDigest(c))
        );
        registry.addClaim(c, sig);
    }

    function testFuzz_untrustedIssuerRejected(uint256 rogueKey, uint256 topicSeed) public {
        rogueKey = bound(rogueKey, 1, SECP256K1_N - 1);
        address rogue = vm.addr(rogueKey);
        vm.assume(rogue != issuer);
        IdentityRegistry.Claim memory c = _claim(keccak256("x"), bound(topicSeed, 1, 3), 1);
        c.issuer = rogue;
        bytes memory sig = _sign(c, rogueKey); // a perfectly valid signature, from the wrong party
        vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.UntrustedIssuer.selector, rogue, c.topic));
        registry.addClaim(c, sig);
    }

    function testFuzz_tamperedFieldRejected(uint8 field, uint256 value) public {
        IdentityRegistry.Claim memory c = _claim(keccak256("x"), 3, US);
        bytes memory sig = _sign(c, issuerKey);
        field = uint8(bound(field, 0, 3));
        if (field == 0) {
            bytes32 identity = bytes32(bound(value, 1, type(uint256).max));
            vm.assume(identity != c.identity);
            c.identity = identity;
        } else if (field == 1) {
            uint32 country = uint32(bound(value, 1, 999));
            vm.assume(country != c.data);
            c.data = country;
        } else if (field == 2) {
            uint64 expiresAt = uint64(bound(value, block.timestamp + 1, type(uint64).max));
            vm.assume(expiresAt != c.expiresAt);
            c.expiresAt = expiresAt;
        } else {
            vm.assume(value != c.nonce);
            c.nonce = value;
        }
        vm.expectRevert(
            abi.encodeWithSelector(IdentityRegistry.InvalidClaimSignature.selector, issuer, registry.claimDigest(c))
        );
        registry.addClaim(c, sig);
    }

    function testFuzz_crossChainReplayRejected(uint64 otherChain) public {
        vm.assume(otherChain != block.chainid && otherChain != 0);
        IdentityRegistry.Claim memory c = _claim(keccak256("x"), 1, 1);
        bytes memory sig = _sign(c, issuerKey);
        vm.chainId(otherChain);
        vm.expectRevert(
            abi.encodeWithSelector(IdentityRegistry.InvalidClaimSignature.selector, issuer, registry.claimDigest(c))
        );
        registry.addClaim(c, sig);
    }

    /// @dev A claim signed before a removal (but never submitted, unexpired and unrevoked) can never undo it.
    function testFuzz_removalIsNeverUndoneByAClaimIssuedBeforeIt(
        uint256 signedAfter,
        uint256 removedAfter,
        uint256 topicSeed
    ) public {
        bytes32 identity = keccak256("x");
        uint256 topic = bound(topicSeed, 1, 3);
        uint32 data = topic == 3 ? US : 1;
        IdentityRegistry.Claim memory first = _claim(identity, topic, data);
        registry.addClaim(first, _sign(first, issuerKey));
        vm.warp(block.timestamp + bound(signedAfter, 1, 300 days));
        IdentityRegistry.Claim memory unsubmitted = _claim(identity, topic, data); // valid for 365 days
        bytes memory sig = _sign(unsubmitted, issuerKey);
        vm.warp(block.timestamp + bound(removedAfter, 0, 300 days));
        vm.prank(complianceOfficer);
        registry.removeClaim(identity, topic);
        vm.expectRevert(
            abi.encodeWithSelector(
                IdentityRegistry.ClaimNotNewer.selector, unsubmitted.issuedAt, uint64(block.timestamp)
            )
        );
        registry.addClaim(unsubmitted, sig);
        assertFalse(registry.isClaimValid(identity, topic));
    }

    function testFuzz_olderClaimCannotOverwriteNewer(uint64 ageGap) public {
        bytes32 identity = keccak256("x");
        IdentityRegistry.Claim memory older = _claim(identity, 3, US);
        bytes memory olderSig = _sign(older, issuerKey);
        vm.warp(block.timestamp + bound(ageGap, 1, 300 days));
        IdentityRegistry.Claim memory newer = _claim(identity, 3, SG);
        registry.addClaim(newer, _sign(newer, issuerKey));
        vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.ClaimNotNewer.selector, older.issuedAt, newer.issuedAt));
        registry.addClaim(older, olderSig);
        assertEq(registry.investorCountry(identity), SG);
    }
}
