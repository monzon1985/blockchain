// SPDX-License-Identifier: MIT
import type { Metadata } from 'next'
import { connection } from 'next/server'

import { Header } from '@/components/Header'
import { loadRuntimeConfig } from '@/lib/runtime-config'

import './globals.css'
import { Providers } from './providers'

export const metadata: Metadata = {
  title: 'Hardened AMM',
  description: 'Swap and provide liquidity on a hardened constant-product AMM (local anvil demo).',
}

export default async function RootLayout({ children }: LayoutProps<'/'>) {
  // The chain endpoint and deployment manifest are read per request, so the build is not tied to one chain.
  await connection()
  const runtime = await loadRuntimeConfig()

  return (
    <html lang="en">
      <body>
        {runtime.ok ? (
          <Providers runtime={runtime.config}>
            <Header />
            <main className="main">{children}</main>
            <footer className="footer">
              Technical demo on a local chain. Unaudited software; do not use with real funds.
            </footer>
          </Providers>
        ) : (
          <main className="main">
            <section className="card">
              <h1>Chain not configured</h1>
              <p data-testid="not-configured">{runtime.reason}</p>
            </section>
          </main>
        )}
      </body>
    </html>
  )
}
