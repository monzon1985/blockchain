// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {SchnorrSecp256k1} from "../src/SchnorrSecp256k1.sol";
import {SchnorrTestBase, VerifierHarness} from "./utils/SchnorrTestBase.sol";

/// @notice Unit and fuzz tests of the ecrecover-based Schnorr verifier.
contract SchnorrSecp256k1Test is SchnorrTestBase {
    VerifierHarness internal harness;
    Key internal key;

    function setUp() public {
        harness = new VerifierHarness();
        key = makeKey(0xC0FFEE);
    }

    function _verify(Key memory k, bytes32 m, SchnorrSecp256k1.Signature memory s)
        internal
        view
        returns (bool)
    {
        return harness.verify(k.x, k.parity, m, s);
    }

    function test_validSignatureVerifies() public view {
        bytes32 m = keccak256("custody");
        assertTrue(_verify(key, m, schnorrSign(key, m)));
    }

    function test_challengeMatchesKnownAnswer() public view {
        // Same preimage as frost-keccak's `challenge_matches_cast_keccak_known_answer`:
        // 0x11..11 || 0x01 || Gx || 0x00..01.
        uint256 gx = 0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798;
        uint256 e = harness.challenge(
            address(0x1111111111111111111111111111111111111111), 1, gx, bytes32(uint256(1))
        );
        assertEq(e, 0xe4f56ad819f25681ea2ed3c41c82c84d86ed74641e4ee9bb4bbb7c2ff47f1a30);
    }

    function test_isValidKeyXBounds() public pure {
        assertFalse(SchnorrSecp256k1.isValidKeyX(0));
        assertTrue(SchnorrSecp256k1.isValidKeyX(1));
        assertTrue(SchnorrSecp256k1.isValidKeyX(Q - 1));
        assertFalse(SchnorrSecp256k1.isValidKeyX(Q));
        assertFalse(SchnorrSecp256k1.isValidKeyX(type(uint256).max));
    }

    function test_rejectsMalformedFields() public view {
        bytes32 m = keccak256("fields");
        SchnorrSecp256k1.Signature memory s = schnorrSign(key, m);
        assertFalse(
            harness.verify(key.x, key.parity, m, SchnorrSecp256k1.Signature(address(0), s.z))
        );
        assertFalse(harness.verify(key.x, key.parity, m, SchnorrSecp256k1.Signature(s.rAddr, 0)));
        assertFalse(harness.verify(key.x, key.parity, m, SchnorrSecp256k1.Signature(s.rAddr, Q)));
        assertFalse(
            harness.verify(
                key.x, key.parity, m, SchnorrSecp256k1.Signature(s.rAddr, type(uint256).max)
            )
        );
        assertFalse(harness.verify(0, key.parity, m, s));
        assertFalse(harness.verify(Q, key.parity, m, s));
        assertFalse(harness.verify(key.x, 2, m, s));
        assertFalse(harness.verify(key.x, key.parity ^ 1, m, s));
    }

    /// @dev An x-coordinate that is below Q but not on the curve makes ecrecover fail;
    ///      the verifier returns false instead of reverting.
    function test_offCurveKeyReturnsFalse() public view {
        bytes32 m = keccak256("off-curve");
        SchnorrSecp256k1.Signature memory s = schnorrSign(key, m);
        // x = 5: 5^3 + 7 = 132 is not a quadratic residue modulo p.
        assertFalse(harness.verify(5, 0, m, s));
    }

    function testFuzz_anyKeyAndMessageVerifies(uint256 sk, bytes32 m, uint256 salt) public {
        sk = bound(sk, 1, Q - 1);
        Key memory k = makeKey(sk);
        vm.assume(SchnorrSecp256k1.isValidKeyX(k.x)); // fails with probability ~2^-128
        assertTrue(_verify(k, m, schnorrSign(k, m, salt)));
    }

    function testFuzz_tamperedSignaturesAreRejected(
        uint256 sk,
        bytes32 m,
        bytes32 other,
        uint160 rDelta,
        uint256 zDelta
    ) public {
        sk = bound(sk, 1, Q - 1);
        rDelta = uint160(bound(rDelta, 1, type(uint160).max));
        zDelta = bound(zDelta, 1, Q - 1);
        Key memory k = makeKey(sk);
        vm.assume(SchnorrSecp256k1.isValidKeyX(k.x));
        SchnorrSecp256k1.Signature memory s = schnorrSign(k, m);

        // Wrong message.
        if (other != m) assertFalse(_verify(k, other, s));
        // Tampered address(R).
        assertFalse(
            _verify(k, m, SchnorrSecp256k1.Signature(address(uint160(s.rAddr) ^ rDelta), s.z))
        );
        // Tampered z (kept in range).
        assertFalse(_verify(k, m, SchnorrSecp256k1.Signature(s.rAddr, addmod(s.z, zDelta, Q))));
        // Negated key (same x, other parity).
        k.parity ^= 1;
        assertFalse(_verify(k, m, s));
    }

    function testFuzz_signatureDoesNotTransferBetweenKeys(uint256 sk1, uint256 sk2, bytes32 m)
        public
    {
        sk1 = bound(sk1, 1, Q - 1);
        sk2 = bound(sk2, 1, Q - 1);
        vm.assume(sk1 != sk2);
        Key memory k1 = makeKey(sk1);
        Key memory k2 = makeKey(sk2);
        vm.assume(SchnorrSecp256k1.isValidKeyX(k1.x) && SchnorrSecp256k1.isValidKeyX(k2.x));
        assertFalse(_verify(k2, m, schnorrSign(k1, m)));
    }

    function testFuzz_verifyNeverReverts(uint256 x, uint8 parity, bytes32 m, address r, uint256 z)
        public
        view
    {
        harness.verify(x, parity, m, SchnorrSecp256k1.Signature(r, z));
    }
}
