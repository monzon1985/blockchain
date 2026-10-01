// SPDX-License-Identifier: MIT
'use client'

import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { useState, type ReactNode } from 'react'
import { WagmiProvider } from 'wagmi'

import { RuntimeContext } from '@/components/RuntimeContext'
import { SettingsProvider } from '@/components/Settings'
import { ToastProvider } from '@/components/Toasts'
import type { RuntimeConfig } from '@/lib/types'
import { createWagmiConfig } from '@/lib/wagmi'

export function Providers({ runtime, children }: { runtime: RuntimeConfig; children: ReactNode }) {
  // One wagmi config and one query client per browser session, created from the server-resolved runtime config.
  const [config] = useState(() => createWagmiConfig(runtime))
  const [queryClient] = useState(() => new QueryClient({ defaultOptions: { queries: { staleTime: 1_000 } } }))

  return (
    <RuntimeContext.Provider value={runtime}>
      <WagmiProvider config={config}>
        <QueryClientProvider client={queryClient}>
          <SettingsProvider>
            <ToastProvider>{children}</ToastProvider>
          </SettingsProvider>
        </QueryClientProvider>
      </WagmiProvider>
    </RuntimeContext.Provider>
  )
}
