// SPDX-License-Identifier: MIT
pragma circom 2.2.3;
include "smt/smtverifier.circom";

// circomlib's SMTVerifier configured exactly like RevocationNonMembership
// (exclusion mode, always enabled) but WITHOUT the project's boolean guard on
// `isOld0`. Test-only: it shows the gap that the guard closes.
template CircomlibSmtExclusion(depth) {
    signal input credentialId;
    signal input revocationRoot;
    signal input siblings[depth];
    signal input oldKey;
    signal input oldValue;
    signal input isOld0;

    component smt = SMTVerifier(depth);
    smt.enabled <== 1;
    smt.fnc <== 1;
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

component main = CircomlibSmtExclusion(20);
