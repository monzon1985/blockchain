// SPDX-License-Identifier: MIT
//
// JSON file formats exchanged between the holder, issuer, governor and prover
// CLIs, plus conversions to the in-memory types.
import { type SignedCredential } from "./issuer.ts";

/** Issuer key file (PRIVATE: contains the signing seed). */
export interface IssuerKeyFile {
  seed: string;
  ax: string;
  ay: string;
  issuerLeaf: string;
}

/** Holder secret file (PRIVATE: the secret links every registration). */
export interface HolderFile {
  subjectSecret: string;
  subjectCommitment: string;
}

/** Signed credential, as the issuer hands it back to the holder. */
export interface CredentialFile {
  fields: {
    subjectCommitment: string;
    birthdate: string;
    countryCode: string;
    accredited: string;
    expiry: string;
    credentialId: string;
  };
  issuerAx: string;
  issuerAy: string;
  sigS: string;
  sigR8x: string;
  sigR8y: string;
  messageHash: string;
}

/** Serialise a signed credential. */
export function credentialToFile(c: SignedCredential): CredentialFile {
  return {
    fields: {
      subjectCommitment: c.fields.subjectCommitment.toString(),
      birthdate: c.fields.birthdate.toString(),
      countryCode: c.fields.countryCode.toString(),
      accredited: c.fields.accredited.toString(),
      expiry: c.fields.expiry.toString(),
      credentialId: c.fields.credentialId.toString(),
    },
    issuerAx: c.issuerAx.toString(),
    issuerAy: c.issuerAy.toString(),
    sigS: c.sigS.toString(),
    sigR8x: c.sigR8x.toString(),
    sigR8y: c.sigR8y.toString(),
    messageHash: c.messageHash.toString(),
  };
}

/** Parse a signed credential file. */
export function credentialFromFile(f: CredentialFile): SignedCredential {
  return {
    fields: {
      subjectCommitment: BigInt(f.fields.subjectCommitment),
      birthdate: BigInt(f.fields.birthdate),
      countryCode: BigInt(f.fields.countryCode),
      accredited: BigInt(f.fields.accredited),
      expiry: BigInt(f.fields.expiry),
      credentialId: BigInt(f.fields.credentialId),
    },
    issuerAx: BigInt(f.issuerAx),
    issuerAy: BigInt(f.issuerAy),
    sigS: BigInt(f.sigS),
    sigR8x: BigInt(f.sigR8x),
    sigR8y: BigInt(f.sigR8y),
    messageHash: BigInt(f.messageHash),
  };
}
