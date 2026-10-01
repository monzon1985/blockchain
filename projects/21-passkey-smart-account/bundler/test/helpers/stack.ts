// SPDX-License-Identifier: MIT
// Spins up anvil (osaka) + EntryPoint v0.9 + contracts + bundler-lite on random ports for integration tests.
import {
  concat,
  encodeAbiParameters,
  encodeFunctionData,
  getAddress,
  numberToHex,
  parseAbi,
  parseAbiParameters,
  toHex,
  type Address,
  type Hex,
  type PublicClient,
  type WalletClient,
} from 'viem'
import { formatUserOperationRequest, getUserOperationHash, type UserOperation } from 'viem/account-abstraction'

import { BundlerLite } from '../../src/bundler.ts'
import { startAnvil, type AnvilInstance } from '../../src/devnet/anvil.ts'
import { artifacts } from '../../src/devnet/artifacts.ts'
import { clientsFor, deployLocalStack, type Deployment } from '../../src/devnet/deploy.ts'
import { startBundlerServer, type RunningServer } from '../../src/server.ts'

export const accountAbi = parseAbi([
  'struct Passkey { bytes32 qx; bytes32 qy; bytes32 rpIdHash; }',
  'struct InitParams { Passkey passkey; address[] guardians; uint8 threshold; }',
  'function execute(bytes32 mode, bytes executionData) payable',
  'function initialize(InitParams params)',
  'function initialized() view returns (bool)',
  'function passkey() view returns (Passkey)',
])
export const factoryAbi = parseAbi([
  'struct Passkey { bytes32 qx; bytes32 qy; bytes32 rpIdHash; }',
  'struct InitParams { Passkey passkey; address[] guardians; uint8 threshold; }',
  'function createAccount(InitParams params, bytes32 salt) returns (address)',
  'function getAddress(InitParams params, bytes32 salt) view returns (address)',
])
export const erc20Abi = parseAbi([
  'function approve(address spender, uint256 amount) returns (bool)',
  'function transfer(address to, uint256 amount) returns (bool)',
  'function balanceOf(address who) view returns (uint256)',
  'function mint(address to, uint256 amount)',
])
export const paymasterAbi = parseAbi([
  'function sponsorGuaranteeDigest(bytes32 userOpHash, uint48 validUntil, uint48 validAfter) view returns (bytes32)',
])

export const MODE_BATCH: Hex = '0x0100000000000000000000000000000000000000000000000000000000000000'
export const MAX_UINT256 = (1n << 256n) - 1n

export interface Call {
  readonly to: Address
  readonly value?: bigint
  readonly data?: Hex
}

export function encodeBatch(calls: readonly Call[]): Hex {
  const executionData = encodeAbiParameters(parseAbiParameters('(address target, uint256 value, bytes callData)[]'), [
    calls.map((c) => ({ target: c.to, value: c.value ?? 0n, callData: c.data ?? '0x' })),
  ])
  return encodeFunctionData({ abi: accountAbi, functionName: 'execute', args: [MODE_BATCH, executionData] })
}

export interface Stack {
  readonly anvil: AnvilInstance
  readonly server: RunningServer
  readonly bundler: BundlerLite
  readonly deployment: Deployment
  readonly publicClient: PublicClient
  readonly walletClient: WalletClient
  stop(): Promise<void>
}

export async function startStack(): Promise<Stack> {
  const anvil = await startAnvil()
  try {
    const deployment = await deployLocalStack(anvil.rpcUrl)
    const { publicClient, walletClient } = clientsFor(anvil.rpcUrl)
    const bundler = new BundlerLite({
      publicClient,
      walletClient,
      bundlerAccount: deployment.bundler,
      entryPoint: deployment.entryPoint,
      simulationsCode: artifacts.entryPointSimulations().deployedBytecode,
    })
    const server = await startBundlerServer(bundler, 0)
    return {
      anvil,
      server,
      bundler,
      deployment,
      publicClient,
      walletClient,
      async stop() {
        await server.close()
        await anvil.stop()
      },
    }
  } catch (error) {
    await anvil.stop()
    throw error
  }
}

export class RpcFailure extends Error {
  readonly code: number
  readonly data: unknown
  constructor(code: number, message: string, data: unknown) {
    super(`${code}: ${message}`)
    this.code = code
    this.data = data
  }
}

let nextId = 1
export async function rpc<T = unknown>(url: string, method: string, params: unknown[] = []): Promise<T> {
  const response = await fetch(url, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: nextId++, method, params }),
  })
  const body = (await response.json()) as { result?: T; error?: { code: number; message: string; data?: unknown } }
  if (body.error !== undefined) throw new RpcFailure(body.error.code, body.error.message, body.error.data)
  return body.result as T
}

export type Op = UserOperation<'0.9'>

export function toRpc(op: Op): Record<string, unknown> {
  return formatUserOperationRequest(op)
}

export function hashOp(op: Op, entryPoint: Address, chainId = 31337): Hex {
  return getUserOperationHash({ chainId, entryPointAddress: entryPoint, entryPointVersion: '0.9', userOperation: op })
}

/** Paymaster data for the sponsor-guaranteed mode: mode byte, validUntil, validAfter (uint48 each). */
export function guaranteedPaymasterData(validUntil: number, validAfter = 0): Hex {
  return concat(['0x01', toHex(validUntil, { size: 6 }), toHex(validAfter, { size: 6 })])
}

/** Asks the sponsor (an unlocked anvil account) to sign the guarantee for `userOpHash`. */
export async function sponsorSignature(stack: Stack, userOpHash: Hex, validUntil: number, validAfter = 0): Promise<Hex> {
  return stack.walletClient.signTypedData({
    account: stack.deployment.sponsor,
    domain: { name: 'TokenPaymaster', version: '1', chainId: 31337, verifyingContract: stack.deployment.paymaster },
    types: {
      SponsorGuarantee: [
        { name: 'userOpHash', type: 'bytes32' },
        { name: 'validUntil', type: 'uint48' },
        { name: 'validAfter', type: 'uint48' },
      ],
    },
    primaryType: 'SponsorGuarantee',
    message: { userOpHash, validUntil, validAfter },
  })
}

export async function mintUsd(stack: Stack, to: Address, amount: bigint): Promise<void> {
  const hash = await stack.walletClient.writeContract({
    address: stack.deployment.testUsd,
    abi: erc20Abi,
    functionName: 'mint',
    args: [to, amount],
    account: stack.deployment.admin,
    chain: stack.walletClient.chain,
  })
  await stack.publicClient.waitForTransactionReceipt({ hash })
}

export async function nonceOf(stack: Stack, sender: Address): Promise<bigint> {
  return stack.publicClient.readContract({
    address: stack.deployment.entryPoint,
    abi: parseAbi(['function getNonce(address sender, uint192 key) view returns (uint256)']),
    functionName: 'getNonce',
    args: [sender, 0n],
  })
}

export function hex(v: bigint): Hex {
  return numberToHex(v)
}

export { getAddress }
