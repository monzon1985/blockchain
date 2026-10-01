// SPDX-License-Identifier: MIT
'use client'

import { useQuery } from '@tanstack/react-query'
import { useBlockNumber, usePublicClient } from 'wagmi'

import { ammPairAbi } from '@/generated'
import { aggregatePoolEvents, type PoolEvent, type PoolStats } from '@/lib/analytics'
import { displayPrice, formatAmount, shortHex } from '@/lib/format'
import type { PairInfo } from '@/lib/types'

import { useRuntime } from './RuntimeContext'

function usePoolStats(pair: PairInfo) {
  const client = usePublicClient()
  const { deployment } = useRuntime()
  const { data: blockNumber } = useBlockNumber({ watch: true })
  return useQuery({
    queryKey: ['pool-events', pair.address, blockNumber?.toString()],
    enabled: !!client && blockNumber !== undefined,
    queryFn: async (): Promise<PoolStats> => {
      const logs = await client!.getContractEvents({
        address: pair.address,
        abi: ammPairAbi,
        fromBlock: BigInt(deployment.startBlock),
        toBlock: blockNumber,
      })
      const events: PoolEvent[] = []
      for (const log of logs) {
        const base = { blockNumber: log.blockNumber, logIndex: log.logIndex, transactionHash: log.transactionHash }
        if (log.eventName === 'Swap') {
          events.push({ kind: 'swap', ...base, ...log.args } as PoolEvent)
        } else if (log.eventName === 'Mint') {
          events.push({ kind: 'mint', ...base, amount0: log.args.amount0!, amount1: log.args.amount1! })
        } else if (log.eventName === 'Burn') {
          events.push({ kind: 'burn', ...base, amount0: log.args.amount0!, amount1: log.args.amount1! })
        } else if (log.eventName === 'Sync') {
          events.push({
            kind: 'sync',
            ...base,
            reserve0: BigInt(log.args.reserve0!),
            reserve1: BigInt(log.args.reserve1!),
          })
        }
      }
      return aggregatePoolEvents(events)
    },
  })
}

/** Inline SVG sparkline of the pool price over its Sync events. */
function Sparkline({ points }: { points: number[] }) {
  if (points.length < 2) return <p className="muted">Not enough price history yet.</p>
  const width = 320
  const height = 64
  const min = Math.min(...points)
  const max = Math.max(...points)
  const span = max - min || 1
  const path = points
    .map((value, i) => {
      const x = (i / (points.length - 1)) * width
      const y = height - ((value - min) / span) * (height - 8) - 4
      return `${i === 0 ? 'M' : 'L'}${x.toFixed(1)},${y.toFixed(1)}`
    })
    .join(' ')
  return (
    <svg className="sparkline" viewBox={`0 0 ${width} ${height}`} role="img" aria-label="Price history">
      <path d={path} fill="none" stroke="currentColor" strokeWidth="2" />
    </svg>
  )
}

export function PoolAnalytics({ pair }: { pair: PairInfo }) {
  const { data: stats, isLoading, error } = usePoolStats(pair)
  const { token0, token1 } = pair
  const label = `${token0.symbol} / ${token1.symbol}`

  return (
    <section className="card" data-testid={`analytics-${token0.symbol}-${token1.symbol}`}>
      <div className="card-head">
        <h2>{label}</h2>
        <code title={pair.address}>{shortHex(pair.address)}</code>
      </div>
      {isLoading || !stats ? (
        <p className="muted">{error ? `Failed to load events: ${error.message}` : 'Loading events…'}</p>
      ) : (
        <>
          <dl className="stats">
            <div>
              <dt>Price</dt>
              <dd>
                1 {token0.symbol} ={' '}
                {displayPrice(stats.reserve0, stats.reserve1, token0.decimals, token1.decimals).toPrecision(6)}{' '}
                {token1.symbol}
              </dd>
            </div>
            <div>
              <dt>Reserves</dt>
              <dd>
                {formatAmount(stats.reserve0, token0.decimals, 2)} {token0.symbol} ·{' '}
                {formatAmount(stats.reserve1, token1.decimals, 2)} {token1.symbol}
              </dd>
            </div>
            <div>
              <dt>Swaps / mints / burns</dt>
              <dd data-testid="analytics-counts">
                {stats.swaps} / {stats.mints} / {stats.burns}
              </dd>
            </div>
            <div>
              <dt>Volume (inputs)</dt>
              <dd>
                {formatAmount(stats.volume0, token0.decimals, 4)} {token0.symbol} ·{' '}
                {formatAmount(stats.volume1, token1.decimals, 4)} {token1.symbol}
              </dd>
            </div>
            <div>
              <dt>LP fees earned (0.30 %)</dt>
              <dd>
                {formatAmount(stats.fees0, token0.decimals, 6)} {token0.symbol} ·{' '}
                {formatAmount(stats.fees1, token1.decimals, 6)} {token1.symbol}
              </dd>
            </div>
          </dl>
          <Sparkline
            points={stats.priceHistory.map((point) =>
              displayPrice(10n ** 18n, point.price1e18, token0.decimals, token1.decimals),
            )}
          />
          <table className="trades">
            <thead>
              <tr>
                <th>Block</th>
                <th>Sold</th>
                <th>Bought</th>
                <th>Tx</th>
              </tr>
            </thead>
            <tbody>
              {stats.recentSwaps.map((swap) => {
                const sold0 = swap.amount0In > 0n
                return (
                  <tr key={`${swap.transactionHash}-${swap.logIndex}`}>
                    <td>{swap.blockNumber.toString()}</td>
                    <td>
                      {sold0
                        ? `${formatAmount(swap.amount0In, token0.decimals, 4)} ${token0.symbol}`
                        : `${formatAmount(swap.amount1In, token1.decimals, 4)} ${token1.symbol}`}
                    </td>
                    <td>
                      {sold0
                        ? `${formatAmount(swap.amount1Out, token1.decimals, 4)} ${token1.symbol}`
                        : `${formatAmount(swap.amount0Out, token0.decimals, 4)} ${token0.symbol}`}
                    </td>
                    <td>
                      <code>{shortHex(swap.transactionHash)}</code>
                    </td>
                  </tr>
                )
              })}
            </tbody>
          </table>
        </>
      )}
    </section>
  )
}
