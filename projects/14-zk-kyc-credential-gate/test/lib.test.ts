// SPDX-License-Identifier: MIT
//
// Unit tests for the TypeScript issuer/holder/witness helpers (no proving).
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { getEddsa } from "../src/lib/crypto.ts";
import { FIELD_MODULUS, computeAppScope, invMod, mod } from "../src/lib/field.ts";
import {
  credentialFieldViolations,
  isValidYyyymmdd,
  issuerKeyFromSeed,
  signCredential,
  REVOKED_SENTINEL,
  type CredentialFields,
} from "../src/lib/issuer.ts";
import { assertStrongSecret, generateSubjectSecret, subjectCommitment } from "../src/lib/holder.ts";
import {
  buildScenario,
  defaultCredentialFields,
  issueCredential,
  witnessFor,
  DEV_ACTION_ID,
  DEV_CHAIN_ID,
  DEV_EPOCH,
  DEV_GATE_ADDRESS,
  DEV_GATE_B_ADDRESS,
  DEV_ISSUER_SEED,
} from "../src/lib/scenario.ts";
import { calculateWitness, patchWitnessValue, readWitnessValue, witnessLength } from "../src/lib/witness_patch.ts";
import { forgeNonBooleanSelectorPath } from "../src/lib/zoo_attacks.ts";

describe("issuer policy", () => {
  it("accepts real calendar dates only (leap years included)", () => {
    for (const ok of [19900215n, 20000229n, 20240229n, 99991231n]) assert.ok(isValidYyyymmdd(ok), `${ok}`);
    for (const bad of [0n, 19001301n, 19000230n, 19000229n, 20230229n, 19900100n, 18991231n, 100000101n]) {
      assert.ok(!isValidYyyymmdd(bad), `${bad}`);
    }
  });

  it("flags every malformed field the circuit does not check", async () => {
    const eddsa = await getEddsa();
    const good = defaultCredentialFields(eddsa);
    assert.deepEqual(credentialFieldViolations(good), []);
    const cases: Array<[Partial<CredentialFields>, RegExp]> = [
      [{ birthdate: 0n }, /birthdate/],
      [{ birthdate: 19901301n }, /birthdate/],
      [{ expiry: 20301232n }, /expiry/],
      [{ accredited: 7n }, /accredited/],
      [{ credentialId: REVOKED_SENTINEL }, /sentinel/],
      [{ credentialId: 0n }, /credentialId/],
      [{ countryCode: 0n }, /countryCode/],
      [{ subjectCommitment: 0n }, /subjectCommitment/],
      [{ birthdate: FIELD_MODULUS - 179999n }, /birthdate/],
    ];
    for (const [override, re] of cases) {
      const v = credentialFieldViolations({ ...good, ...override });
      assert.ok(
        v.some((m) => re.test(m)),
        `${Object.keys(override).join(",")}: ${v.join("; ")}`,
      );
    }
  });

  it("signCredential refuses malformed fields unless a malicious issuer is emulated", async () => {
    const eddsa = await getEddsa();
    const key = issuerKeyFromSeed(eddsa, DEV_ISSUER_SEED);
    const bad = defaultCredentialFields(eddsa, { birthdate: 0n });
    assert.throws(() => signCredential(eddsa, key, bad), /refusing to sign/);
    assert.ok(signCredential(eddsa, key, bad, { emulateMaliciousIssuer: true }).sigS > 0n);
  });
});

describe("holder secret", () => {
  it("generates 248-bit secrets and only exposes the commitment", async () => {
    const eddsa = await getEddsa();
    const s = generateSubjectSecret();
    assert.ok(s > 0n && s < 1n << 248n && s < FIELD_MODULUS);
    assertStrongSecret(s);
    assert.notEqual(subjectCommitment(eddsa, s), s);
  });

  it("rejects low-entropy or out-of-field secrets", () => {
    assert.throws(() => assertStrongSecret(123n), /fewer than 128 bits/);
    assert.throws(() => assertStrongSecret(0n), /non-zero/);
    assert.throws(() => assertStrongSecret(FIELD_MODULUS), /non-zero field element/);
  });

  it("the witness builder refuses a secret that does not open the signed commitment", async () => {
    const scenario = await buildScenario();
    const cred = issueCredential(scenario, defaultCredentialFields(scenario.eddsa));
    await assert.rejects(
      () => witnessFor(scenario, cred, scenario.appScopeA, { secret: 42n }),
      /does not open the credential.s subjectCommitment/,
    );
  });
});

describe("scope derivation", () => {
  it("binds chain id, gate address, action id and epoch", () => {
    const base = computeAppScope(DEV_CHAIN_ID, DEV_GATE_ADDRESS, DEV_ACTION_ID, DEV_EPOCH);
    assert.ok(base < FIELD_MODULUS);
    assert.notEqual(base, computeAppScope(DEV_CHAIN_ID + 1n, DEV_GATE_ADDRESS, DEV_ACTION_ID, DEV_EPOCH));
    assert.notEqual(base, computeAppScope(DEV_CHAIN_ID, DEV_GATE_B_ADDRESS, DEV_ACTION_ID, DEV_EPOCH));
    assert.notEqual(base, computeAppScope(DEV_CHAIN_ID, DEV_GATE_ADDRESS, DEV_ACTION_ID, DEV_EPOCH + 1n));
  });
});

describe("zoo #3 forgery arithmetic", () => {
  it("steers a non-boolean selector onto the real (leaf, sibling) pair", () => {
    const honest = { root: 9n, leaf: 111n, pathElements: [222n, 5n, 6n], pathIndices: [0n, 1n, 0n] };
    const f = forgeNonBooleanSelectorPath(honest, 999n);
    const pe = f.pathElements[0] as bigint;
    const s = f.selector;
    assert.equal(mod((pe - 999n) * s + 999n), 111n);
    assert.equal(mod((999n - pe) * s + pe), 222n);
    assert.deepEqual(f.pathElements.slice(1), [5n, 6n]);
    assert.equal(mod(invMod(7n) * 7n), 1n);
  });
});

describe("witness patching (@iden3/binfileutils)", () => {
  it("rewrites exactly one value and refuses out-of-field values", async () => {
    const scenario = await buildScenario();
    const cred = issueCredential(scenario, defaultCredentialFields(scenario.eddsa));
    const input = await witnessFor(scenario, cred, scenario.appScopeA);
    const file = path.join(fs.mkdtempSync(path.join(os.tmpdir(), "wtns-")), "w.wtns");
    await calculateWitness("credential", input as unknown as Record<string, bigint | bigint[]>, file);
    const n = await witnessLength(file);
    const before = await readWitnessValue(file, 5);
    await patchWitnessValue(file, 1, 12345n);
    assert.equal(await readWitnessValue(file, 1), 12345n);
    assert.equal(await readWitnessValue(file, 5), before, "other values untouched");
    assert.equal(await witnessLength(file), n);
    await assert.rejects(() => patchWitnessValue(file, 1, FIELD_MODULUS), /canonical field element/);
    await assert.rejects(() => patchWitnessValue(file, n, 1n), /out of range/);
  });
});
