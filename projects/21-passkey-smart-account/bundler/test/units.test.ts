// SPDX-License-Identifier: MIT
// Unit tests: RPC user operation parsing, calldata gas, WebAuthn helpers and the authorization signing policy.
import { webcrypto } from 'node:crypto'
import { describe, expect, it } from 'vitest'
import { toHex, type Hex } from 'viem'

import { calldataGas, checkValidityWindow, parseValidationData, VALIDITY_MARGIN_SECONDS } from '../src/bundler.ts'
import { loadArtifact } from '../src/devnet/artifacts.ts'
import { RpcError, RpcErrorCode } from '../src/errors.ts'
import { checkAuthorizationPolicy } from '../src/policy/authorization.ts'
import { EIP7702_MARKER, packUserOperation, parseRpcUserOperation, toRpcUserOperation } from '../src/userop.ts'
import {
  base64UrlDecode,
  base64UrlEncode,
  bytesToHex,
  clientDataIndices,
  derToRawSignature,
  hexToBytes,
  normalizeLowS,
  P256_N,
  p256PublicKeyFromSpki,
} from '../src/webauthn.ts'

const SENDER = '0x1111111111111111111111111111111111111111'

function baseRpcOp(extra: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    sender: SENDER,
    nonce: '0x0',
    callData: '0x',
    callGasLimit: '0x1',
    verificationGasLimit: '0x2',
    preVerificationGas: '0x3',
    maxFeePerGas: '0x4',
    maxPriorityFeePerGas: '0x5',
    signature: '0x00',
    ...extra,
  }
}

describe('parseRpcUserOperation', () => {
  it('parses quantities and round-trips to RPC form', () => {
    const op = parseRpcUserOperation(
      baseRpcOp({
        paymaster: '0x2222222222222222222222222222222222222222',
        paymasterData: '0x00',
        paymasterVerificationGasLimit: '0x10',
        paymasterPostOpGasLimit: '0x20',
        paymasterSignature: '0xabcd',
      }),
    )
    expect(op.callGasLimit).toBe(1n)
    expect(op.paymasterPostOpGasLimit).toBe(0x20n)
    const back = toRpcUserOperation(op)
    expect(back['paymasterSignature']).toBe('0xabcd')
    expect(back['maxPriorityFeePerGas']).toBe('0x5')
  })

  it('normalizes the short 0x7702 marker to the padded 20-byte form used in initCode', () => {
    const op = parseRpcUserOperation(baseRpcOp({ factory: '0x7702', factoryData: '0x' }))
    expect(op.factory).toBe(EIP7702_MARKER)
    expect(packUserOperation(op).initCode).toBe(EIP7702_MARKER)
  })

  it('parses eip7702Auth', () => {
    const op = parseRpcUserOperation(
      baseRpcOp({
        eip7702Auth: { address: SENDER, chainId: '0x7a69', nonce: '0x3', r: '0x01', s: '0x02', yParity: '0x1' },
      }),
    )
    expect(op.authorization).toEqual({ address: SENDER, chainId: 31337, nonce: 3, r: '0x01', s: '0x02', yParity: 1 })
    expect(toRpcUserOperation(op)['eip7702Auth']).toMatchObject({ chainId: '0x7a69', yParity: '0x1' })
  })

  it.each([
    ['not an object', 'x'],
    ['missing sender', { ...baseRpcOp(), sender: undefined }],
    ['non-hex nonce', baseRpcOp({ nonce: 12 })],
    ['bad address', baseRpcOp({ sender: '0x1234' })],
    ['missing signature', { ...baseRpcOp(), signature: undefined }],
    ['bad eip7702Auth', baseRpcOp({ eip7702Auth: 'nope' })],
  ])('rejects %s with -32602', (_name, input) => {
    try {
      parseRpcUserOperation(input)
      throw new Error('should have thrown')
    } catch (error) {
      expect(error).toBeInstanceOf(RpcError)
      expect((error as RpcError).code).toBe(RpcErrorCode.InvalidParams)
    }
  })

  it('lets estimation omit gas fields and the signature', () => {
    const op = parseRpcUserOperation({ sender: SENDER, nonce: '0x0', callData: '0x' }, true)
    expect(op.callGasLimit).toBe(0n)
    expect(op.signature).toBe('0x')
  })
})

describe('calldataGas (EIP-2028)', () => {
  it('charges 4 per zero byte and 16 per non-zero byte', () => {
    expect(calldataGas('0x')).toBe(0n)
    expect(calldataGas('0x00ff00')).toBe(24n)
  })
})

describe('validation data and validity windows (EntryPoint v0.9 semantics)', () => {
  const pack = (sigFailed: boolean, validUntil: bigint, validAfter: bigint): bigint =>
    (sigFailed ? 1n : 0n) | (validUntil << 160n) | (validAfter << 208n)
  const head = { timestamp: 1_000_000n, number: 500n }

  function outOfRange(fn: () => void): RpcError {
    try {
      fn()
    } catch (error) {
      expect(error).toBeInstanceOf(RpcError)
      expect((error as RpcError).code).toBe(RpcErrorCode.OutOfTimeRange)
      return error as RpcError
    }
    throw new Error('expected -32503')
  }

  it('parses validUntil 0 as "no expiry" and keeps the signature bit apart', () => {
    expect(parseValidationData(pack(true, 0n, 7n))).toEqual({
      aggregator: 1n,
      validAfter: 7n,
      validUntil: (1n << 48n) - 1n,
      blockRange: false,
    })
  })

  it('accepts no window, and a window that contains the next block with margin', () => {
    checkValidityWindow(0n, head, 'account')
    checkValidityWindow(pack(false, head.timestamp + 3600n, head.timestamp - 10n), head, 'account')
    checkValidityWindow(pack(false, head.timestamp + VALIDITY_MARGIN_SECONDS, head.timestamp), head, 'paymaster')
  })

  it('rejects an operation that is not due yet, e.g. a frozen account (validAfter = frozenUntil)', () => {
    const e = outOfRange(() => checkValidityWindow(pack(false, 0n, head.timestamp + 7n * 86_400n), head, 'account'))
    expect(e.message).toContain('not due')
  })

  it('rejects an expired window and one that expires within the margin', () => {
    outOfRange(() => checkValidityWindow(pack(false, head.timestamp - 1n, 0n), head, 'paymaster'))
    outOfRange(() => checkValidityWindow(pack(false, head.timestamp + VALIDITY_MARGIN_SECONDS - 1n, 0n), head, 'paymaster'))
  })

  it('switches to block numbers when both bounds carry the block-range flag', () => {
    const flag = 0x800000000000n
    const parsed = parseValidationData(pack(false, flag | 600n, flag | 400n))
    expect(parsed).toMatchObject({ blockRange: true, validAfter: 400n, validUntil: 600n })
    checkValidityWindow(pack(false, flag | 600n, flag | 400n), head, 'account')
    outOfRange(() => checkValidityWindow(pack(false, flag | 600n, flag | 501n), head, 'account'))
    outOfRange(() => checkValidityWindow(pack(false, flag | 501n, flag | 1n), head, 'account'))
  })
})

describe('WebAuthn helpers', () => {
  it('base64url round-trips without padding', () => {
    const bytes = new Uint8Array([0xfb, 0xff, 0x00, 0x01])
    const text = base64UrlEncode(bytes)
    expect(text).not.toContain('=')
    expect(text).not.toContain('+')
    expect(base64UrlDecode(text)).toEqual(bytes)
  })

  it('decodes DER signatures with and without leading zero bytes', () => {
    // SEQUENCE { INTEGER 0x00ff.., INTEGER 0x01 }
    const der = hexToBytes('0x3007020200ff020101')
    expect(derToRawSignature(der)).toEqual({ r: 0xffn, s: 1n })
  })

  it('normalizes high-s to low-s', () => {
    expect(normalizeLowS(P256_N - 1n)).toBe(1n)
    expect(normalizeLowS(5n)).toBe(5n)
  })

  it('locates challenge and type in clientDataJSON', () => {
    const json = '{"type":"webauthn.get","challenge":"abc","origin":"http://localhost"}'
    expect(clientDataIndices(json)).toEqual({ typeIndex: 1, challengeIndex: 23 })
    expect(() => clientDataIndices('{}')).toThrow()
  })

  it('extracts the P-256 point from a WebCrypto SPKI export', async () => {
    const pair = await webcrypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign'])
    const spki = new Uint8Array(await webcrypto.subtle.exportKey('spki', pair.publicKey))
    const raw = new Uint8Array(await webcrypto.subtle.exportKey('raw', pair.publicKey))
    const { x, y } = p256PublicKeyFromSpki(spki)
    expect(toHex(x, { size: 32 })).toBe(bytesToHex(raw.slice(1, 33)))
    expect(toHex(y, { size: 32 })).toBe(bytesToHex(raw.slice(33, 65)))
  })
})

describe('EIP-7702 authorization signing policy', () => {
  const passkeyCode = loadArtifact('PasskeyAccount.sol', 'PasskeyAccount').deployedBytecode
  const sweeperCode = loadArtifact('ClassifierCorpus.sol', 'SweeperReceiveForward').deployedBytecode
  const target = '0x3333333333333333333333333333333333333333'

  it('allows a chain-specific authorization to a safe implementation', () => {
    const r = checkAuthorizationPolicy({ chainId: 31337, address: target, nonce: 0 }, { currentChainId: 31337, targetCode: passkeyCode })
    expect(r.allowed).toBe(true)
    expect(r.reasons).toEqual([])
  })

  it('never signs chainId 0 (hazard H03)', () => {
    const r = checkAuthorizationPolicy({ chainId: 0, address: target, nonce: 0 }, { currentChainId: 31337, targetCode: passkeyCode })
    expect(r.allowed).toBe(false)
    expect(r.reasons[0]).toContain('chainId 0')
  })

  it('refuses a chain id other than the connected one', () => {
    const r = checkAuthorizationPolicy({ chainId: 1, address: target, nonce: 0 }, { currentChainId: 31337, targetCode: passkeyCode })
    expect(r.allowed).toBe(false)
  })

  it('refuses sweeper-like targets even if they are on the trusted list', () => {
    const r = checkAuthorizationPolicy(
      { chainId: 31337, address: target, nonce: 0 },
      { currentChainId: 31337, targetCode: sweeperCode, trustedImplementations: new Set([target]) },
    )
    expect(r.allowed).toBe(false)
    expect(r.classification.verdict).toBe('malicious')
  })

  it('needs an explicit trust entry for review-level targets', () => {
    const empty: Hex = '0x'
    const denied = checkAuthorizationPolicy({ chainId: 31337, address: target, nonce: 0 }, { currentChainId: 31337, targetCode: empty })
    expect(denied.allowed).toBe(false)
    const trusted = checkAuthorizationPolicy(
      { chainId: 31337, address: target, nonce: 0 },
      { currentChainId: 31337, targetCode: empty, trustedImplementations: new Set([target]) },
    )
    expect(trusted.allowed).toBe(true)
  })

  it('passes trusted callers to the classifier: an EntryPoint-guarded executor is owner-controlled only if trusted', () => {
    // CALLER PUSH20 ep EQ PUSH1 0x1b JUMPI STOP | 0x1b: JUMPDEST, CALL(gas, calldata[4:], calldata[36:]) STOP
    const ep = '5fbdb2315678afecb367f032d93f642f64180aa3'
    const code = `0x3373${ep}14601b57005b5f5f5f5f6024356004355af100`
    const request = { chainId: 31337, address: target, nonce: 0 }
    const unknown = checkAuthorizationPolicy(request, { currentChainId: 31337, targetCode: code })
    expect(unknown.allowed).toBe(false)
    expect(unknown.classification.findings[0]?.guard).toBe('foreign')
    const trusted = checkAuthorizationPolicy(request, { currentChainId: 31337, targetCode: code, trustedCallers: [`0x${ep}`] })
    expect(trusted.allowed).toBe(true)
  })

  it('rejects a negative or fractional nonce', () => {
    const r = checkAuthorizationPolicy({ chainId: 31337, address: target, nonce: -1 }, { currentChainId: 31337, targetCode: passkeyCode })
    expect(r.allowed).toBe(false)
  })
})
