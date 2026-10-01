// SPDX-License-Identifier: MIT
pragma circom 2.2.3;

include "poseidon.circom";
include "comparators.circom";
include "mux1.circom";
include "eddsaposeidon.circom";
include "../lib/credential_lib.circom";

/*
 * ZOO BUG #3 - Merkle path selector not constrained to a bit (issuer forgery).
 *
 * OWASP SC Top 10 (2026): SC05 Lack of Input Validation (a missing boolean
 * constraint on a private selector); the impact is an access-control bypass
 * (SC01 Access Control Vulnerabilities): the trusted-issuer allowlist is
 * skipped entirely.
 *
 * The production `MerkleInclusionProof` constrains every path selector:
 *
 *     pathIndices[i] * (pathIndices[i] - 1) === 0;
 *
 * This flawed copy drops that line. `MultiMux1` computes
 *
 *     out0 = (pe - h) * s + h
 *     out1 = (h - pe) * s + pe          (so out0 + out1 = h + pe)
 *
 * which is a *selector* only when s is 0 or 1. For any other s it is an affine
 * map the prover steers: to make level i hash an arbitrary pair (L, R) from a
 * node h, choose pe = L + R - h and s = (L - h) / (pe - h). Picking (L, R) as
 * the REAL leaf and sibling at the bottom of the trusted tree makes the
 * recomputed root equal the real issuerRoot, although the leaf being proven is
 * the attacker's own, self-generated issuer key.
 *
 * The attacker therefore needs NO trusted issuer at all: they sign their own
 * credential with any birthdate/country they like and obtain a proof that
 * verifies against the gate's genuine issuer root. This is a true forged
 * proof: the statement "signed by a trusted issuer" is false.
 *
 * The fix is the production `MerkleInclusionProof` (boolean selectors); the
 * production witness generator aborts on the same inputs (test/zoo.test.ts).
 */
template MerkleInclusionProofNonBooleanSelector(levels) {
    signal input leaf;
    signal input root;
    signal input pathElements[levels];
    signal input pathIndices[levels];

    signal hashes[levels + 1];
    hashes[0] <== leaf;

    component mux[levels];
    component hasher[levels];

    for (var i = 0; i < levels; i++) {
        // BUG: missing `pathIndices[i] * (pathIndices[i] - 1) === 0;`

        mux[i] = MultiMux1(2);
        mux[i].c[0][0] <== hashes[i];
        mux[i].c[0][1] <== pathElements[i];
        mux[i].c[1][0] <== pathElements[i];
        mux[i].c[1][1] <== hashes[i];
        mux[i].s <== pathIndices[i];

        hasher[i] = Poseidon(2);
        hasher[i].inputs[0] <== mux[i].out[0];
        hasher[i].inputs[1] <== mux[i].out[1];
        hashes[i + 1] <== hasher[i].out;
    }

    root === hashes[levels];
}

template CredentialGateMerkleSelector(issuerDepth, revDepth, nSanctioned) {
    signal output nullifier;

    signal input currentDate;
    signal input issuerRoot;
    signal input revocationRoot;
    signal input sanctioned[nSanctioned];
    signal input appScope;
    signal input recipient;

    signal input subjectSecret;
    signal input birthdate;
    signal input countryCode;
    signal input accredited;
    signal input expiry;
    signal input credentialId;

    signal input issuerAx;
    signal input issuerAy;
    signal input sigS;
    signal input sigR8x;
    signal input sigR8y;

    signal input issuerPathElements[issuerDepth];
    signal input issuerPathIndices[issuerDepth];

    signal input revSiblings[revDepth];
    signal input revOldKey;
    signal input revOldValue;
    signal input revIsOld0;

    component commit = Poseidon(1);
    commit.inputs[0] <== subjectSecret;

    component msg = CredentialMessageHash();
    msg.subjectCommitment <== commit.out;
    msg.birthdate <== birthdate;
    msg.countryCode <== countryCode;
    msg.accredited <== accredited;
    msg.expiry <== expiry;
    msg.credentialId <== credentialId;

    component sig = EdDSAPoseidonVerifier();
    sig.enabled <== 1;
    sig.Ax <== issuerAx;
    sig.Ay <== issuerAy;
    sig.S <== sigS;
    sig.R8x <== sigR8x;
    sig.R8y <== sigR8y;
    sig.M <== msg.out;

    component issuerLeaf = Poseidon(2);
    issuerLeaf.inputs[0] <== issuerAx;
    issuerLeaf.inputs[1] <== issuerAy;

    // BUG: the Merkle gadget does not constrain its path selectors to bits.
    component issuerProof = MerkleInclusionProofNonBooleanSelector(issuerDepth);
    issuerProof.leaf <== issuerLeaf.out;
    issuerProof.root <== issuerRoot;
    for (var i = 0; i < issuerDepth; i++) {
        issuerProof.pathElements[i] <== issuerPathElements[i];
        issuerProof.pathIndices[i] <== issuerPathIndices[i];
    }

    component age = AgeAtLeast18();
    age.birthdate <== birthdate;
    age.currentDate <== currentDate;

    component exp = NotExpired();
    exp.expiry <== expiry;
    exp.currentDate <== currentDate;

    component sanc = NotSanctioned(nSanctioned);
    sanc.countryCode <== countryCode;
    for (var i = 0; i < nSanctioned; i++) {
        sanc.sanctioned[i] <== sanctioned[i];
    }

    component rev = RevocationNonMembership(revDepth);
    rev.credentialId <== credentialId;
    rev.revocationRoot <== revocationRoot;
    for (var i = 0; i < revDepth; i++) {
        rev.siblings[i] <== revSiblings[i];
    }
    rev.oldKey <== revOldKey;
    rev.oldValue <== revOldValue;
    rev.isOld0 <== revIsOld0;

    component nf = NullifierHash();
    nf.subjectSecret <== subjectSecret;
    nf.appScope <== appScope;
    nullifier <== nf.out;

    signal recipientSquare;
    recipientSquare <== recipient * recipient;
}

component main {public [currentDate, issuerRoot, revocationRoot, sanctioned, appScope, recipient]} =
    CredentialGateMerkleSelector(8, 20, 16);
