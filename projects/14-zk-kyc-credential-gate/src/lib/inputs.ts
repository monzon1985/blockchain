// SPDX-License-Identifier: MIT
import { type Eddsa } from "circomlibjs";
import { commitment } from "./crypto.ts";
import { type MerkleProof } from "./merkle.ts";
import { type NonMembershipProof } from "./revocation.ts";
import { type SignedCredential } from "./issuer.ts";

/** Fully-typed witness for the CredentialGate circuit (bigints throughout). */
export interface CredentialCircuitInput {
  currentDate: bigint;
  issuerRoot: bigint;
  revocationRoot: bigint;
  sanctioned: bigint[];
  appScope: bigint;
  recipient: bigint;

  subjectSecret: bigint;
  birthdate: bigint;
  countryCode: bigint;
  accredited: bigint;
  expiry: bigint;
  credentialId: bigint;

  issuerAx: bigint;
  issuerAy: bigint;
  sigS: bigint;
  sigR8x: bigint;
  sigR8y: bigint;

  issuerPathElements: bigint[];
  issuerPathIndices: bigint[];

  revSiblings: bigint[];
  revOldKey: bigint;
  revOldValue: bigint;
  revIsOld0: bigint;
}

export interface BuildInputArgs {
  eddsa: Eddsa;
  credential: SignedCredential;
  /** The holder's secret; must open `credential.fields.subjectCommitment`. */
  subjectSecret: bigint;
  issuerProof: MerkleProof;
  revocationProof: NonMembershipProof;
  sanctioned: bigint[];
  currentDate: bigint;
  appScope: bigint;
  /** `uint160` of the address that will submit the proof. */
  recipient: bigint;
}

/** Assemble the circuit witness from its parts (holder side). */
export function buildCredentialInput(args: BuildInputArgs): CredentialCircuitInput {
  const { credential: c, issuerProof, revocationProof, sanctioned } = args;
  if (commitment(args.eddsa, args.subjectSecret) !== c.fields.subjectCommitment) {
    throw new Error("subject secret does not open the credential's subjectCommitment");
  }
  return {
    currentDate: args.currentDate,
    issuerRoot: issuerProof.root,
    revocationRoot: revocationProof.root,
    sanctioned,
    appScope: args.appScope,
    recipient: args.recipient,

    subjectSecret: args.subjectSecret,
    birthdate: c.fields.birthdate,
    countryCode: c.fields.countryCode,
    accredited: c.fields.accredited,
    expiry: c.fields.expiry,
    credentialId: c.fields.credentialId,

    issuerAx: c.issuerAx,
    issuerAy: c.issuerAy,
    sigS: c.sigS,
    sigR8x: c.sigR8x,
    sigR8y: c.sigR8y,

    issuerPathElements: issuerProof.pathElements,
    issuerPathIndices: issuerProof.pathIndices,

    revSiblings: revocationProof.siblings,
    revOldKey: revocationProof.oldKey,
    revOldValue: revocationProof.oldValue,
    revIsOld0: revocationProof.isOld0,
  };
}
