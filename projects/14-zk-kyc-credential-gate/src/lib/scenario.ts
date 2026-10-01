// SPDX-License-Identifier: MIT
//
// The deterministic dev/test world shared by the circuit tests, the bug zoo,
// the committed Foundry fixtures and the local demo.
//
// TEST-ONLY SECRETS: `DEV_SUBJECT_SECRET` and `DEV_ISSUER_SEED` are fixed,
// public values so fixtures are reproducible. Real holders generate their
// secret with `node src/cli/holder.ts commit`; real issuers keep their seed in
// an HSM / key file and never see holder secrets.
import { type Address, type Hex } from "viem";
import { type Eddsa } from "circomlibjs";
import { getEddsa } from "./crypto.ts";
import {
  issuerKeyFromSeed,
  signCredential,
  REVOKED_SENTINEL,
  type CredentialFields,
  type IssuerKey,
  type SignOptions,
  type SignedCredential,
} from "./issuer.ts";
import { subjectCommitment } from "./holder.ts";
import { type PoseidonMerkleTree } from "./merkle.ts";
import { type RevocationTree } from "./revocation.ts";
import { buildWorld, type WorldFile } from "./world.ts";
import { buildCredentialInput, type CredentialCircuitInput } from "./inputs.ts";
import { actionIdFromString, addressToField, computeAppScope, FIELD_MODULUS } from "./field.ts";

export { ISSUER_TREE_DEPTH, REVOCATION_TREE_DEPTH, N_SANCTIONED } from "./world.ts";
export { REVOKED_SENTINEL } from "./issuer.ts";

/** Local dev chain id used for scope derivation in tests and fixtures. */
export const DEV_CHAIN_ID = 31337n;

/**
 * Fixed addresses the Foundry suite deploys ZkGate to (`deployCodeTo`), so the
 * address-bound appScope of the committed proofs is known in advance. In a
 * real deployment the prover simply reads `appScope()` from the live gate.
 */
export const DEV_GATE_ADDRESS: Address = "0x000000000000000000000000000000000000A11A";
/** A second gate with the SAME actionId (a clone, or a sibling app). */
export const DEV_GATE_B_ADDRESS: Address = "0x000000000000000000000000000000000000b22B";

/** The action the demo gate protects. */
export const DEV_ACTION_ID: Hex = actionIdFromString("zk-kyc-gate:allowlist-v1");

/** Registration epoch length used by tests, fixtures and the demo: 30 days. */
export const DEV_EPOCH_DURATION = 30n * 24n * 60n * 60n;

/** Block timestamp the fixtures are proven for: 2026-09-29T12:00:00Z. */
export const DEV_TIMESTAMP = 1790683200n;

/** The epoch containing DEV_TIMESTAMP. */
export const DEV_EPOCH = DEV_TIMESTAMP / DEV_EPOCH_DURATION;

/** The account every committed proof is bound to (`address(0xB0B)` in Solidity). */
export const DEV_RECIPIENT: Address = "0x0000000000000000000000000000000000000B0B";

/**
 * A demonstration sanctioned-country list (ISO-3166 numeric codes), padded to
 * 16 entries with 0 (an invalid ISO code, so it never matches a real country).
 * This list is illustrative only; it is not an official sanctions list.
 */
export const SANCTIONED_COUNTRIES: bigint[] = [
  408n, // Korea (DPRK)
  364n, // Iran
  760n, // Syria
  192n, // Cuba
  0n,
  0n,
  0n,
  0n,
  0n,
  0n,
  0n,
  0n,
  0n,
  0n,
  0n,
  0n,
];

/** Fixed 32-byte issuer seed for deterministic dev/CI. Not a real key. */
export const DEV_ISSUER_SEED = new Uint8Array(32).map((_v, i) => (i * 7 + 3) & 0xff);

/** TEST-ONLY fixed holder secret (a real holder generates a random one). */
export const DEV_SUBJECT_SECRET =
  0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdefn % FIELD_MODULUS;

/** Default "today" used by the tests, as a YYYYMMDD integer. */
export const DEV_CURRENT_DATE = 20260929n;

/** Scope of the dev gate at DEV_GATE_ADDRESS in DEV_EPOCH. */
export function devScope(gate: Address = DEV_GATE_ADDRESS, epoch: bigint = DEV_EPOCH): bigint {
  return computeAppScope(DEV_CHAIN_ID, gate, DEV_ACTION_ID, epoch);
}

/** The public dev world: two decoy issuers, the dev issuer, the revoked sentinel. */
export function devWorldFile(issuerKey: IssuerKey): WorldFile {
  return {
    issuers: [
      { ax: "1", ay: "2" },
      { ax: "3", ay: "4" },
      { ax: issuerKey.ax.toString(), ay: issuerKey.ay.toString() },
    ],
    revoked: [REVOKED_SENTINEL.toString()],
    sanctioned: SANCTIONED_COUNTRIES.map((s) => s.toString()),
    currentDate: DEV_CURRENT_DATE.toString(),
  };
}

/** A fully wired-up honest world the tests, zoo and fixtures build on. */
export interface Scenario {
  eddsa: Eddsa;
  issuerKey: IssuerKey;
  issuerTree: PoseidonMerkleTree;
  issuerIndex: number;
  revocationTree: RevocationTree;
  sanctioned: bigint[];
  currentDate: bigint;
  /** Scope of the gate at DEV_GATE_ADDRESS in DEV_EPOCH. */
  appScopeA: bigint;
  /** Scope of the gate at DEV_GATE_B_ADDRESS in DEV_EPOCH. */
  appScopeB: bigint;
  /** uint160(DEV_RECIPIENT). */
  recipient: bigint;
}

/** Build the default honest world: one trusted issuer, sentinel-only revocation tree. */
export async function buildScenario(): Promise<Scenario> {
  const eddsa = await getEddsa();
  const issuerKey = issuerKeyFromSeed(eddsa, DEV_ISSUER_SEED);
  const world = await buildWorld(eddsa, devWorldFile(issuerKey));
  return {
    eddsa,
    issuerKey,
    issuerTree: world.issuerTree,
    issuerIndex: 2,
    revocationTree: world.revocationTree,
    sanctioned: world.sanctioned,
    currentDate: world.currentDate,
    appScopeA: devScope(DEV_GATE_ADDRESS),
    appScopeB: devScope(DEV_GATE_B_ADDRESS),
    recipient: addressToField(DEV_RECIPIENT),
  };
}

/** An honest, adult, non-sanctioned, unexpired credential for `secret`. */
export function defaultCredentialFields(
  eddsa: Eddsa,
  overrides: Partial<CredentialFields> = {},
  secret: bigint = DEV_SUBJECT_SECRET,
): CredentialFields {
  return {
    subjectCommitment: subjectCommitment(eddsa, secret),
    birthdate: 19900215n,
    countryCode: 724n, // Spain
    accredited: 1n,
    expiry: 20301231n,
    credentialId: 987654321012345678n,
    ...overrides,
  };
}

/** Sign `fields` with the scenario issuer (validated unless opts says otherwise). */
export function issueCredential(
  scenario: Scenario,
  fields: CredentialFields,
  opts: SignOptions = {},
): SignedCredential {
  return signCredential(scenario.eddsa, scenario.issuerKey, fields, opts);
}

/** Options for {@link witnessFor}. */
export interface WitnessOptions {
  /** Holder secret; defaults to the TEST-ONLY DEV_SUBJECT_SECRET. */
  secret?: bigint;
  /** Recipient field; defaults to uint160(DEV_RECIPIENT). */
  recipient?: bigint;
}

/**
 * Build a complete circuit witness for a signed credential against the given
 * scope. Produces the issuer inclusion proof and revocation exclusion proof
 * on the fly from the scenario's trees.
 */
export async function witnessFor(
  scenario: Scenario,
  credential: SignedCredential,
  appScope: bigint,
  opts: WitnessOptions = {},
): Promise<CredentialCircuitInput> {
  const issuerProof = scenario.issuerTree.proof(scenario.issuerIndex);
  const revocationProof = await scenario.revocationTree.nonMembership(credential.fields.credentialId);
  return buildCredentialInput({
    eddsa: scenario.eddsa,
    credential,
    subjectSecret: opts.secret ?? DEV_SUBJECT_SECRET,
    issuerProof,
    revocationProof,
    sanctioned: scenario.sanctioned,
    currentDate: scenario.currentDate,
    appScope,
    recipient: opts.recipient ?? scenario.recipient,
  });
}
