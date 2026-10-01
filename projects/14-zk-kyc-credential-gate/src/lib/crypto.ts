// SPDX-License-Identifier: MIT
import { buildEddsa, type Eddsa, type FElement } from "circomlibjs";

/**
 * A single shared EdDSA / Poseidon context.
 *
 * `circomlibjs` builds its Poseidon and BabyJubJub curve lazily and caches the
 * bn128 curve internally, so every hash and signature in this project runs
 * over the exact same field the circuits use.
 */
let cached: Eddsa | undefined;

export async function getEddsa(): Promise<Eddsa> {
  if (!cached) {
    cached = await buildEddsa();
  }
  return cached;
}

/** Poseidon over bigints, returning a canonical field element as a bigint. */
export function poseidon(eddsa: Eddsa, inputs: bigint[]): bigint {
  const F = eddsa.poseidon.F;
  return F.toObject(eddsa.poseidon(inputs));
}

/** Convert a field element to its canonical bigint. */
export function toBig(eddsa: Eddsa, felt: FElement): bigint {
  return eddsa.F.toObject(felt);
}

/** subjectCommitment = Poseidon(subjectSecret). */
export function commitment(eddsa: Eddsa, subjectSecret: bigint): bigint {
  return poseidon(eddsa, [subjectSecret]);
}

/** Poseidon leaf for a trusted issuer public key. */
export function issuerLeaf(eddsa: Eddsa, ax: bigint, ay: bigint): bigint {
  return poseidon(eddsa, [ax, ay]);
}

/** Scoped nullifier = Poseidon(subjectSecret, appScope). */
export function nullifier(
  eddsa: Eddsa,
  subjectSecret: bigint,
  appScope: bigint,
): bigint {
  return poseidon(eddsa, [subjectSecret, appScope]);
}

/**
 * The credential message hash, matching `CredentialMessageHash` in
 * circuits/lib/credential_lib.circom. Field order is load-bearing.
 */
export function messageHash(
  eddsa: Eddsa,
  fields: {
    subjectCommitment: bigint;
    birthdate: bigint;
    countryCode: bigint;
    accredited: bigint;
    expiry: bigint;
    credentialId: bigint;
  },
): bigint {
  return poseidon(eddsa, [
    fields.subjectCommitment,
    fields.birthdate,
    fields.countryCode,
    fields.accredited,
    fields.expiry,
    fields.credentialId,
  ]);
}
