// SPDX-License-Identifier: MIT
//
// Adversarial audit of the bug zoo, at the circuit/constraint level. For
// each bug the FLAWED circuit accepts the malicious witness and the
// PRODUCTION circuit rejects the same attack, failing inside the template
// that carries the fix. End-to-end forged proofs live in scripts/zoo.ts and
// contracts/test/Zoo.t.sol.
import assert from "node:assert/strict";
import { loadProduction, expectWitnessFailure, expectConstraintViolation, asInput } from "./helpers.ts";
import {
  buildScenario,
  defaultCredentialFields,
  issueCredential,
  witnessFor,
  type Scenario,
} from "../src/lib/scenario.ts";
import { FIELD_MODULUS } from "../src/lib/field.ts";
import {
  ATTACKER_SUBJECT_SECRET,
  NULLIFIER_WITNESS_INDEX,
  WRAPPED_BIRTHDATE,
  attackerSelfSignedCredential,
  forgeNonBooleanSelectorPath,
} from "../src/lib/zoo_attacks.ts";
import { buildCredentialInput } from "../src/lib/inputs.ts";

describe("bug zoo: production rejects what flawed circuits accept", function () {
  let scenario: Scenario;
  before(async () => {
    scenario = await buildScenario();
  });

  it("#1 unconstrained nullifier: flawed accepts a patched nullifier, production does not", async () => {
    const cred = issueCredential(scenario, defaultCredentialFields(scenario.eddsa));
    const input = asInput(await witnessFor(scenario, cred, scenario.appScopeA));

    const prod = await loadProduction("credential");
    const wp = await prod.calculateWitness(input, true);
    await prod.checkConstraints(wp); // control: the honest witness is valid
    wp[NULLIFIER_WITNESS_INDEX] = ((wp[NULLIFIER_WITNESS_INDEX] as bigint) + 1n) % FIELD_MODULUS;
    await expectConstraintViolation(prod, wp);

    const flawed = await loadProduction("nullifier_unconstrained");
    const wf = await flawed.calculateWitness(input, true);
    await flawed.checkConstraints(wf); // control
    wf[NULLIFIER_WITNESS_INDEX] = ((wf[NULLIFIER_WITNESS_INDEX] as bigint) + 1n) % FIELD_MODULUS;
    await flawed.checkConstraints(wf); // BUG: passes with an arbitrary nullifier
  });

  it("#2 missing range check: flawed accepts a field-wrapped birthdate, production does not", async () => {
    // Needs an issuer that signs a non-date (the CLI's policy would refuse).
    const cred = issueCredential(
      scenario,
      defaultCredentialFields(scenario.eddsa, { birthdate: WRAPPED_BIRTHDATE, credentialId: 777000111n }),
      { emulateMaliciousIssuer: true },
    );
    const input = asInput(await witnessFor(scenario, cred, scenario.appScopeA));

    const flawed = await loadProduction("age_no_rangecheck");
    const wf = await flawed.calculateWitness(input, true);
    await flawed.checkConstraints(wf);

    const prod = await loadProduction("credential");
    const msg = await expectWitnessFailure(prod, input, "AgeAtLeast18");
    assert.match(msg, /Error in template Num2Bits/, "the birthdate range guard must be what fails");
  });

  it("#3 non-boolean Merkle selector: an UNTRUSTED issuer key passes the flawed tree check only", async () => {
    const { credential, attackerLeaf } = attackerSelfSignedCredential(
      scenario.eddsa,
      defaultCredentialFields(scenario.eddsa, { credentialId: 31337000n }, ATTACKER_SUBJECT_SECRET),
    );
    const honest = scenario.issuerTree.proof(scenario.issuerIndex);
    for (let i = 0; i <= scenario.issuerIndex; i++) {
      assert.notEqual(scenario.issuerTree.proof(i).leaf, attackerLeaf, "attacker key is not a trusted issuer");
    }
    const forged = forgeNonBooleanSelectorPath(honest, attackerLeaf);
    assert.ok(forged.selector > 1n, "the forgery needs a non-boolean selector");

    const input = asInput(
      buildCredentialInput({
        eddsa: scenario.eddsa,
        credential,
        subjectSecret: ATTACKER_SUBJECT_SECRET,
        issuerProof: { ...honest, leaf: attackerLeaf, ...forged },
        revocationProof: await scenario.revocationTree.nonMembership(credential.fields.credentialId),
        sanctioned: scenario.sanctioned,
        currentDate: scenario.currentDate,
        appScope: scenario.appScopeA,
        recipient: scenario.recipient,
      }),
    );
    assert.equal((input as { issuerRoot: bigint }).issuerRoot, honest.root, "claims the REAL trusted root");

    const flawed = await loadProduction("merkle_selector_nonboolean");
    const wf = await flawed.calculateWitness(input, true);
    await flawed.checkConstraints(wf);

    const prod = await loadProduction("credential");
    await expectWitnessFailure(prod, input, "MerkleInclusionProof");
  });

  it("#4 nullifier without scope: flawed nullifier == signed commitment and collides across apps", async () => {
    const cred = issueCredential(scenario, defaultCredentialFields(scenario.eddsa));
    const inA = asInput(await witnessFor(scenario, cred, scenario.appScopeA));
    const inB = asInput(await witnessFor(scenario, cred, scenario.appScopeB));

    const flawed = await loadProduction("nullifier_no_scope");
    const fa = await flawed.calculateWitness(inA, true);
    const fb = await flawed.calculateWitness(inB, true);
    assert.equal(fa[1], fb[1], "flawed nullifier collides across scopes");
    assert.equal(fa[1], cred.fields.subjectCommitment, "flawed nullifier IS the issuer-signed commitment");

    const prod = await loadProduction("credential");
    const pa = await prod.calculateWitness(inA, true);
    const pb = await prod.calculateWitness(inB, true);
    assert.notEqual(pa[1], pb[1], "production nullifier is scoped");
    assert.notEqual(pa[1], cred.fields.subjectCommitment, "production nullifier is not the commitment");
  });
});
