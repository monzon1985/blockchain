// SPDX-License-Identifier: MIT
pragma circom 2.2.3;

include "poseidon.circom";
include "comparators.circom";
include "mux1.circom";
include "eddsaposeidon.circom";
include "../lib/credential_lib.circom";

/*
 * ZOO BUG #1 - Under-constrained nullifier (assigned with `<--`).
 *
 * OWASP SC Top 10 (2026): SC05 Lack of Input Validation. In ZK terms: an
 * under-constrained signal (a witness value no constraint pins down).
 *
 * This circuit is the production `CredentialGate` EXCEPT for one operator: the
 * nullifier output is assigned with the witness-only `<--` instead of the
 * constraining `<==`.
 *
 *     nullifier <-- nf.out;   // BUG: computes a hint, adds NO r1cs constraint
 *
 * Consequences:
 *   - The Poseidon sub-circuit still computes `nf.out` and is constrained, but
 *     nothing binds the *output* signal `nullifier` to it. A prover is free to
 *     put ANY value in the nullifier slot of the witness and the proof still
 *     verifies.
 *   - On-chain, the scoped-nullifier replay guard is defeated: one credential
 *     can register unlimited times, each with a fresh forged nullifier (Sybil).
 *
 * Witness layout: NOT identical to production. In production the linear
 * constraint `nullifier <== nf.out` lets the compiler merge the two signals
 * into one wire; here `<--` keeps `nullifier` as a separate, free wire, so
 * this r1cs has exactly ONE more wire than production (`npm run zoo` asserts
 * the counts). The `wtns check` differential in scripts/zoo.ts therefore never
 * checks a witness against an r1cs of a different layout: it applies the SAME
 * patch (witness index 1 = the nullifier output, which both layouts share) to
 * each circuit's OWN honest witness, and shows the patched witness passes the
 * flawed r1cs but fails the production r1cs, while both unpatched witnesses
 * pass (control).
 *
 * The fix is the production circuit: `nullifier <== nf.out;`.
 */
template CredentialGateNullifierUnconstrained(issuerDepth, revDepth, nSanctioned) {
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

    component issuerProof = MerkleInclusionProof(issuerDepth);
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

    // BUG: witness-only assignment. `nullifier` is never constrained to `nf.out`.
    nullifier <-- nf.out;

    signal recipientSquare;
    recipientSquare <== recipient * recipient;
}

component main {public [currentDate, issuerRoot, revocationRoot, sanctioned, appScope, recipient]} =
    CredentialGateNullifierUnconstrained(8, 20, 16);
