// SPDX-License-Identifier: MIT
'use client'

import { useEffect, useMemo } from 'react'
import type { Address } from 'viem'
import { useBlockNumber, useReadContracts } from 'wagmi'

import { useRuntime } from '@/components/RuntimeContext'
import { ammPairAbi } from '@/generated'
import type { PairReserves } from '@/lib/route'
import type { PairInfo } from '@/lib/types'

export interface PoolState {
  pair: PairInfo
  reserve0: bigint
  reserve1: bigint
  totalSupply: bigint
}

export interface PoolsResult {
  pools: ReadonlyMap<Address, PoolState>
  reserves: ReadonlyMap<Address, PairReserves>
  isLoading: boolean
  blockNumber: bigint | undefined
}

/**
 * Reserves and LP supply of every pair in the manifest, re-read on every new block so quotes are always computed
 * from the state the next transaction will see.
 */
export function usePools(): PoolsResult {
  const { deployment } = useRuntime()
  const { data: blockNumber } = useBlockNumber({ watch: true })
  const contracts = useMemo(
    () =>
      deployment.pairs.flatMap((pair) => [
        { address: pair.address, abi: ammPairAbi, functionName: 'getReserves' } as const,
        { address: pair.address, abi: ammPairAbi, functionName: 'totalSupply' } as const,
      ]),
    [deployment.pairs],
  )
  const { data, isLoading, refetch } = useReadContracts({ contracts, allowFailure: false })

  useEffect(() => {
    if (blockNumber !== undefined) void refetch()
  }, [blockNumber, refetch])

  return useMemo(() => {
    const pools = new Map<Address, PoolState>()
    const reserves = new Map<Address, PairReserves>()
    if (data) {
      deployment.pairs.forEach((pair, i) => {
        const [reserve0, reserve1] = data[i * 2] as readonly [bigint, bigint, number]
        const totalSupply = data[i * 2 + 1] as bigint
        pools.set(pair.address, { pair, reserve0, reserve1, totalSupply })
        reserves.set(pair.address, [reserve0, reserve1])
      })
    }
    return { pools, reserves, isLoading, blockNumber }
  }, [data, deployment.pairs, isLoading, blockNumber])
}
