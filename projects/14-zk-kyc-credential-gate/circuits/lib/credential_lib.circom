// SPDX-License-Identifier: MIT
pragma circom 2.2.3;

include "poseidon.circom";
include "comparators.circom";
include "bitify.circom";
include "mux1.circom";
include "eddsaposeidon.circom";
include "smt/smtverifier.circom";

/*
 * credential_lib.circom
 *
 * Reusable, fully-constrained building blocks for the KYC credential gate.
 * Every template here is written to be *sound on its own*: each output is
 * bound to its inputs by rank-1 constraints, and every template that feeds a
 * value into a `LessThan`-family comparator range-checks that value with
 * `Num2Bits` itself, so a gadget stays safe when reused without the guards of
 * its current caller (field wrap-around cannot smuggle a malformed integer
 * past a `<` / `<=` gate).
 *
 * The flawed variants that deliberately break these properties live in
 * ../zoo/ and are documented there.
 */

/// @title CredentialMessageHash
/// @notice Poseidon hash of the six signed credential fields. This is the
///         message the issuer signs with EdDSA-Poseidon, so it binds every
///         field (including the subject commitment) into a single scalar.
/// @dev Field order is fixed and shared with the TypeScript issuer
///      (`messageHash` in src/lib/crypto.ts).
template CredentialMessageHash() {
    signal input subjectCommitment;
    signal input birthdate;
    signal input countryCode;
    signal input accredited;
    signal input expiry;
    signal input credentialId;
    signal output out;

    component h = Poseidon(6);
    h.inputs[0] <== subjectCommitment;
    h.inputs[1] <== birthdate;
    h.inputs[2] <== countryCode;
    h.inputs[3] <== accredited;
    h.inputs[4] <== expiry;
    h.inputs[5] <== credentialId;
    out <== h.out;
}

/// @title MerkleInclusionProof
/// @notice Verifies that `leaf` sits at the position described by `pathIndices`
///         under a depth-`levels` binary Poseidon Merkle tree with root `root`.
/// @dev Each path index bit selects whether the sibling is the left or right
///      child. `pathIndices[i]` is constrained to be boolean: with a
///      non-boolean selector `MultiMux1` becomes an affine map the prover can
///      steer to ANY pair of hash inputs, which forges membership of a key
///      that is not in the tree (zoo bug #3, circuits/zoo/merkle_selector_nonboolean.circom).
template MerkleInclusionProof(levels) {
    signal input leaf;
    signal input root;
    signal input pathElements[levels];
    signal input pathIndices[levels];

    signal hashes[levels + 1];
    hashes[0] <== leaf;

    component mux[levels];
    component hasher[levels];

    for (var i = 0; i < levels; i++) {
        // pathIndices[i] must be a bit: 0 -> current node is left, 1 -> right.
        pathIndices[i] * (pathIndices[i] - 1) === 0;

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

/// @title AgeAtLeast18
/// @notice Enforces `birthdate + 180000 <= currentDate` on YYYYMMDD integers,
///         which is exactly "the subject is at least 18 years old on
///         currentDate" (adding 180000 to a YYYYMMDD value adds 18 years).
/// @dev Both operands are range-checked to 32 bits *before* the comparison.
///      This is the constraint the age zoo bug removes: without the Num2Bits
///      guard a field-wrapped birthdate can make the comparator lie.
template AgeAtLeast18() {
    signal input birthdate;
    signal input currentDate;

    // Range guards: reject any birthdate/currentDate that is not a genuine
    // < 2^32 integer. YYYYMMDD values (max 99991231 ~ 1e8) fit comfortably.
    component bdBits = Num2Bits(32);
    bdBits.in <== birthdate;
    component cdBits = Num2Bits(32);
    cdBits.in <== currentDate;

    component le = LessEqThan(32);
    le.in[0] <== birthdate + 180000;
    le.in[1] <== currentDate;
    le.out === 1;
}

/// @title NotExpired
/// @notice Enforces `expiry > currentDate`, i.e. the credential has not lapsed.
/// @dev BOTH operands are range-checked to 32 bits so the strict comparator is
///      sound. The production circuit also range-checks `currentDate` inside
///      `AgeAtLeast18`, but this gadget does not rely on that: without its own
///      guard a field-wrapped `currentDate` (e.g. r - 1) would satisfy
///      `GreaterThan(32)` for a genuine expiry (regression-tested in
///      test/subcircuits.test.ts).
template NotExpired() {
    signal input expiry;
    signal input currentDate;

    component expBits = Num2Bits(32);
    expBits.in <== expiry;
    component cdBits = Num2Bits(32);
    cdBits.in <== currentDate;

    component gt = GreaterThan(32);
    gt.in[0] <== expiry;
    gt.in[1] <== currentDate;
    gt.out === 1;
}

/// @title NotSanctioned
/// @notice Enforces that `countryCode` is not equal to any of the `n` public
///         sanctioned ISO-3166 numeric codes.
/// @dev Sums the equality flags and constrains the sum to zero. countryCode is
///      range-checked so the equality gadget operates on a well-formed value.
template NotSanctioned(n) {
    signal input countryCode;
    signal input sanctioned[n];

    component ccBits = Num2Bits(32);
    ccBits.in <== countryCode;

    component eq[n];
    signal partial[n + 1];
    partial[0] <== 0;
    for (var i = 0; i < n; i++) {
        eq[i] = IsEqual();
        eq[i].in[0] <== countryCode;
        eq[i].in[1] <== sanctioned[i];
        partial[i + 1] <== partial[i] + eq[i].out;
    }
    // No sanctioned code matched.
    partial[n] === 0;
}

/// @title NullifierHash
/// @notice Scoped nullifier `Poseidon(subjectSecret, appScope)`.
/// @dev Binding the app scope is what makes the nullifier per-application and
///      unlinkable across gates. Zoo entry #4 (nullifier_no_scope.circom) drops
///      `appScope`, which makes the nullifier equal the issuer-signed
///      subject commitment.
template NullifierHash() {
    signal input subjectSecret;
    signal input appScope;
    signal output out;

    component h = Poseidon(2);
    h.inputs[0] <== subjectSecret;
    h.inputs[1] <== appScope;
    out <== h.out;
}

/// @title RevocationNonMembership
/// @notice Proves `credentialId` is NOT a member of the sparse Merkle tree of
///         revoked credential ids whose root is `revocationRoot`.
/// @dev Wrapper over circomlib's SMTVerifier in exclusion mode (fnc = 1),
///      always enabled. The depth is fixed by the caller.
///      circomlib's SMTVerifier never constrains `isOld0` to be a bit. At the
///      insertion level it computes `node = (1 - isOld0) * H(oldKey, oldValue, 1)`,
///      so with a non-boolean `isOld0` a prover can set that node to ANY value,
///      e.g. the real leaf of a REVOKED id, and "prove" non-membership against
///      the current revocation root (regression-tested in
///      test/credential.test.ts). The boolean constraint below closes that.
template RevocationNonMembership(depth) {
    signal input credentialId;
    signal input revocationRoot;
    signal input siblings[depth];
    signal input oldKey;
    signal input oldValue;
    signal input isOld0;

    // isOld0 must be a bit (circomlib's SMTVerifier does not enforce this).
    isOld0 * (isOld0 - 1) === 0;

    component smt = SMTVerifier(depth);
    smt.enabled <== 1;
    smt.fnc <== 1; // 1 = verify non-inclusion
    smt.root <== revocationRoot;
    for (var i = 0; i < depth; i++) {
        smt.siblings[i] <== siblings[i];
    }
    smt.oldKey <== oldKey;
    smt.oldValue <== oldValue;
    smt.isOld0 <== isOld0;
    smt.key <== credentialId;
    smt.value <== 0;
}
