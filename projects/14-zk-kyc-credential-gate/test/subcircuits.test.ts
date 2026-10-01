// SPDX-License-Identifier: MIT
import assert from "node:assert/strict";
import { compileTest, expectWitnessFailure } from "./helpers.ts";
import { getEddsa, poseidon, nullifier, issuerLeaf } from "../src/lib/crypto.ts";
import { PoseidonMerkleTree } from "../src/lib/merkle.ts";
import { RevocationTree } from "../src/lib/revocation.ts";
import { forgeRevokedExclusion } from "../src/lib/zoo_attacks.ts";
import { FIELD_MODULUS } from "../src/lib/field.ts";
import { type Eddsa } from "circomlibjs";

const TWO_32 = 1n << 32n;

describe("AgeAtLeast18", () => {
  it("accepts a subject who turns 18 exactly on currentDate", async () => {
    const c = await compileTest("age.circom");
    // 20080929 + 180000 = 20260929 == currentDate  -> <= holds
    const w = await c.calculateWitness({ birthdate: 20080929n, currentDate: 20260929n }, true);
    await c.checkConstraints(w);
  });

  it("rejects a subject one day too young", async () => {
    const c = await compileTest("age.circom");
    // 20080930 + 180000 = 20260930 > 20260929
    await expectWitnessFailure(c, { birthdate: 20080930n, currentDate: 20260929n }, "AgeAtLeast18");
  });

  it("rejects a birthdate that is not a 32-bit integer (range guard)", async () => {
    const c = await compileTest("age.circom");
    const msg = await expectWitnessFailure(c, { birthdate: TWO_32, currentDate: 20260929n }, "AgeAtLeast18");
    assert.match(msg, /Error in template Num2Bits/, "the Num2Bits range guard must be what fails");
  });
});

describe("NotExpired", () => {
  it("accepts an unexpired credential", async () => {
    const c = await compileTest("notexpired.circom");
    const w = await c.calculateWitness({ expiry: 20301231n, currentDate: 20260929n }, true);
    await c.checkConstraints(w);
  });

  it("rejects a credential expiring exactly today (strict >)", async () => {
    const c = await compileTest("notexpired.circom");
    await expectWitnessFailure(c, { expiry: 20260929n, currentDate: 20260929n }, "NotExpired");
  });

  it("rejects an expired credential", async () => {
    const c = await compileTest("notexpired.circom");
    await expectWitnessFailure(c, { expiry: 20200101n, currentDate: 20260929n }, "NotExpired");
  });

  it("rejects a field-wrapped currentDate on its own (no reliance on the caller's guard)", async () => {
    // Regression: before NotExpired range-checked currentDate itself, the
    // standalone gadget accepted expiry=20301231, currentDate=r-1.
    const c = await compileTest("notexpired.circom");
    const msg = await expectWitnessFailure(
      c,
      { expiry: 20301231n, currentDate: FIELD_MODULUS - 1n },
      "NotExpired",
    );
    assert.match(msg, /Error in template Num2Bits/, "the currentDate range guard must be what fails");
  });
});

describe("NotSanctioned(16)", () => {
  const sanctioned = [408n, 364n, 760n, 192n, 0n, 0n, 0n, 0n, 0n, 0n, 0n, 0n, 0n, 0n, 0n, 0n];

  it("accepts a non-sanctioned country", async () => {
    const c = await compileTest("sanctioned.circom");
    const w = await c.calculateWitness({ countryCode: 724n, sanctioned }, true);
    await c.checkConstraints(w);
  });

  it("rejects a sanctioned country", async () => {
    const c = await compileTest("sanctioned.circom");
    await expectWitnessFailure(c, { countryCode: 364n, sanctioned }, "NotSanctioned");
  });

  it("rejects a sanctioned country in the last slot", async () => {
    const c = await compileTest("sanctioned.circom");
    const list = sanctioned.slice();
    list[15] = 999n;
    await expectWitnessFailure(c, { countryCode: 999n, sanctioned: list }, "NotSanctioned");
  });
});

describe("MerkleInclusionProof(8)", () => {
  let eddsa: Eddsa;
  before(async () => {
    eddsa = await getEddsa();
  });

  it("verifies a valid inclusion proof", async () => {
    const c = await compileTest("merkle.circom");
    const tree = new PoseidonMerkleTree(eddsa, 8);
    tree.insert(issuerLeaf(eddsa, 1n, 2n));
    const idx = tree.insert(issuerLeaf(eddsa, 11n, 22n));
    tree.insert(issuerLeaf(eddsa, 3n, 4n));
    const p = tree.proof(idx);
    const w = await c.calculateWitness(
      { leaf: p.leaf, root: p.root, pathElements: p.pathElements, pathIndices: p.pathIndices },
      true,
    );
    await c.checkConstraints(w);
  });

  it("rejects a proof against a tampered root", async () => {
    const c = await compileTest("merkle.circom");
    const tree = new PoseidonMerkleTree(eddsa, 8);
    const idx = tree.insert(issuerLeaf(eddsa, 11n, 22n));
    const p = tree.proof(idx);
    await expectWitnessFailure(
      c,
      { leaf: p.leaf, root: p.root + 1n, pathElements: p.pathElements, pathIndices: p.pathIndices },
      "MerkleInclusionProof",
    );
  });

  it("rejects a non-boolean path selector (the constraint zoo #3 removes)", async () => {
    const c = await compileTest("merkle.circom");
    const tree = new PoseidonMerkleTree(eddsa, 8);
    const idx = tree.insert(issuerLeaf(eddsa, 11n, 22n));
    const p = tree.proof(idx);
    const indices = p.pathIndices.slice();
    indices[0] = 2n;
    await expectWitnessFailure(
      c,
      { leaf: p.leaf, root: p.root, pathElements: p.pathElements, pathIndices: indices },
      "MerkleInclusionProof",
    );
  });
});

describe("RevocationNonMembership(20): non-boolean isOld0", () => {
  // circomlib's SMTVerifier never constrains isOld0 to {0, 1}. With the public
  // membership path of a REVOKED id, solving for isOld0 rebuilds the real
  // revoked leaf at the insertion level, so the raw gadget "proves" that the
  // revoked id is absent from the current tree.
  async function forgedExclusion() {
    const eddsa = await getEddsa();
    const tree = await RevocationTree.create(eddsa, 20);
    await tree.revoke(1n); // the sentinel every deployment carries
    await tree.revoke(42n);
    const member = await tree.membership(42n);
    const forged = forgeRevokedExclusion(eddsa, 42n, member.value);
    return {
      credentialId: 42n,
      revocationRoot: member.root,
      siblings: member.siblings,
      ...forged,
    };
  }

  it("circomlib's raw SMTVerifier ACCEPTS the forged exclusion of a revoked id (the gap)", async () => {
    const c = await compileTest("smt_exclusion_circomlib.circom");
    const input = await forgedExclusion();
    assert.ok(input.isOld0 > 1n, "the forgery relies on a non-boolean isOld0");
    const w = await c.calculateWitness(input, true);
    await c.checkConstraints(w);
  });

  it("RevocationNonMembership rejects the same witness (isOld0 must be a bit)", async () => {
    const c = await compileTest("revocation.circom");
    await expectWitnessFailure(c, await forgedExclusion(), "RevocationNonMembership");
  });
});

describe("NullifierHash", () => {
  it("outputs Poseidon(subjectSecret, appScope)", async () => {
    const eddsa = await getEddsa();
    const c = await compileTest("nullifier.circom");
    const secret = 123456789n;
    const scope = 987654321n;
    const w = await c.calculateWitness({ subjectSecret: secret, appScope: scope }, true);
    await c.checkConstraints(w);
    const expected = nullifier(eddsa, secret, scope);
    assert.equal(w[1], expected, "circuit nullifier must equal JS Poseidon(secret, scope)");
    assert.equal(expected, poseidon(eddsa, [secret, scope]));
  });
});
