// SPDX-License-Identifier: MIT
import type { Metadata } from 'next'
import type { ReactNode } from 'react'

import './globals.css'

export const metadata: Metadata = {
  title: 'Passkey Smart Account',
  description: 'Passkey-first ERC-4337 v0.9 / EIP-7702 wallet running against a local devnet (technical demo).',
}

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="en">
      <body>
        <header className="topbar">
          <strong>Passkey Smart Account</strong>
          <span className="muted">ERC-4337 v0.9 · EIP-7702 · P-256 · local devnet demo</span>
        </header>
        <main className="container">{children}</main>
      </body>
    </html>
  )
}
