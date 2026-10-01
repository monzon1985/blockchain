// SPDX-License-Identifier: MIT
pragma circom 2.2.3;

include "poseidon.circom";
include "comparators.circom";
include "mux1.circom";
include "eddsaposeidon.circom";
include "../lib/credential_lib.circom";

/*
 * ZOO ENTRY #4 - Nullifier not bound to `appScope` (domain-separation flaw).
 *
 * OWASP SC Top 10 (2026): SC02 Business Logic Vulnerabilities. Unlike #1-#3
 * this circuit is NOT under-constrained: every signal is fully determined and
 * both demo proofs are honest. It proves the WRONG statement: the nullifier
 * omits the application scope.
 *
 *     nullifier <== Poseidon(subjectSecret);   // BUG: appScope ignored
 *
 * `appScope` is still a public input (the gate checks it), but it no longer
 * affects the nullifier. Consequences:
 *   - Issuer de-anonymisation. Poseidon(1)(subjectSecret) is EXACTLY the
 *     subjectCommitment the issuer signed, so nullifier == subjectCommitment:
 *     the issuer (and anyone who sees the credential) can map every on-chain
 *     registration straight back to the KYC'd identity. This is the worst
 *     impact and is asserted by `npm run zoo` and test/zoo.test.ts.
 *   - Cross-application linkage: the same subject produces the SAME
 *     nullifier at every gate, so two gates (or any observer of both) learn
 *     that one person used both; a federation that shares a nullifier set
 *     lets a registration at one gate block the subject at every other gate.
 *   - What it does NOT enable: replaying one proof at another gate. The
 *     gate's own appScope check rejects a proof made for a different scope,
 *     so the on-chain demo registers two HONEST proofs at two gates and shows
 *     they burn the same nullifier.
 *
 * The fix is the production circuit's `NullifierHash` (binds `appScope`).
 */
template NullifierNoScope() {
    signal input subjectSecret;
    signal output out;

    component h = Poseidon(1);
    h.inputs[0] <== subjectSecret;
    out <== h.out;
}

template CredentialGateNullifierNoScope(issuerDepth, revDepth, nSanctioned) {
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

    // `appScope` stays a public input (same ABI as production) but it is only
    // bound by this dummy quadratic constraint, never by the nullifier.
    signal appScopeSquare;
    appScopeSquare <== appScope * appScope;

    // BUG: nullifier ignores appScope entirely.
    component nf = NullifierNoScope();
    nf.subjectSecret <== subjectSecret;
    nullifier <== nf.out;

    signal recipientSquare;
    recipientSquare <== recipient * recipient;
}

component main {public [currentDate, issuerRoot, revocationRoot, sanctioned, appScope, recipient]} =
    CredentialGateNullifierNoScope(8, 20, 16);
