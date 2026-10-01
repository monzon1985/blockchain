// SPDX-License-Identifier: MIT
pragma circom 2.2.3;

include "poseidon.circom";
include "eddsaposeidon.circom";
include "credential_lib.circom";

/*
 * CredentialGate — the production KYC statement.
 *
 * A prover convinces the verifier that they hold an EdDSA-Poseidon credential,
 * signed by an issuer in the trusted-issuer Merkle tree, that:
 *   - belongs to a subject at least 18 years old on `currentDate`,
 *   - from a non-sanctioned country,
 *   - that has not expired, and
 *   - whose credential id is NOT in the revocation sparse Merkle tree,
 * while revealing nothing but a scoped nullifier. The proof is additionally
 * bound to the address that will submit it (`recipient`), so a proof seen in
 * the mempool cannot be front-run by another sender.
 *
 * Public signals (order matters, it is the on-chain ABI):
 *   output nullifier
 *   input  currentDate
 *   input  issuerRoot
 *   input  revocationRoot
 *   input  sanctioned[nSanctioned]
 *   input  appScope
 *   input  recipient
 */
template CredentialGate(issuerDepth, revDepth, nSanctioned) {
    // ---- Public output ----
    signal output nullifier;

    // ---- Public inputs (declaration order == public-signal order) ----
    signal input currentDate;    // YYYYMMDD
    signal input issuerRoot;     // root of trusted-issuer Merkle tree
    signal input revocationRoot; // root of revoked-id sparse Merkle tree
    signal input sanctioned[nSanctioned];
    signal input appScope;       // keccak256(abi.encode(chainId, gate, actionId, epoch)) mod r
    signal input recipient;      // uint160(address) that will submit the proof

    // ---- Private witness ----
    signal input subjectSecret;
    signal input birthdate;      // YYYYMMDD
    signal input countryCode;    // ISO-3166 numeric
    signal input accredited;     // 0/1 flag, bound into the signature (not gated)
    signal input expiry;         // YYYYMMDD
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

    // 1. The subject secret opens the subject commitment that is part of the
    //    signed message. The issuer only ever sees Poseidon(subjectSecret), so
    //    it cannot compute the scoped nullifier. This ties the nullifier's
    //    secret to *this* credential: you cannot prove over a credential you
    //    cannot open.
    component commit = Poseidon(1);
    commit.inputs[0] <== subjectSecret;

    // 2. Message hash over all signed fields.
    component msg = CredentialMessageHash();
    msg.subjectCommitment <== commit.out;
    msg.birthdate <== birthdate;
    msg.countryCode <== countryCode;
    msg.accredited <== accredited;
    msg.expiry <== expiry;
    msg.credentialId <== credentialId;

    // 3. EdDSA-Poseidon signature verification (always enabled).
    component sig = EdDSAPoseidonVerifier();
    sig.enabled <== 1;
    sig.Ax <== issuerAx;
    sig.Ay <== issuerAy;
    sig.S <== sigS;
    sig.R8x <== sigR8x;
    sig.R8y <== sigR8y;
    sig.M <== msg.out;

    // 4. The issuer public key is in the trusted-issuer Merkle tree.
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

    // 5. Age >= 18 on currentDate.
    component age = AgeAtLeast18();
    age.birthdate <== birthdate;
    age.currentDate <== currentDate;

    // 6. Not expired.
    component exp = NotExpired();
    exp.expiry <== expiry;
    exp.currentDate <== currentDate;

    // 7. Country not sanctioned.
    component sanc = NotSanctioned(nSanctioned);
    sanc.countryCode <== countryCode;
    for (var i = 0; i < nSanctioned; i++) {
        sanc.sanctioned[i] <== sanctioned[i];
    }

    // 8. Credential id not revoked (SMT non-membership).
    component rev = RevocationNonMembership(revDepth);
    rev.credentialId <== credentialId;
    rev.revocationRoot <== revocationRoot;
    for (var i = 0; i < revDepth; i++) {
        rev.siblings[i] <== revSiblings[i];
    }
    rev.oldKey <== revOldKey;
    rev.oldValue <== revOldValue;
    rev.isOld0 <== revIsOld0;

    // 9. Scoped nullifier, fully constrained.
    component nf = NullifierHash();
    nf.subjectSecret <== subjectSecret;
    nf.appScope <== appScope;
    nullifier <== nf.out;

    // 10. Bind the submitter. `recipient` takes part in no other constraint,
    //     so give it a quadratic one (the Semaphore "signal hash square"
    //     pattern) to make the binding explicit instead of relying on the
    //     proving system's implicit public-input handling. ZkGate then
    //     requires recipient == uint160(msg.sender).
    signal recipientSquare;
    recipientSquare <== recipient * recipient;
}
