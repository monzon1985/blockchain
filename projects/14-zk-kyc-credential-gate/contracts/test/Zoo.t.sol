// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {FixtureLoader} from "./base/FixtureLoader.sol";
import {ZkGate} from "../src/ZkGate.sol";
import {CredentialVerifier} from "generated/CredentialVerifier.sol";
import {CredentialVerifierPlonk} from "generated/CredentialVerifierPlonk.sol";
import {ZooNullifierUnconstrainedVerifier} from "generated/ZooNullifierUnconstrainedVerifier.sol";
import {ZooAgeNoRangeCheckVerifier} from "generated/ZooAgeNoRangeCheckVerifier.sol";
import {ZooMerkleSelectorVerifier} from "generated/ZooMerkleSelectorVerifier.sol";
import {ZooNullifierNoScopeVerifier} from "generated/ZooNullifierNoScopeVerifier.sol";

/// @title ZooTest
/// @notice On-chain demonstration that each zoo proof verifies against its own flawed verifier, and
///         the concrete impact when such a verifier is wired into an otherwise-correct ZkGate. The
///         proof that the PRODUCTION circuit rejects the same attacks lives in the circuit tests
///         (test/zoo.test.ts) and `npm run zoo`.
contract ZooTest is FixtureLoader {
    ZooNullifierUnconstrainedVerifier internal nullifierBug;
    ZooAgeNoRangeCheckVerifier internal ageBug;
    ZooMerkleSelectorVerifier internal merkleBug;
    ZooNullifierNoScopeVerifier internal scopeBug;
    CredentialVerifier internal production;
    CredentialVerifierPlonk internal plonkDummy;
    GateFixture internal g;

    function setUp() public {
        g = loadGate();
        useFixtureChain(g);
        nullifierBug = new ZooNullifierUnconstrainedVerifier();
        ageBug = new ZooAgeNoRangeCheckVerifier();
        merkleBug = new ZooMerkleSelectorVerifier();
        scopeBug = new ZooNullifierNoScopeVerifier();
        production = new CredentialVerifier();
        plonkDummy = new CredentialVerifierPlonk();
    }

    /// @dev A correctly configured gate whose Groth16 verifier is the given (flawed) one.
    function _gate(address where, address groth16Verifier) internal returns (ZkGate) {
        return deployGateAt(where, fixtureConfig(g, groth16Verifier, address(plonkDummy), address(this)));
    }

    function _register(ZkGate gate, Groth16Fixture memory f) internal {
        vm.prank(g.recipient);
        gate.registerWithGroth16(f.a, f.b, f.c, f.pub);
    }

    // ---- Bug #1: under-constrained nullifier -> forged proof verifies ----

    function test_Bug1_ForgedNullifierProofsVerify() public view {
        Groth16Fixture memory pa = loadGroth16Nested("zoo_nullifier.json", ".proofA");
        Groth16Fixture memory pb = loadGroth16Nested("zoo_nullifier.json", ".proofB");
        assertTrue(nullifierBug.verifyProof(pa.a, pa.b, pa.c, pa.pub), "honest proofA must verify");
        assertTrue(nullifierBug.verifyProof(pb.a, pb.b, pb.c, pb.pub), "forged proofB must verify");
        for (uint256 i = 1; i < pa.pub.length; i++) {
            assertEq(pa.pub[i], pb.pub[i], "same credential, scope and recipient");
        }
        assertTrue(pa.pub[0] != pb.pub[0], "forged nullifier must differ from honest");
    }

    function test_Bug1_EnablesDoubleRegistration() public {
        Groth16Fixture memory pa = loadGroth16Nested("zoo_nullifier.json", ".proofA");
        Groth16Fixture memory pb = loadGroth16Nested("zoo_nullifier.json", ".proofB");
        ZkGate gate = _gate(g.gateAddress, address(nullifierBug));
        // One credential registers TWICE, each time burning a distinct nullifier (Sybil).
        _register(gate, pa);
        _register(gate, pb);
        assertTrue(gate.isNullifierUsed(pa.pub[0]));
        assertTrue(gate.isNullifierUsed(pb.pub[0]));
        assertEq(gate.registrationCount(), 2);
    }

    // ---- Bug #2: missing range check -> wrapped birthdate verifies ----

    function test_Bug2_WrappedBirthdateVerifies() public view {
        Groth16Fixture memory f = loadGroth16("zoo_age.json");
        assertTrue(ageBug.verifyProof(f.a, f.b, f.c, f.pub), "wrapped-birthdate proof must verify");
        // Its public signals are exactly those of an honest proof: nothing on-chain can tell.
        Groth16Fixture memory honest = loadGroth16("valid_groth16.json");
        for (uint256 i = 0; i < f.pub.length; i++) {
            assertEq(f.pub[i], honest.pub[i]);
        }
    }

    function test_Bug2_WrappedBirthdateRegisters() public {
        Groth16Fixture memory f = loadGroth16("zoo_age.json");
        ZkGate gate = _gate(g.gateAddress, address(ageBug));
        _register(gate, f); // admits a credential whose birthdate is not a date at all
        assertTrue(gate.isRegistered(g.recipient));
    }

    // ---- Bug #3: non-boolean Merkle selector -> untrusted issuer passes ----

    function test_Bug3_UntrustedIssuerProofVerifiesAgainstRealRoot() public view {
        Groth16Fixture memory f = loadGroth16("zoo_merkle.json");
        assertTrue(merkleBug.verifyProof(f.a, f.b, f.c, f.pub), "forged issuer path must verify");
        assertEq(f.pub[2], g.issuerRoot, "it claims the REAL trusted issuer root");
    }

    function test_Bug3_UntrustedIssuerRegisters() public {
        Groth16Fixture memory f = loadGroth16("zoo_merkle.json");
        ZkGate gate = _gate(g.gateAddress, address(merkleBug));
        assertTrue(gate.isAcceptedIssuerRoot(f.pub[2]));
        _register(gate, f); // a self-issued credential passes the trusted-issuer check
        assertTrue(gate.isRegistered(g.recipient));
    }

    // ---- #4: nullifier not bound to scope -> same nullifier at two gates ----

    function test_Bug4_NullifierCollidesAcrossScopesAndEqualsCommitment() public view {
        Groth16Fixture memory pa = loadGroth16Nested("zoo_scope.json", ".proofA");
        Groth16Fixture memory pb = loadGroth16Nested("zoo_scope.json", ".proofB");
        assertTrue(scopeBug.verifyProof(pa.a, pa.b, pa.c, pa.pub));
        assertTrue(scopeBug.verifyProof(pb.a, pb.b, pb.c, pb.pub));
        assertTrue(pa.pub[20] != pb.pub[20], "scopes must differ");
        assertEq(pa.pub[0], pb.pub[0], "flawed nullifier collides across scopes");
        uint256 commitment = vm.parseJsonUint(_read("zoo_scope.json"), ".subjectCommitment");
        assertEq(pa.pub[0], commitment, "the nullifier IS the issuer-signed commitment");
    }

    function test_Bug4_LinksSubjectAcrossTwoGates() public {
        Groth16Fixture memory pa = loadGroth16Nested("zoo_scope.json", ".proofA");
        Groth16Fixture memory pb = loadGroth16Nested("zoo_scope.json", ".proofB");
        ZkGate gateA = _gate(g.gateAddress, address(scopeBug));
        ZkGate gateB = _gate(g.gateBAddress, address(scopeBug));
        assertEq(gateA.appScope(), pa.pub[20], "gateA scope");
        assertEq(gateB.appScope(), pb.pub[20], "gateB scope");
        // Each proof only works at its own gate (the scope check still holds)...
        vm.expectRevert(abi.encodeWithSelector(ZkGate.UnexpectedAppScope.selector, pa.pub[20], pb.pub[20]));
        _register(gateB, pa);
        // ...but the two HONEST registrations burn the SAME nullifier value at both gates.
        _register(gateA, pa);
        _register(gateB, pb);
        assertTrue(gateA.isNullifierUsed(pa.pub[0]));
        assertTrue(gateB.isNullifierUsed(pa.pub[0]));
    }

    // ---- The production key does not accept any zoo proof ----

    function test_ProductionVerifierRejectsZooProofs() public view {
        string[5] memory files =
            ["zoo_nullifier.json", "zoo_nullifier.json", "zoo_age.json", "zoo_merkle.json", "zoo_scope.json"];
        string[5] memory keys = [".proofA", ".proofB", "", "", ".proofA"];
        for (uint256 i = 0; i < files.length; i++) {
            Groth16Fixture memory f = loadGroth16Nested(files[i], keys[i]);
            assertFalse(production.verifyProof(f.a, f.b, f.c, f.pub), "production key must reject zoo proofs");
        }
    }
}
