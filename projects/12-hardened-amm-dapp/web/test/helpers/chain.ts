// SPDX-License-Identifier: MIT
import { createPublicClient, createWalletClient, http, type Address, type Hex } from 'viem'
import { inject } from 'vitest'

import { ANVIL_ACCOUNTS } from '../../scripts/lib/chain.mjs'
import { parseDeployment } from '@/lib/manifest'
import type { RuntimeConfig } from '@/lib/types'
import { localChain } from '@/lib/wagmi'

/** The shared anvil chain started by test/setup/anvil.global.ts. */
export function testChain() {
  const rpcUrl = inject('rpcUrl')
  const deployment = parseDeployment(inject('manifest'))
  const chain = localChain(rpcUrl, deployment.chainId)
  const publicClient = createPublicClient({ chain, transport: http(rpcUrl), pollingInterval: 50 })
  /** Wallet client for an unlocked anvil account (eth_sendTransaction; no key material). */
  const wallet = (account: Address) => createWalletClient({ chain, transport: http(rpcUrl), account })
  const runtime: RuntimeConfig = {
    rpcUrl,
    deployment,
    mockConnector: { enabled: true, accounts: [ANVIL_ACCOUNTS[1]!] },
  }
  return { rpcUrl, deployment, chain, publicClient, wallet, runtime }
}

/** evm_snapshot / evm_revert helpers so every suite leaves the shared chain as it found it. */
export async function snapshot(client: ReturnType<typeof testChain>['publicClient']): Promise<Hex> {
  return (await client.request({ method: 'evm_snapshot' } as never)) as Hex
}

export async function revert(client: ReturnType<typeof testChain>['publicClient'], id: Hex): Promise<void> {
  await client.request({ method: 'evm_revert', params: [id] } as never)
}

/** Deterministic PRNG (mulberry32) for reproducible differential campaigns. */
export function prng(seed: number) {
  let state = seed >>> 0
  const next = () => {
    state = (state + 0x6d2b79f5) >>> 0
    let t = state
    t = Math.imul(t ^ (t >>> 15), t | 1)
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61)
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
  return {
    next,
    int: (max: number) => Math.floor(next() * max),
    /** Roughly log-uniform bigint in [1, max]: dust, typical and pool-draining sizes are equally likely. */
    logUniform: (max: bigint) => {
      const digits = 1 + Math.floor(next() * max.toString().length)
      let value = 0n
      for (let i = 0; i < digits; i++) value = value * 10n + BigInt(Math.floor(next() * 10))
      value %= max
      return value === 0n ? 1n : value
    },
  }
}
