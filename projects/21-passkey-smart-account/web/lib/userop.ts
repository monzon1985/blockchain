// SPDX-License-Identifier: MIT
// Builds, estimates, co-signs and submits ERC-4337 v0.9 user operations through bundler-lite (via /api/bundler).
import {
  concat,
  encodeAbiParameters,
  encodeFunctionData,
  parseAbiParameters,
  sha256,
  toBytes,
  toHex,
  type Address,
  type Hex,
  type PublicClient,
  type SignedAuthorization,
} from 'viem'
import { formatUserOperationRequest, getUserOperationHash, type UserOperation } from 'viem/account-abstraction'

import { accountAbi, entryPointReadAbi, factoryAbi } from './abis'
import type { WalletConfig } from './config'
import { base64UrlEncode } from './shared'

export type Op = UserOperation<'0.9'>

export interface Call {
  readonly to: Address
  readonly value?: bigint
  readonly data?: Hex
}

export interface UserOpReceipt {
  readonly userOpHash: Hex
  readonly success: boolean
  readonly actualGasCost: Hex
  readonly receipt: { transactionHash: Hex }
}

/** ERC-7821 single-batch mode (call type 0x01, default exec type). */
const MODE_BATCH: Hex = '0x0100000000000000000000000000000000000000000000000000000000000000'
const STUB_PAYMASTER_SIGNATURE: Hex = `0x${'11'.repeat(65)}`
/** Headroom on preVerificationGas: browsers may add extra keys to clientDataJSON (a longer signature). */
const PVG_BUFFER = 5_000n
const GUARANTEED_PM_VERIFICATION_FLOOR = 150_000n

export function encodeBatch(calls: readonly Call[]): Hex {
  const executionData = encodeAbiParameters(parseAbiParameters('(address target, uint256 value, bytes callData)[]'), [
    calls.map((c) => ({ target: c.to, value: c.value ?? 0n, callData: c.data ?? '0x' })),
  ])
  return encodeFunctionData({ abi: accountAbi, functionName: 'execute', args: [MODE_BATCH, executionData] })
}

export function initParams(key: { qx: Hex; qy: Hex; rpIdHash: Hex }, guardians: readonly Address[] = [], threshold = 0) {
  return { passkey: key, guardians: [...guardians], threshold }
}

export const ACCOUNT_SALT: Hex = toHex(0, { size: 32 })

export async function counterfactualAddress(
  client: PublicClient,
  cfg: WalletConfig,
  key: { qx: Hex; qy: Hex; rpIdHash: Hex },
): Promise<Address> {
  return client.readContract({
    address: cfg.factory,
    abi: factoryAbi,
    functionName: 'getAddress',
    args: [initParams(key), ACCOUNT_SALT],
  })
}

export function factoryInit(cfg: WalletConfig, key: { qx: Hex; qy: Hex; rpIdHash: Hex }): { factory: Address; factoryData: Hex } {
  return {
    factory: cfg.factory,
    factoryData: encodeFunctionData({ abi: factoryAbi, functionName: 'createAccount', args: [initParams(key), ACCOUNT_SALT] }),
  }
}

let rpcId = 1

export class BundlerRpcError extends Error {
  readonly code: number
  constructor(code: number, message: string) {
    super(`${message} (${code})`)
    this.code = code
  }
}

export async function bundlerRpc<T>(method: string, params: unknown[]): Promise<T> {
  const response = await fetch('/api/bundler', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: rpcId++, method, params }),
  })
  const body = (await response.json()) as { result?: T; error?: { code: number; message: string } }
  if (body.error !== undefined) throw new BundlerRpcError(body.error.code, body.error.message)
  return body.result as T
}

/** A well-formed WebAuthn signature with dummy values, for gas estimation without prompting the user. */
export function stubWebAuthnSignature(origin: string, rpId: string): Hex {
  const clientDataJSON = JSON.stringify({
    type: 'webauthn.get',
    challenge: base64UrlEncode(new Uint8Array(32).fill(0x5a)),
    origin,
    crossOrigin: false,
  })
  const authenticatorData = concat([sha256(toBytes(rpId)), '0x05', '0x00000001'])
  const body = encodeAbiParameters(
    [{ type: 'bytes32' }, { type: 'bytes32' }, { type: 'uint256' }, { type: 'uint256' }, { type: 'bytes' }, { type: 'string' }],
    [toHex(0x1234n, { size: 32 }), toHex(0x5678n, { size: 32 }), 23n, 1n, authenticatorData, clientDataJSON],
  )
  return concat(['0x00', body])
}

/** Stub for the EOA signer (type byte + 65 bytes that do not recover to the sender). */
export const STUB_EOA_SIGNATURE: Hex = `0x01${'ff'.repeat(64)}1b`

export interface SendParams {
  readonly client: PublicClient
  readonly cfg: WalletConfig
  readonly sender: Address
  readonly callData: Hex
  readonly factory?: { factory: Address; factoryData: Hex }
  readonly authorization?: SignedAuthorization
  /** `user`: the sender pays TestUSD from its allowance. `guaranteed`: the demo sponsor fronts the first op. */
  readonly paymasterMode: 'user' | 'guaranteed'
  readonly stubSignature: Hex
  readonly sign: (userOpHash: Hex) => Promise<Hex>
  readonly onStage?: (stage: string) => void
}

async function sponsorGuarantee(userOpHash: Hex, validUntil: number): Promise<Hex> {
  const response = await fetch('/api/sponsor', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ userOpHash, validUntil, validAfter: 0 }),
  })
  if (!response.ok) throw new Error(`sponsor refused: ${await response.text()}`)
  return ((await response.json()) as { signature: Hex }).signature
}

export async function waitForReceipt(hash: Hex, timeoutMs = 60_000): Promise<UserOpReceipt> {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    const receipt = await bundlerRpc<UserOpReceipt | null>('eth_getUserOperationReceipt', [hash])
    if (receipt !== null) return receipt
    await new Promise((r) => setTimeout(r, 250))
  }
  throw new Error(`no receipt for ${hash}`)
}

/** Full pipeline: draft → estimate → (sponsor co-signature) → owner signature → send → receipt. */
export async function sendUserOperation(p: SendParams): Promise<UserOpReceipt> {
  const stage = p.onStage ?? (() => undefined)
  const nonce = await p.client.readContract({
    address: p.cfg.entryPoint,
    abi: entryPointReadAbi,
    functionName: 'getNonce',
    args: [p.sender, 0n],
  })
  const fees = await p.client.estimateFeesPerGas()
  const guaranteed = p.paymasterMode === 'guaranteed'
  // The guarantee window follows chain time (a devnet clock may run ahead of the wall clock).
  const latest = await p.client.getBlock({ blockTag: 'latest' })
  const validUntil = Number(latest.timestamp) + 3_600
  const draft: Op = {
    sender: p.sender,
    nonce,
    callData: p.callData,
    callGasLimit: 0n,
    verificationGasLimit: 0n,
    preVerificationGas: 0n,
    maxFeePerGas: fees.maxFeePerGas,
    maxPriorityFeePerGas: fees.maxPriorityFeePerGas,
    paymaster: p.cfg.paymaster,
    paymasterData: guaranteed
      ? concat(['0x01', toHex(validUntil, { size: 6 }), toHex(0, { size: 6 })])
      : '0x00',
    paymasterVerificationGasLimit: guaranteed ? GUARANTEED_PM_VERIFICATION_FLOOR : 0n,
    paymasterPostOpGasLimit: guaranteed ? 120_000n : 80_000n,
    signature: p.stubSignature,
    ...(p.factory ?? {}),
    ...(p.authorization === undefined ? {} : { authorization: p.authorization }),
    ...(guaranteed ? { paymasterSignature: STUB_PAYMASTER_SIGNATURE } : {}),
  } as Op

  stage('estimating gas')
  const gas = await bundlerRpc<Record<string, Hex>>('eth_estimateUserOperationGas', [
    formatUserOperationRequest(draft),
    p.cfg.entryPoint,
  ])
  const op: Op = {
    ...draft,
    preVerificationGas: BigInt(gas['preVerificationGas'] ?? '0x0') + PVG_BUFFER,
    verificationGasLimit: BigInt(gas['verificationGasLimit'] ?? '0x0'),
    callGasLimit: BigInt(gas['callGasLimit'] ?? '0x0'),
    paymasterVerificationGasLimit: BigInt(gas['paymasterVerificationGasLimit'] ?? '0x0'),
  }
  const userOpHash = getUserOperationHash({
    chainId: p.cfg.chainId,
    entryPointAddress: p.cfg.entryPoint,
    entryPointVersion: '0.9',
    userOperation: op,
  })
  if (guaranteed) {
    stage('requesting sponsor guarantee')
    op.paymasterSignature = await sponsorGuarantee(userOpHash, validUntil)
  }
  stage('waiting for signature')
  op.signature = await p.sign(userOpHash)
  stage('submitting to bundler')
  const hash = await bundlerRpc<Hex>('eth_sendUserOperation', [formatUserOperationRequest(op), p.cfg.entryPoint])
  stage('waiting for receipt')
  return waitForReceipt(hash)
}
