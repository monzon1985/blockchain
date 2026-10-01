// SPDX-License-Identifier: MIT
import assert from "node:assert/strict";
import { loadProduction, expectWitnessFailure, asInput } from "./helpers.ts";
import {
  buildScenario,
  defaultCredentialFields,
  issueCredential,
  witnessFor,
  DEV_SUBJECT_SECRET,
  type Scenario,
} from "../src/lib/scenario.ts";
import { nullifier } from "../src/lib/crypto.ts";
import { buildCredentialInput } from "../src/lib/inputs.ts";
import { type NonMembershipProof } from "../src/lib/revocation.ts";
import { forgeRevokedExclusion } from "../src/lib/zoo_attacks.ts";

describe("credential circuit (production)", function () {
  let scenario: Scenario;

  before(async () => {
    scenario = await buildScenario();
  });

  function fields(overrides = {}) {
    return defaultCredentialFields(scenario.eddsa, overrides);
  }

  it("accepts a valid credential; public signals are [nullifier, date, roots, list, scope, recipient]", async () => {
    const circuit = await loadProduction("credential");
    const cred = issueCredential(scenario, fields());
    const input = await witnessFor(scenario, cred, scenario.appScopeA);
    const w = await circuit.calculateWitness(asInput(input), true);
    await circuit.checkConstraints(w);
    assert.equal(w[1], nullifier(scenario.eddsa, DEV_SUBJECT_SECRET, scenario.appScopeA));
    assert.equal(w[2], scenario.currentDate);
    assert.equal(w[3], input.issuerRoot);
    assert.equal(w[4], input.revocationRoot);
    assert.deepEqual(w.slice(5, 21), scenario.sanctioned);
    assert.equal(w[21], scenario.appScopeA, "appScope is public signal [20]");
    assert.equal(w[22], scenario.recipient, "recipient is public signal [21]");
  });

  it("produces different nullifiers for different app scopes (unlinkability)", async () => {
    const circuit = await loadProduction("credential");
    const cred = issueCredential(scenario, fields());
    const wA = await circuit.calculateWitness(asInput(await witnessFor(scenario, cred, scenario.appScopeA)), true);
    const wB = await circuit.calculateWitness(asInput(await witnessFor(scenario, cred, scenario.appScopeB)), true);
    assert.notEqual(wA[1], wB[1]);
  });

  it("rejects an underage subject", async () => {
    const circuit = await loadProduction("credential");
    // Born 2010 -> not yet 18 on 2026-09-29.
    const cred = issueCredential(scenario, fields({ birthdate: 20100101n }));
    const input = await witnessFor(scenario, cred, scenario.appScopeA);
    await expectWitnessFailure(circuit, asInput(input), "AgeAtLeast18");
  });

  it("rejects a sanctioned country", async () => {
    const circuit = await loadProduction("credential");
    const cred = issueCredential(scenario, fields({ countryCode: 364n }));
    const input = await witnessFor(scenario, cred, scenario.appScopeA);
    await expectWitnessFailure(circuit, asInput(input), "NotSanctioned");
  });

  it("rejects an expired credential", async () => {
    const circuit = await loadProduction("credential");
    const cred = issueCredential(scenario, fields({ expiry: 20260101n }));
    const input = await witnessFor(scenario, cred, scenario.appScopeA);
    await expectWitnessFailure(circuit, asInput(input), "NotExpired");
  });

  it("rejects a forged (tampered) signature", async () => {
    const circuit = await loadProduction("credential");
    const cred = issueCredential(scenario, fields());
    const input = await witnessFor(scenario, cred, scenario.appScopeA);
    input.sigS = input.sigS + 1n;
    await expectWitnessFailure(circuit, asInput(input), "EdDSAPoseidonVerifier");
  });

  it("rejects a prover whose secret does not open the signed commitment", async () => {
    const circuit = await loadProduction("credential");
    const cred = issueCredential(scenario, fields());
    const input = await witnessFor(scenario, cred, scenario.appScopeA);
    input.subjectSecret = input.subjectSecret + 1n; // e.g. an issuer guessing the secret
    await expectWitnessFailure(circuit, asInput(input), "EdDSAPoseidonVerifier");
  });

  it("rejects an issuer whose key is not in the trusted tree", async () => {
    const circuit = await loadProduction("credential");
    const cred = issueCredential(scenario, fields());
    const input = await witnessFor(scenario, cred, scenario.appScopeA);
    // Break the Merkle path so the recomputed root no longer matches issuerRoot.
    input.issuerPathElements[0] = input.issuerPathElements[0]! + 1n;
    await expectWitnessFailure(circuit, asInput(input), "MerkleInclusionProof");
  });

  it("rejects a stale/incorrect revocation root", async () => {
    const circuit = await loadProduction("credential");
    const cred = issueCredential(scenario, fields());
    const input = await witnessFor(scenario, cred, scenario.appScopeA);
    input.revocationRoot = input.revocationRoot + 1n;
    await expectWitnessFailure(circuit, asInput(input), "SMTVerifier");
  });

  it("accepts a sibling-collision exclusion proof (isOld0 = 0)", async () => {
    const circuit = await loadProduction("credential");
    const cred = issueCredential(scenario, fields());
    const input = await witnessFor(scenario, cred, scenario.appScopeA);
    assert.equal(input.revIsOld0, 0n, "the sentinel-only tree ends the path at a different leaf");
    assert.notEqual(input.revOldKey, 0n);
    const w = await circuit.calculateWitness(asInput(input), true);
    await circuit.checkConstraints(w);
  });

  it("accepts an empty-branch exclusion proof (isOld0 = 1)", async () => {
    const circuit = await loadProduction("credential");
    const world = await buildScenario();
    // Keys 4 and 8 share their two lowest bits, so the SMT splits them below
    // level 1 and leaves the (bit0=0, bit1=1) branch empty.
    await world.revocationTree.revoke(4n);
    await world.revocationTree.revoke(8n);
    let found: bigint | undefined;
    for (let id = 2n; id < 64n && found === undefined; id++) {
      if (id === 4n || id === 8n) continue;
      if ((await world.revocationTree.nonMembership(id)).isOld0 === 1n) found = id;
    }
    assert.ok(found !== undefined, "expected an id whose path ends in an empty branch");
    const cred = issueCredential(world, defaultCredentialFields(world.eddsa, { credentialId: found }));
    const input = await witnessFor(world, cred, world.appScopeA);
    assert.equal(input.revIsOld0, 1n);
    const w = await circuit.calculateWitness(asInput(input), true);
    await circuit.checkConstraints(w);
  });

  describe("revoked credential with a forged exclusion proof", () => {
    // The circuit (not the JS helper) must refuse: build the witness by hand.
    async function revokedInput(forge: (pre: NonMembershipProof) => NonMembershipProof) {
      const world = await buildScenario();
      const cid = 42n;
      const pre = await world.revocationTree.nonMembership(cid); // honest, BEFORE revocation
      await world.revocationTree.revoke(cid);
      const cred = issueCredential(world, defaultCredentialFields(world.eddsa, { credentialId: cid }));
      return buildCredentialInput({
        eddsa: world.eddsa,
        credential: cred,
        subjectSecret: DEV_SUBJECT_SECRET,
        issuerProof: world.issuerTree.proof(world.issuerIndex),
        revocationProof: { ...forge(pre), root: world.revocationTree.root() },
        sanctioned: world.sanctioned,
        currentDate: world.currentDate,
        appScope: world.appScopeA,
        recipient: world.recipient,
      });
    }

    it("rejects the pre-revocation siblings replayed against the post-revocation root", async () => {
      const circuit = await loadProduction("credential");
      const input = await revokedInput((pre) => pre);
      await expectWitnessFailure(circuit, asInput(input), "SMTVerifier");
    });

    it("rejects an empty-branch claim (isOld0 = 1, zero siblings) for a revoked id", async () => {
      const circuit = await loadProduction("credential");
      const input = await revokedInput((pre) => ({
        ...pre,
        siblings: pre.siblings.map(() => 0n),
        oldKey: 0n,
        oldValue: 0n,
        isOld0: 1n,
      }));
      await expectWitnessFailure(circuit, asInput(input), "SMTVerifier");
    });

    it("rejects a non-boolean isOld0 that rebuilds the revoked leaf against the CURRENT root", async () => {
      // circomlib's SMTVerifier alone accepts this witness (see subcircuits.test.ts);
      // the boolean guard in RevocationNonMembership is what stops it.
      const circuit = await loadProduction("credential");
      const world = await buildScenario();
      const cid = 42n;
      await world.revocationTree.revoke(cid);
      const member = await world.revocationTree.membership(cid);
      const forged = forgeRevokedExclusion(world.eddsa, cid, member.value);
      assert.ok(forged.isOld0 > 1n);
      const cred = issueCredential(world, defaultCredentialFields(world.eddsa, { credentialId: cid }));
      const input = buildCredentialInput({
        eddsa: world.eddsa,
        credential: cred,
        subjectSecret: DEV_SUBJECT_SECRET,
        issuerProof: world.issuerTree.proof(world.issuerIndex),
        revocationProof: { root: member.root, siblings: member.siblings, ...forged },
        sanctioned: world.sanctioned,
        currentDate: world.currentDate,
        appScope: world.appScopeA,
        recipient: world.recipient,
      });
      await expectWitnessFailure(circuit, asInput(input), "RevocationNonMembership");
    });
  });

  it("RevocationTree helper refuses to build an honest exclusion proof for a revoked id (JS only)", async () => {
    const fresh = await buildScenario();
    await fresh.revocationTree.revoke(42n);
    const cred = issueCredential(fresh, defaultCredentialFields(fresh.eddsa, { credentialId: 42n }));
    await assert.rejects(() => witnessFor(fresh, cred, fresh.appScopeA), /revoked/);
  });
});
