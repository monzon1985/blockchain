// SPDX-License-Identifier: MIT
pragma circom 2.2.3;

include "poseidon.circom";

/*
 * GAS BASELINE ONLY (not a credential statement, never deployed by ZkGate).
 *
 * A Groth16 verifier's on-chain cost is a fixed 4-pair pairing check plus one
 * ecMul + ecAdd per PUBLIC signal; it does not depend on the circuit's size.
 * This tiny circuit therefore reproduces exactly the verifier the credential
 * statement would have if the 16-entry sanctioned list were committed to ONE
 * field element instead of being 16 public inputs: 7 public signals
 * (nullifier, currentDate, issuerRoot, revocationRoot, sanctionedListHash,
 * appScope, recipient) instead of 22. GasBench measures both verifiers so the
 * README can quote the saving of that design alternative with a real number.
 */
template Baseline7PublicSignals() {
    signal input a[6];
    signal output out;

    component h = Poseidon(6);
    for (var i = 0; i < 6; i++) {
        h.inputs[i] <== a[i];
    }
    out <== h.out;
}

component main {public [a]} = Baseline7PublicSignals();
