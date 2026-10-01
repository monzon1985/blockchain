// SPDX-License-Identifier: MIT
//
// Attack-side helpers for the bug zoo. Each function builds the malicious
// witness input that the corresponding FLAWED circuit accepts and the
// production circuit rejects. They are used by the zoo script, the circuit
// tests and the fixture generator; nothing on the honest path imports them.
import { type Eddsa } from "circomlibjs";
import { FIELD_MODULUS, invMod, mod } from "./field.ts";
import { issuerLeaf, poseidon } from "./crypto.ts";
import { issuerKeyFromSeed, signCredential, type CredentialFields, type SignedCredential } from "./issuer.ts";
import { type MerkleProof } from "./merkle.ts";

/** Witness index of the nullifier output (index 0 is the constant `1`). */
export const NULLIFIER_WITNESS_INDEX = 1;

/**
 * Zoo #2: a "birthdate" that is not a date. `r - 179999 + 180000 = 1 (mod r)`,
 * so a range-check-free `birthdate + 180000 <= currentDate` holds.
 */
export const WRAPPED_BIRTHDATE = FIELD_MODULUS - 179999n;

/** Zoo #3: the attacker's own holder secret (distinct from the honest dev holder). */
export const ATTACKER_SUBJECT_SECRET = 0x0bad0bad0bad0bad0bad0bad0bad0bad0bad0bad0bad0bad0bad0bad0bad0ban;

/** Zoo #3: the attacker's self-generated issuer seed (NOT in the trusted tree). */
export const ATTACKER_ISSUER_SEED = new Uint8Array(32).map((_v, i) => (0xa5 ^ (i * 13)) & 0xff);

/**
 * Zoo #3 forgery. Given the HONEST inclusion proof of some trusted leaf and
 * the attacker's own leaf, return a path that a Merkle gadget WITHOUT boolean
 * selector constraints accepts for the attacker's leaf against the real root.
 *
 * MultiMux1 with c = [[h, pe], [pe, h]] outputs (out0, out1) =
 * ((pe - h)s + h, (h - pe)s + pe). Choosing pe = L + R - h and
 * s = (L - h) / (pe - h) makes (out0, out1) = (L, R): level 0 then hashes the
 * real (leaf, sibling) pair, and every level above reuses the honest path.
 */
export function forgeNonBooleanSelectorPath(
  honest: MerkleProof,
  attackerLeaf: bigint,
): { pathElements: bigint[]; pathIndices: bigint[]; selector: bigint } {
  const sibling = honest.pathElements[0] as bigint;
  const bit = honest.pathIndices[0] as bigint;
  const [left, right] = bit === 0n ? [honest.leaf, sibling] : [sibling, honest.leaf];
  const h = attackerLeaf;
  const pe = mod(left + right - h);
  if (pe === h) throw new Error("degenerate forgery (pe == h); pick another attacker key");
  const s = mod((left - h) * invMod(pe - h));
  // Sanity: the affine mux really lands on (left, right).
  const out0 = mod((pe - h) * s + h);
  const out1 = mod((h - pe) * s + pe);
  if (out0 !== left || out1 !== right) throw new Error("forgery arithmetic is wrong");
  return {
    pathElements: [pe, ...honest.pathElements.slice(1)],
    pathIndices: [s, ...honest.pathIndices.slice(1)],
    selector: s,
  };
}

/**
 * Revocation bypass through circomlib's SMTVerifier, which never constrains
 * `isOld0` to be a bit. In exclusion mode the node at the insertion level is
 * `(1 - isOld0) * Poseidon(oldKey, oldValue, 1)`. Given the PUBLIC membership
 * path of a revoked id, pick any `oldKey != revokedId` and solve for the
 * `isOld0` that turns that node into the real revoked leaf
 * `Poseidon(revokedId, value, 1)`: every level above then rebuilds the real
 * post-revocation root. The production `RevocationNonMembership` rejects it
 * with `isOld0 * (isOld0 - 1) === 0`.
 */
export function forgeRevokedExclusion(
  eddsa: Eddsa,
  revokedId: bigint,
  storedValue: bigint,
): { oldKey: bigint; oldValue: bigint; isOld0: bigint } {
  const oldKey = revokedId + 1n;
  const oldValue = 0n;
  const revokedLeaf = poseidon(eddsa, [revokedId, storedValue, 1n]);
  const decoyLeaf = poseidon(eddsa, [oldKey, oldValue, 1n]);
  const isOld0 = mod(1n - revokedLeaf * invMod(decoyLeaf));
  if (mod((1n - isOld0) * decoyLeaf) !== revokedLeaf) throw new Error("forgery arithmetic is wrong");
  return { oldKey, oldValue, isOld0 };
}

/**
 * Zoo #3: the attacker signs their OWN credential with their own,
 * untrusted key (any fields they like; here they simply claim adulthood).
 */
export function attackerSelfSignedCredential(
  eddsa: Eddsa,
  fields: CredentialFields,
): { credential: SignedCredential; attackerLeaf: bigint } {
  const key = issuerKeyFromSeed(eddsa, ATTACKER_ISSUER_SEED);
  const credential = signCredential(eddsa, key, fields);
  return { credential, attackerLeaf: issuerLeaf(eddsa, key.ax, key.ay) };
}
