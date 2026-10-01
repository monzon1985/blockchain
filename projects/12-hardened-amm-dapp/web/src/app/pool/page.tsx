// SPDX-License-Identifier: MIT
import { AddLiquidityCard, RemoveLiquidityCard } from '@/components/LiquidityCards'

export default function PoolPage() {
  return (
    <div className="stack">
      <AddLiquidityCard />
      <RemoveLiquidityCard />
    </div>
  )
}
