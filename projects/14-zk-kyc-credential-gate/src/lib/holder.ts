// SPDX-License-Identifier: MIT
import { randomBytes } from "node:crypto";
import { type Eddsa } from "circomlibjs";
import { commitment } from "./crypto.ts";
import { FIELD_MODULUS } from "./field.ts";

/**
 * Holder-side secret handling. The subject secret is generated on the
 * holder's machine and NEVER sent to the issuer; only its Poseidon commitment
 * leaves the device.
 */

/** Minimum accepted secret size: 128 bits. A guessable secret lets anyone
 *  recompute the commitment and every scoped nullifier (linkability). */
export const MIN_SECRET_BITS = 128;

/** A fresh uniformly random 248-bit secret (31 bytes, always < r). */
export function generateSubjectSecret(): bigint {
  return BigInt(`0x${randomBytes(31).toString("hex")}`);
}

/** Reject secrets that are out of the field or too small to be unguessable. */
export function assertStrongSecret(secret: bigint): void {
  if (secret <= 0n || secret >= FIELD_MODULUS) throw new Error("subject secret must be a non-zero field element");
  if (secret < 1n << BigInt(MIN_SECRET_BITS)) {
    throw new Error(`subject secret has fewer than ${MIN_SECRET_BITS} bits; generate one with \`holder commit\``);
  }
}

/** subjectCommitment = Poseidon(subjectSecret), the only value the issuer sees. */
export function subjectCommitment(eddsa: Eddsa, secret: bigint): bigint {
  return commitment(eddsa, secret);
}
