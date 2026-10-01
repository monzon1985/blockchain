// SPDX-License-Identifier: MIT
pragma circom 2.2.3;

include "poseidon.circom";
include "comparators.circom";
include "mux1.circom";
include "eddsaposeidon.circom";
include "../lib/credential_lib.circom";

/*
 * ZOO BUG #2 - Missing Num2Bits range check on `birthdate` (field wrap).
 *
 * OWASP SC Top 10 (2026): SC09 Integer Overflow and Underflow (here: modular
 * wrap-around in the BN254 scalar field), enabled by SC05 Lack of Input
 * Validation (the missing range constraint).
 *
 * The production `AgeAtLeast18` range-checks `birthdate` with `Num2Bits(32)`
 * BEFORE feeding it into the `<=` comparator, guaranteeing the comparator
 * operates on a genuine < 2^32 integer. This flawed variant drops that guard:
 *
 *     // BUG: no `Num2Bits(32)` on birthdate
 *     le.in[0] <== birthdate + 180000;
 *     le.in[1] <== currentDate;
 *     le.out === 1;
 *
 * `LessEqThan(32)` only range-checks the *difference*, not `birthdate` itself.
 * A credential whose `birthdate` field is a large element `W = r - 180000 + X`
 * wraps modulo the field so that `birthdate + 180000 = X` (a small value) and
 * the comparator reports "adult" even though `W` is not a date at all.
 *
 * PRECONDITION (stated honestly): `birthdate` is a SIGNED field, so this
 * forgery needs an issuer that signs a non-date value, i.e. a buggy or
 * malicious issuer. The circuit is the last line of defence against such an
 * issuer; the project's issuer CLI (src/cli/issuer.ts) refuses to sign a
 * birthdate that is not a valid YYYYMMDD date.
 *
 * The production circuit rejects `W` because `Num2Bits(32)` fails for it, so
 * the production witness generator aborts for this input while the forged
 * proof PASSES the flawed verifier (and registers at a gate wired to it).
 *
 * The fix is the production circuit's `AgeAtLeast18`.
 */
template AgeAtLeast18NoRangeCheck() {
    signal input birthdate;
    signal input currentDate;

    // Only currentDate is guarded here; birthdate is NOT range-checked (BUG).
    component cdBits = Num2Bits(32);
    cdBits.in <== currentDate;

    component le = LessEqThan(32);
    le.in[0] <== birthdate + 180000;
    le.in[1] <== currentDate;
    le.out === 1;
}

template CredentialGateAgeNoRangeCheck(issuerDepth, revDepth, nSanctioned) {
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

    // BUG: uses the age check without a birthdate range guard.
    component age = AgeAtLeast18NoRangeCheck();
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
    CredentialGateAgeNoRangeCheck(8, 20, 16);
