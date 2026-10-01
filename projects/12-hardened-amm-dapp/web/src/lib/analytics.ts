// SPDX-License-Identifier: MIT
// Pool analytics are derived only from the pair's own events (Swap, Mint, Burn, Sync), so the page works against any
// node without an indexer. The aggregation is pure and unit-tested.
import type { Hex } from 'viem'

export type PoolEvent =
  | {
      kind: 'swap'
      blockNumber: bigint
      logIndex: number
      transactionHash: Hex
      amount0In: bigint
      amount1In: bigint
      amount0Out: bigint
      amount1Out: bigint
    }
  | { kind: 'mint'; blockNumber: bigint; logIndex: number; transactionHash: Hex; amount0: bigint; amount1: bigint }
  | { kind: 'burn'; blockNumber: bigint; logIndex: number; transactionHash: Hex; amount0: bigint; amount1: bigint }
  | { kind: 'sync'; blockNumber: bigint; logIndex: number; transactionHash: Hex; reserve0: bigint; reserve1: bigint }

export interface PricePoint {
  blockNumber: bigint
  /** reserve1 / reserve0 in raw units scaled by 1e18 (fixed point). */
  price1e18: bigint
}

export interface PoolStats {
  swaps: number
  mints: number
  burns: number
  /** Total token0 / token1 that entered the pool through swaps. */
  volume0: bigint
  volume1: bigint
  /** LP fees earned (0.30 % of swap inputs, protocol share included), rounded down. */
  fees0: bigint
  fees1: bigint
  /** Net liquidity added minus removed, per token (excluding swaps and donations). */
  netDeposits0: bigint
  netDeposits1: bigint
  reserve0: bigint
  reserve1: bigint
  priceHistory: PricePoint[]
  recentSwaps: Extract<PoolEvent, { kind: 'swap' }>[]
}

const byChainOrder = (a: PoolEvent, b: PoolEvent) =>
  a.blockNumber === b.blockNumber ? a.logIndex - b.logIndex : a.blockNumber < b.blockNumber ? -1 : 1

export function aggregatePoolEvents(events: readonly PoolEvent[], recent = 10): PoolStats {
  const stats: PoolStats = {
    swaps: 0,
    mints: 0,
    burns: 0,
    volume0: 0n,
    volume1: 0n,
    fees0: 0n,
    fees1: 0n,
    netDeposits0: 0n,
    netDeposits1: 0n,
    reserve0: 0n,
    reserve1: 0n,
    priceHistory: [],
    recentSwaps: [],
  }
  const ordered = [...events].sort(byChainOrder)
  const swaps: Extract<PoolEvent, { kind: 'swap' }>[] = []
  for (const event of ordered) {
    switch (event.kind) {
      case 'swap':
        stats.swaps++
        stats.volume0 += event.amount0In
        stats.volume1 += event.amount1In
        stats.fees0 += (event.amount0In * 3n) / 1000n
        stats.fees1 += (event.amount1In * 3n) / 1000n
        swaps.push(event)
        break
      case 'mint':
        stats.mints++
        stats.netDeposits0 += event.amount0
        stats.netDeposits1 += event.amount1
        break
      case 'burn':
        stats.burns++
        stats.netDeposits0 -= event.amount0
        stats.netDeposits1 -= event.amount1
        break
      case 'sync':
        stats.reserve0 = event.reserve0
        stats.reserve1 = event.reserve1
        if (event.reserve0 > 0n) {
          const point = { blockNumber: event.blockNumber, price1e18: (event.reserve1 * 10n ** 18n) / event.reserve0 }
          const last = stats.priceHistory[stats.priceHistory.length - 1]
          // One point per block: the last Sync of a block is the price the block ended with.
          if (last && last.blockNumber === event.blockNumber) stats.priceHistory[stats.priceHistory.length - 1] = point
          else stats.priceHistory.push(point)
        }
        break
    }
  }
  stats.recentSwaps = swaps.slice(-recent).reverse()
  return stats
}
