// SPDX-License-Identifier: MIT
// Browser WebAuthn: create an ES256 (P-256) passkey and sign user operation hashes with it.
import { concat, encodeAbiParameters, sha256, toBytes, toHex, type Hex } from 'viem'

import { assertionFields, base64UrlDecode, base64UrlEncode, p256PublicKeyFromSpki } from './shared'

/** What the wallet remembers about a passkey. The private key never leaves the authenticator. */
export interface StoredPasskey {
  readonly credentialId: string
  readonly label: string
  readonly rpId: string
  readonly qx: Hex
  readonly qy: Hex
  readonly rpIdHash: Hex
}

/** On-chain representation, as the account's `Passkey` struct. */
export function toOnchainPasskey(key: StoredPasskey): { qx: Hex; qy: Hex; rpIdHash: Hex } {
  return { qx: key.qx, qy: key.qy, rpIdHash: key.rpIdHash }
}

function randomBytes(n: number): Uint8Array<ArrayBuffer> {
  const out = new Uint8Array(new ArrayBuffer(n))
  crypto.getRandomValues(out)
  return out
}

function buffer(bytes: Uint8Array): ArrayBuffer {
  const copy = new Uint8Array(new ArrayBuffer(bytes.length))
  copy.set(bytes)
  return copy.buffer
}

/** Registers a new discoverable ES256 credential bound to the current host (the RP id). */
export async function createPasskey(label: string): Promise<StoredPasskey> {
  const rpId = window.location.hostname
  const credential = (await navigator.credentials.create({
    publicKey: {
      rp: { id: rpId, name: 'Passkey Smart Account' },
      user: { id: randomBytes(16), name: label, displayName: label },
      challenge: randomBytes(32),
      pubKeyCredParams: [{ type: 'public-key', alg: -7 }],
      authenticatorSelection: { residentKey: 'required', userVerification: 'required' },
      attestation: 'none',
      timeout: 60_000,
    },
  })) as PublicKeyCredential | null
  if (credential === null) throw new Error('passkey creation was cancelled')
  const response = credential.response as AuthenticatorAttestationResponse
  const spki = response.getPublicKey()
  if (spki === null) throw new Error('authenticator did not return a public key')
  const { x, y } = p256PublicKeyFromSpki(new Uint8Array(spki))
  return {
    credentialId: base64UrlEncode(new Uint8Array(credential.rawId)),
    label,
    rpId,
    qx: toHex(x, { size: 32 }),
    qy: toHex(y, { size: 32 }),
    rpIdHash: sha256(toBytes(rpId)),
  }
}

/**
 * Runs a WebAuthn `get` ceremony whose challenge is `hash` and returns the account signature:
 * `0x00 || abi.encode(r, s, challengeIndex, typeIndex, authenticatorData, clientDataJSON)`.
 */
export async function signWithPasskey(key: StoredPasskey, hash: Hex): Promise<Hex> {
  const credential = (await navigator.credentials.get({
    publicKey: {
      challenge: buffer(toBytes(hash)),
      rpId: key.rpId,
      allowCredentials: [{ type: 'public-key', id: buffer(base64UrlDecode(key.credentialId)) }],
      userVerification: 'required',
      timeout: 60_000,
    },
  })) as PublicKeyCredential | null
  if (credential === null) throw new Error('signature was cancelled')
  const response = credential.response as AuthenticatorAssertionResponse
  const fields = assertionFields(
    new Uint8Array(response.authenticatorData),
    new Uint8Array(response.clientDataJSON),
    new Uint8Array(response.signature),
  )
  const body = encodeAbiParameters(
    [{ type: 'bytes32' }, { type: 'bytes32' }, { type: 'uint256' }, { type: 'uint256' }, { type: 'bytes' }, { type: 'string' }],
    [
      toHex(fields.r, { size: 32 }),
      toHex(fields.s, { size: 32 }),
      BigInt(fields.challengeIndex),
      BigInt(fields.typeIndex),
      fields.authenticatorData,
      fields.clientDataJSON,
    ],
  )
  return concat(['0x00', body])
}
