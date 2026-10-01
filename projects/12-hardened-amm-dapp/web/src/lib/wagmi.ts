// SPDX-License-Identifier: MIT
import { defineChain, type Chain } from 'viem'
import { createConfig, http, type CreateConnectorFn } from 'wagmi'
import { injected, mock } from 'wagmi/connectors'

import type { RuntimeConfig } from './types'

/** The local anvil chain, with the RPC endpoint resolved at request time. */
export function localChain(rpcUrl: string, chainId = 31337): Chain {
  return defineChain({
    id: chainId,
    name: 'Anvil (local)',
    nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
    rpcUrls: { default: { http: [rpcUrl] } },
    testnet: true,
  })
}

/**
 * wagmi config: an injected browser wallet, plus (local chain only) wagmi's mock connector bound to anvil's unlocked
 * dev accounts. The mock connector forwards eth_sendTransaction / eth_signTypedData_v4 to anvil, so Playwright can
 * drive real transactions and real EIP-2612 signatures without a browser extension or any private key.
 */
export function createWagmiConfig(runtime: RuntimeConfig) {
  const chain = localChain(runtime.rpcUrl, runtime.deployment.chainId)
  const connectors: CreateConnectorFn[] = [injected()]
  const [first, ...rest] = runtime.mockConnector.accounts
  if (runtime.mockConnector.enabled && first) {
    connectors.push(mock({ accounts: [first, ...rest], features: { reconnect: true } }))
  }
  return createConfig({
    chains: [chain],
    connectors,
    transports: { [chain.id]: http(runtime.rpcUrl) },
    multiInjectedProviderDiscovery: true,
    pollingInterval: 500,
    ssr: true,
  })
}
