// SPDX-License-Identifier: MIT
'use client'

import { PoolAnalytics } from '@/components/PoolAnalytics'
import { useRuntime } from '@/components/RuntimeContext'

export default function AnalyticsPage() {
  const { deployment } = useRuntime()
  return (
    <div className="stack wide">
      <p className="muted">Derived from the pairs&apos; own Swap, Mint, Burn and Sync events; no indexer involved.</p>
      {deployment.pairs.map((pair) => (
        <PoolAnalytics key={pair.address} pair={pair} />
      ))}
    </div>
  )
}
