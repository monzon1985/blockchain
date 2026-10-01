// SPDX-License-Identifier: MIT
'use client'

import Link from 'next/link'
import { usePathname } from 'next/navigation'

import { ConnectButton } from './ConnectButton'

const LINKS = [
  { href: '/', label: 'Swap' },
  { href: '/pool', label: 'Pool' },
  { href: '/analytics', label: 'Analytics' },
] as const

export function Header() {
  const pathname = usePathname()
  return (
    <header className="header">
      <div className="brand">
        <span className="logo" aria-hidden>
          ◆
        </span>
        Hardened AMM
      </div>
      <nav>
        {LINKS.map((link) => (
          <Link key={link.href} href={link.href} className={pathname === link.href ? 'active' : undefined}>
            {link.label}
          </Link>
        ))}
      </nav>
      <ConnectButton />
    </header>
  )
}
