// SPDX-License-Identifier: MIT
import {
  createPublicClient,
  createWalletClient,
  defineChain,
  http,
  parseEther,
  type Abi,
  type Address,
  type Chain,
  type Hex,
  type PublicClient,
  type WalletClient,
} from 'viem'

import { artifacts } from './artifacts.ts'

/** Addresses and roles of a freshly deployed local stack. */
export interface Deployment {
  readonly chainId: number
  readonly entryPoint: Address
  readonly factory: Address
  readonly accountImplementation: Address
  readonly testUsd: Address
  readonly paymaster: Address
  /** Owner of TestUSD (faucet) and of the paymaster. Unlocked anvil account #0. */
  readonly admin: Address
  /** Submits `handleOps`. Unlocked anvil account #1. */
  readonly bundler: Address
  /** Signs paymaster guarantees. Unlocked anvil account #2. */
  readonly sponsor: Address
  /** Demo guardians. Unlocked anvil accounts #3..#5. */
  readonly guardians: readonly Address[]
}

/** 3000 TUSD per ETH, in 6-decimal token units per 1e18 wei. */
export const DEFAULT_TOKEN_PER_NATIVE = 3_000_000_000n

export function localChain(rpcUrl: string, chainId = 31337): Chain {
  return defineChain({
    id: chainId,
    name: 'Local anvil',
    nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
    rpcUrls: { default: { http: [rpcUrl] } },
  })
}

export function clientsFor(rpcUrl: string, chainId = 31337): { publicClient: PublicClient; walletClient: WalletClient } {
  const chain = localChain(rpcUrl, chainId)
  // Struct-log traces of validation (used by the ERC-7562 opcode checks) easily exceed viem's 10 MiB default.
  const transport = http(rpcUrl, { retryCount: 0, timeout: 120_000, maxResponseBodySize: 512 * 1024 * 1024 })
  return {
    publicClient: createPublicClient({ chain, transport }),
    walletClient: createWalletClient({ chain, transport }),
  }
}

async function deploy(
  publicClient: PublicClient,
  walletClient: WalletClient,
  from: Address,
  abi: Abi,
  bytecode: Hex,
  args: readonly unknown[],
): Promise<Address> {
  const hash = await walletClient.deployContract({ abi, bytecode, args, account: from, chain: walletClient.chain })
  const receipt = await publicClient.waitForTransactionReceipt({ hash })
  if (receipt.status !== 'success' || receipt.contractAddress == null) throw new Error('deployment failed')
  return receipt.contractAddress
}

async function send(
  publicClient: PublicClient,
  walletClient: WalletClient,
  from: Address,
  to: Address,
  abi: Abi,
  functionName: string,
  args: readonly unknown[],
  value = 0n,
): Promise<void> {
  const hash = await walletClient.writeContract({
    address: to,
    abi,
    functionName,
    args,
    value,
    account: from,
    chain: walletClient.chain,
  })
  const receipt = await publicClient.waitForTransactionReceipt({ hash })
  if (receipt.status !== 'success') throw new Error(`${functionName} failed`)
}

/**
 * Deploys EntryPoint v0.9, the account factory (and implementation), TestUSD and the paymaster on a local node,
 * using the node's unlocked dev accounts. No private key is handled here.
 */
export async function deployLocalStack(rpcUrl: string, chainId = 31337): Promise<Deployment> {
  const { publicClient, walletClient } = clientsFor(rpcUrl, chainId)
  const accounts = await walletClient.requestAddresses()
  const [admin, bundler, sponsor, g0, g1, g2] = accounts
  if (admin === undefined || bundler === undefined || sponsor === undefined || g2 === undefined) {
    throw new Error('the node must expose at least 6 unlocked accounts')
  }
  if (g0 === undefined || g1 === undefined) throw new Error('unreachable')

  const ep = artifacts.entryPoint()
  const entryPoint = await deploy(publicClient, walletClient, admin, ep.abi, ep.bytecode, [])

  const fac = artifacts.factory()
  const factory = await deploy(publicClient, walletClient, admin, fac.abi, fac.bytecode, [entryPoint])
  const accountImplementation = (await publicClient.readContract({
    address: factory,
    abi: fac.abi,
    functionName: 'ACCOUNT_IMPLEMENTATION',
  })) as Address

  const usdArtifact = artifacts.testUsd()
  const testUsd = await deploy(publicClient, walletClient, admin, usdArtifact.abi, usdArtifact.bytecode, [admin])

  const pm = artifacts.paymaster()
  const paymaster = await deploy(publicClient, walletClient, admin, pm.abi, pm.bytecode, [
    entryPoint,
    testUsd,
    admin,
    DEFAULT_TOKEN_PER_NATIVE,
  ])
  await send(publicClient, walletClient, admin, paymaster, pm.abi, 'deposit', [], parseEther('50'))
  await send(publicClient, walletClient, admin, paymaster, pm.abi, 'addStake', [86_400], parseEther('1'))
  await send(publicClient, walletClient, admin, paymaster, pm.abi, 'setSponsorSigner', [sponsor])
  // Token float the paymaster uses to front sponsor-guaranteed first operations.
  await send(publicClient, walletClient, admin, testUsd, usdArtifact.abi, 'mint', [paymaster, 1_000_000_000_000n])

  return {
    chainId,
    entryPoint,
    factory,
    accountImplementation,
    testUsd,
    paymaster,
    admin,
    bundler,
    sponsor,
    guardians: [g0, g1, g2],
  }
}
