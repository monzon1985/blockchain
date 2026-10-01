// SPDX-License-Identifier: MIT
import { type Eddsa } from "circomlibjs";
import { messageHash, toBig } from "./crypto.ts";
import { FIELD_MODULUS } from "./field.ts";

/**
 * The six signed fields of a KYC credential, exactly as the ISSUER sees them.
 *
 * The issuer never learns the holder's `subjectSecret`: the holder generates
 * it locally (`src/lib/holder.ts`, `node src/cli/holder.ts commit`) and only
 * hands over `subjectCommitment = Poseidon(subjectSecret)`. Knowing the secret
 * would let the issuer compute `Poseidon(secret, appScope)` for every gate,
 * i.e. link each on-chain registration to the KYC'd identity and burn the
 * holder's nullifiers.
 */
export interface CredentialFields {
  /** Poseidon(subjectSecret), supplied by the holder. */
  subjectCommitment: bigint;
  /** Date of birth as a YYYYMMDD integer, e.g. 19900215. */
  birthdate: bigint;
  /** ISO-3166 numeric country code, e.g. 724 for Spain. */
  countryCode: bigint;
  /** Accredited-investor flag (0/1); bound into the signature, not gated. */
  accredited: bigint;
  /** Credential expiry as a YYYYMMDD integer. */
  expiry: bigint;
  /** Unique credential identifier (also the revocation-tree key). */
  credentialId: bigint;
}

/** A credential together with the issuer's EdDSA-Poseidon signature. */
export interface SignedCredential {
  fields: CredentialFields;
  issuerAx: bigint;
  issuerAy: bigint;
  sigS: bigint;
  sigR8x: bigint;
  sigR8y: bigint;
  messageHash: bigint;
}

/** A BabyJubJub EdDSA issuer key pair. */
export interface IssuerKey {
  privateKey: Uint8Array;
  ax: bigint;
  ay: bigint;
}

/**
 * Credential id reserved as the always-revoked sentinel. An empty circomlib
 * sparse Merkle tree has root 0, which ZkGate rejects (`ZeroRoot`), so every
 * deployment revokes this id to keep the revocation root non-zero. Real
 * credentials must never use it.
 */
export const REVOKED_SENTINEL = 1n;

/** True iff `v` is a real calendar date written as YYYYMMDD (years 1900-9999). */
export function isValidYyyymmdd(v: bigint): boolean {
  if (v < 19000101n || v > 99991231n) return false;
  const year = Number(v / 10000n);
  const month = Number((v / 100n) % 100n);
  const day = Number(v % 100n);
  if (month < 1 || month > 12 || day < 1) return false;
  const leap = (year % 4 === 0 && year % 100 !== 0) || year % 400 === 0;
  const days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1] as number;
  return day <= days;
}

/**
 * Issuer-side well-formedness policy. The circuit is the last line of
 * defence (it range-checks every comparator input, so a field-wrapped value
 * cannot pass), but it does NOT check that a date is a real calendar date,
 * that `accredited` is boolean, or that the credential id is not the revoked
 * sentinel. A careful issuer refuses to sign such values; this function is
 * that refusal. Returns the list of violations (empty = valid).
 */
export function credentialFieldViolations(fields: CredentialFields): string[] {
  const errors: string[] = [];
  if (fields.subjectCommitment <= 0n || fields.subjectCommitment >= FIELD_MODULUS) {
    errors.push("subjectCommitment must be a non-zero field element");
  }
  if (!isValidYyyymmdd(fields.birthdate)) errors.push(`birthdate ${fields.birthdate} is not a valid YYYYMMDD date`);
  if (!isValidYyyymmdd(fields.expiry)) errors.push(`expiry ${fields.expiry} is not a valid YYYYMMDD date`);
  if (isValidYyyymmdd(fields.birthdate) && isValidYyyymmdd(fields.expiry) && fields.expiry <= fields.birthdate) {
    errors.push("expiry must be after birthdate");
  }
  if (fields.countryCode < 1n || fields.countryCode > 999n) {
    errors.push(`countryCode ${fields.countryCode} is not an ISO-3166 numeric code (1..999)`);
  }
  if (fields.accredited !== 0n && fields.accredited !== 1n) errors.push("accredited must be 0 or 1");
  if (fields.credentialId <= REVOKED_SENTINEL || fields.credentialId >= FIELD_MODULUS) {
    errors.push(`credentialId must be in (${REVOKED_SENTINEL}, r): 0 is invalid and ${REVOKED_SENTINEL} is the revoked sentinel`);
  }
  return errors;
}

/**
 * Deterministically derive an issuer key from a 32-byte seed. Real issuers
 * would keep the private key in an HSM; this is a demo helper.
 */
export function issuerKeyFromSeed(eddsa: Eddsa, seed: Uint8Array): IssuerKey {
  if (seed.length !== 32) {
    throw new Error(`issuer seed must be 32 bytes, got ${seed.length}`);
  }
  const pub = eddsa.prv2pub(seed);
  return { privateKey: seed, ax: toBig(eddsa, pub[0]), ay: toBig(eddsa, pub[1]) };
}

/** Options for {@link signCredential}. */
export interface SignOptions {
  /**
   * Skip the issuer's well-formedness policy. ONLY for the adversarial bug-zoo
   * code that emulates a buggy/malicious issuer (zoo #2); never set by the CLI.
   */
  emulateMaliciousIssuer?: boolean;
}

/**
 * Sign a credential with an issuer key. Refuses malformed fields unless the
 * caller explicitly emulates a malicious issuer.
 */
export function signCredential(
  eddsa: Eddsa,
  key: IssuerKey,
  fields: CredentialFields,
  opts: SignOptions = {},
): SignedCredential {
  if (!opts.emulateMaliciousIssuer) {
    const violations = credentialFieldViolations(fields);
    if (violations.length > 0) {
      throw new Error(`refusing to sign a malformed credential: ${violations.join("; ")}`);
    }
  }
  const m = messageHash(eddsa, fields);
  const F = eddsa.poseidon.F;
  const sig = eddsa.signPoseidon(key.privateKey, F.e(m));
  return {
    fields,
    issuerAx: key.ax,
    issuerAy: key.ay,
    sigS: sig.S,
    sigR8x: toBig(eddsa, sig.R8[0]),
    sigR8y: toBig(eddsa, sig.R8[1]),
    messageHash: m,
  };
}
