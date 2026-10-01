// SPDX-License-Identifier: MIT
// Node-side software passkey: WebCrypto P-256 keys producing real WebAuthn assertion structures.
import { webcrypto } from 'node:crypto'
import { concat, encodeAbiParameters, sha256, toBytes, toHex, type Hex } from 'viem'

import {
  base64UrlEncode,
  bytesToBigInt,
  clientDataIndices,
  FLAG_UP,
  FLAG_UV,
  normalizeLowS,
  p1363ToRawSignature,
} from '../../src/webauthn.ts'

export interface SoftPasskey {
  readonly x: bigint
  readonly y: bigint
  readonly rpId: string
  readonly rpIdHash: Hex
  /** Signs `challenge` as a WebAuthn `get` assertion and returns the account signature (type byte 0x00 + ABI). */
  sign(challenge: Hex, options?: { origin?: string; rpId?: string }): Promise<Hex>
}

export function encodeWebAuthnSignature(fields: {
  r: bigint
  s: bigint
  challengeIndex: number
  typeIndex: number
  authenticatorData: Hex
  clientDataJSON: string
}): Hex {
  const body = encodeAbiParameters(
    [
      { type: 'bytes32' },
      { type: 'bytes32' },
      { type: 'uint256' },
      { type: 'uint256' },
      { type: 'bytes' },
      { type: 'string' },
    ],
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

export async function createSoftPasskey(rpId = 'localhost'): Promise<SoftPasskey> {
  const keyPair = await webcrypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify'])
  const raw = new Uint8Array(await webcrypto.subtle.exportKey('raw', keyPair.publicKey))
  const x = bytesToBigInt(raw.slice(1, 33))
  const y = bytesToBigInt(raw.slice(33, 65))
  let counter = 0
  return {
    x,
    y,
    rpId,
    rpIdHash: sha256(toBytes(rpId)),
    async sign(challenge, options = {}) {
      const signRpId = options.rpId ?? rpId
      const origin = options.origin ?? `http://${signRpId}`
      counter += 1
      const authenticatorData = concat([
        sha256(toBytes(signRpId)),
        toHex(FLAG_UP | FLAG_UV, { size: 1 }),
        toHex(counter, { size: 4 }),
      ])
      const clientDataJSON = JSON.stringify({
        type: 'webauthn.get',
        challenge: base64UrlEncode(toBytes(challenge)),
        origin,
        crossOrigin: false,
      })
      const message = concat([authenticatorData, sha256(toBytes(clientDataJSON))])
      // WebCrypto hashes the message with SHA-256 itself and returns r || s (IEEE P1363).
      const signature = new Uint8Array(
        await webcrypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, keyPair.privateKey, toBytes(message)),
      )
      const { r, s } = p1363ToRawSignature(signature)
      const { challengeIndex, typeIndex } = clientDataIndices(clientDataJSON)
      return encodeWebAuthnSignature({ r, s: normalizeLowS(s), challengeIndex, typeIndex, authenticatorData, clientDataJSON })
    },
  }
}
