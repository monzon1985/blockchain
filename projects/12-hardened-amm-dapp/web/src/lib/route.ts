// SPDX-License-Identifier: MIT
import type { Address } from 'viem'

import type { HopReserves } from './quote'
import type { PairInfo, TokenInfo } from './types'

/** A swap route: the token path and the pair used for every hop. */
export interface Route {
  path: TokenInfo[]
  pairs: PairInfo[]
}

const same = (a: Address, b: Address) => a.toLowerCase() === b.toLowerCase()

/** Shortest route (fewest hops, at most `maxHops`) between two tokens over the known pairs. */
export function findRoute(
  tokenIn: TokenInfo,
  tokenOut: TokenInfo,
  pairs: readonly PairInfo[],
  maxHops = 3,
): Route | null {
  if (same(tokenIn.address, tokenOut.address)) return null
  const queue: Route[] = [{ path: [tokenIn], pairs: [] }]
  while (queue.length > 0) {
    const route = queue.shift()!
    const last = route.path[route.path.length - 1]!
    if (route.pairs.length >= maxHops) continue
    for (const pair of pairs) {
      if (route.pairs.includes(pair)) continue
      const next = same(pair.token0.address, last.address)
        ? pair.token1
        : same(pair.token1.address, last.address)
          ? pair.token0
          : null
      if (!next || route.path.some((token) => same(token.address, next.address))) continue
      const extended = { path: [...route.path, next], pairs: [...route.pairs, pair] }
      if (same(next.address, tokenOut.address)) return extended
      queue.push(extended)
    }
  }
  return null
}

/** Reserves of a pair as returned by getReserves: [reserve0, reserve1]. */
export type PairReserves = readonly [bigint, bigint]

/** Orients each pair's reserves along the route (reserve of the token sold first). */
export function routeHops(route: Route, reserves: ReadonlyMap<Address, PairReserves>): HopReserves[] | null {
  const hops: HopReserves[] = []
  for (let i = 0; i < route.pairs.length; i++) {
    const pair = route.pairs[i]!
    const r = reserves.get(pair.address)
    if (!r) return null
    const sellsToken0 = same(pair.token0.address, route.path[i]!.address)
    hops.push(sellsToken0 ? { reserveIn: r[0], reserveOut: r[1] } : { reserveIn: r[1], reserveOut: r[0] })
  }
  return hops
}
