// SPDX-License-Identifier: MIT
// Dependency-free WebAuthn helpers shared by the Node tests and the browser wallet.

/** Order of the P-256 group. */
export const P256_N = 0xffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551n

/** Authenticator data flag bits (WebAuthn L2 §6.1). */
export const FLAG_UP = 0x01
export const FLAG_UV = 0x04

export function base64UrlEncode(bytes: Uint8Array): string {
  let binary = ''
  for (const b of bytes) binary += String.fromCharCode(b)
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
}

export function base64UrlDecode(text: string): Uint8Array {
  const padded = text.replace(/-/g, '+').replace(/_/g, '/') + '='.repeat((4 - (text.length % 4)) % 4)
  const binary = atob(padded)
  const out = new Uint8Array(binary.length)
  for (let i = 0; i < binary.length; i++) out[i] = binary.charCodeAt(i)
  return out
}

export function bytesToBigInt(bytes: Uint8Array): bigint {
  let v = 0n
  for (const b of bytes) v = (v << 8n) | BigInt(b)
  return v
}

export function hexToBytes(hex: string): Uint8Array {
  const clean = hex.startsWith('0x') ? hex.slice(2) : hex
  const out = new Uint8Array(clean.length / 2)
  for (let i = 0; i < out.length; i++) out[i] = Number.parseInt(clean.slice(2 * i, 2 * i + 2), 16)
  return out
}

export function bytesToHex(bytes: Uint8Array): `0x${string}` {
  let s = '0x'
  for (const b of bytes) s += b.toString(16).padStart(2, '0')
  return s as `0x${string}`
}

/** Flips a high-s P-256 signature to its low-s twin (the account rejects high-s, like OpenZeppelin's P256). */
export function normalizeLowS(s: bigint): bigint {
  return s > P256_N / 2n ? P256_N - s : s
}

/** Decodes an ASN.1 DER ECDSA signature (what browsers return) into (r, s). */
export function derToRawSignature(der: Uint8Array): { r: bigint; s: bigint } {
  let offset = 0
  const expect = (tag: number): void => {
    if (der[offset] !== tag) throw new Error(`DER: expected tag 0x${tag.toString(16)} at ${offset}`)
    offset++
  }
  const readLength = (): number => {
    const first = der[offset++] ?? 0
    if (first < 0x80) return first
    const n = first & 0x7f
    let len = 0
    for (let i = 0; i < n; i++) len = (len << 8) | (der[offset++] ?? 0)
    return len
  }
  expect(0x30)
  readLength()
  expect(0x02)
  const rLen = readLength()
  const r = bytesToBigInt(der.slice(offset, offset + rLen))
  offset += rLen
  expect(0x02)
  const sLen = readLength()
  const s = bytesToBigInt(der.slice(offset, offset + sLen))
  return { r, s }
}

/** Splits an IEEE P1363 signature (WebCrypto's format: r || s, 32 bytes each). */
export function p1363ToRawSignature(sig: Uint8Array): { r: bigint; s: bigint } {
  if (sig.length !== 64) throw new Error('P1363 signature must be 64 bytes')
  return { r: bytesToBigInt(sig.slice(0, 32)), s: bytesToBigInt(sig.slice(32)) }
}

/** Positions the on-chain verifier needs: where `"challenge":"` and `"type":"` start in clientDataJSON. */
export function clientDataIndices(clientDataJSON: string): { challengeIndex: number; typeIndex: number } {
  const challengeIndex = clientDataJSON.indexOf('"challenge":"')
  const typeIndex = clientDataJSON.indexOf('"type":"')
  if (challengeIndex < 0 || typeIndex < 0) throw new Error('clientDataJSON lacks challenge or type')
  return { challengeIndex, typeIndex }
}

/**
 * Extracts (x, y) from the DER SubjectPublicKeyInfo that `AuthenticatorAttestationResponse.getPublicKey()` returns
 * for an ES256 credential: the uncompressed point `04 || x || y` is the last 65 bytes.
 */
export function p256PublicKeyFromSpki(spki: Uint8Array): { x: bigint; y: bigint } {
  if (spki.length < 65 || spki[spki.length - 65] !== 0x04) throw new Error('not an uncompressed P-256 SPKI key')
  const point = spki.slice(spki.length - 64)
  return { x: bytesToBigInt(point.slice(0, 32)), y: bytesToBigInt(point.slice(32)) }
}

/** The fields of OpenZeppelin's `WebAuthn.WebAuthnAuth`, ready for ABI encoding. */
export interface WebAuthnAssertionFields {
  readonly r: bigint
  readonly s: bigint
  readonly challengeIndex: number
  readonly typeIndex: number
  readonly authenticatorData: `0x${string}`
  readonly clientDataJSON: string
}

/** Normalizes a browser assertion (DER signature) into the on-chain encoding fields. */
export function assertionFields(
  authenticatorData: Uint8Array,
  clientDataJSONBytes: Uint8Array,
  derSignature: Uint8Array,
): WebAuthnAssertionFields {
  const clientDataJSON = new TextDecoder().decode(clientDataJSONBytes)
  const { r, s } = derToRawSignature(derSignature)
  const { challengeIndex, typeIndex } = clientDataIndices(clientDataJSON)
  return { r, s: normalizeLowS(s), challengeIndex, typeIndex, authenticatorData: bytesToHex(authenticatorData), clientDataJSON }
}
