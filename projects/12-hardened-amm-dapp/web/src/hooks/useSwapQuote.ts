// SPDX-License-Identifier: MIT
'use client'

import { useMemo } from 'react'

import { useRuntime } from '@/components/RuntimeContext'

import {
  QuoteError,
  assertReservesFit,
  getAmountsIn,
  getAmountsOut,
  maximumAmountIn,
  minimumAmountOut,
  priceImpactBps,
} from '@/lib/quote'
import { findRoute, routeHops, type Route } from '@/lib/route'
import type { TokenInfo } from '@/lib/types'

import { usePools } from './usePools'

export type SwapMode = 'exactIn' | 'exactOut'

export interface SwapQuote {
  route: Route
  mode: SwapMode
  /** amounts[0] is paid, amounts[last] is received; one entry per token of the route. */
  amounts: bigint[]
  amountIn: bigint
  amountOut: bigint
  /** Exact-in: minimum received after slippage. Exact-out: equal to amountOut. */
  minimumOut: bigint
  /** Exact-out: maximum paid after slippage. Exact-in: equal to amountIn. */
  maximumIn: bigint
  priceImpactBps: bigint
}

export type SwapQuoteResult =
  | { status: 'idle' }
  | { status: 'loading' }
  | { status: 'no-route' }
  | { status: 'error'; message: string }
  | { status: 'ok'; quote: SwapQuote }

/**
 * Quote for a swap, computed locally with the shared quote library from the latest on-chain reserves. The library
 * is differential-tested against the router, so this is the amount the router would compute in the next block.
 */
export function useSwapQuote(params: {
  tokenIn: TokenInfo | undefined
  tokenOut: TokenInfo | undefined
  mode: SwapMode
  amount: bigint | null
  slippageBps: bigint
}): SwapQuoteResult {
  const { tokenIn, tokenOut, mode, amount, slippageBps } = params
  const { reserves, isLoading } = usePools()
  const { deployment } = useRuntime()

  return useMemo(() => {
    if (!tokenIn || !tokenOut || amount === null || amount === 0n) return { status: 'idle' }
    const route = findRoute(tokenIn, tokenOut, deployment.pairs)
    if (!route) return { status: 'no-route' }
    const hops = routeHops(route, reserves)
    if (!hops) return isLoading ? { status: 'loading' } : { status: 'error', message: 'Pool state unavailable' }
    try {
      const amounts = mode === 'exactIn' ? getAmountsOut(amount, hops) : getAmountsIn(amount, hops)
      assertReservesFit(amounts, hops)
      const amountIn = amounts[0]!
      const amountOut = amounts[amounts.length - 1]!
      if (amountOut === 0n) return { status: 'error', message: 'Amount too small: the trade would return nothing' }
      return {
        status: 'ok',
        quote: {
          route,
          mode,
          amounts,
          amountIn,
          amountOut,
          minimumOut: mode === 'exactIn' ? minimumAmountOut(amountOut, slippageBps) : amountOut,
          maximumIn: mode === 'exactOut' ? maximumAmountIn(amountIn, slippageBps) : amountIn,
          priceImpactBps: priceImpactBps(amountIn, amountOut, hops),
        },
      }
    } catch (error) {
      if (error instanceof QuoteError) return { status: 'error', message: error.message }
      throw error
    }
  }, [tokenIn, tokenOut, amount, mode, slippageBps, reserves, isLoading, deployment.pairs])
}
