// SPDX-License-Identifier: MIT
'use client'

import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { createContext, useContext, useEffect, useState, type ReactNode } from 'react'
import { defineChain } from 'viem'
import { createConfig, http, WagmiProvider, type Config } from 'wagmi'

import type { WalletConfig } from '@/lib/config'

const WalletConfigContext = createContext<WalletConfig | null>(null)

export function useWalletConfig(): WalletConfig {
  const cfg = useContext(WalletConfigContext)
  if (cfg === null) throw new Error('useWalletConfig outside of <Providers>')
  return cfg
}

function wagmiConfigFor(cfg: WalletConfig): Config {
  const rpc = `${window.location.origin}/api/rpc`
  const chain = defineChain({
    id: cfg.chainId,
    name: 'Local devnet',
    nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
    rpcUrls: { default: { http: [rpc] } },
  })
  return createConfig({ chains: [chain], transports: { [chain.id]: http(rpc) }, ssr: true })
}

/** Loads the devnet configuration at runtime (ports and addresses are chosen when the chain starts). */
export function Providers({ children }: { children: ReactNode }) {
  const [state, setState] = useState<{ cfg: WalletConfig; wagmi: Config } | { error: string } | null>(null)
  const [queryClient] = useState(() => new QueryClient())

  useEffect(() => {
    let cancelled = false
    fetch('/api/config', { cache: 'no-store' })
      .then(async (res) => {
        if (!res.ok) throw new Error(((await res.json()) as { error?: string }).error ?? res.statusText)
        return (await res.json()) as WalletConfig
      })
      .then((cfg) => {
        if (!cancelled) setState({ cfg, wagmi: wagmiConfigFor(cfg) })
      })
      .catch((error: unknown) => {
        if (!cancelled) setState({ error: error instanceof Error ? error.message : String(error) })
      })
    return () => {
      cancelled = true
    }
  }, [])

  if (state === null) return <p className="muted">Connecting to the local devnet…</p>
  if ('error' in state) {
    return (
      <div className="card error" data-testid="config-error">
        <h2>Devnet not configured</h2>
        <p>{state.error}</p>
        <p className="muted">Start the stack with <code>npm run e2e:chain</code> and pass its output to the server.</p>
      </div>
    )
  }
  return (
    <WagmiProvider config={state.wagmi}>
      <QueryClientProvider client={queryClient}>
        <WalletConfigContext.Provider value={state.cfg}>{children}</WalletConfigContext.Provider>
      </QueryClientProvider>
    </WagmiProvider>
  )
}
