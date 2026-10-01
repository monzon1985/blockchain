// SPDX-License-Identifier: MIT
'use client'

import { useEffect, useMemo } from 'react'
import { erc20Abi, type Address } from 'viem'
import { useBlockNumber, useConnection, useReadContracts } from 'wagmi'

import { useRuntime } from '@/components/RuntimeContext'

export interface TokenState {
  balance: bigint
  /** Allowance granted to the router. */
  allowance: bigint
}

const NO_EXTRA_TOKENS: readonly Address[] = []

/** Balance and router allowance of every manifest token (plus optional extra tokens, e.g. LP tokens). */
export function useTokenState(extraTokens: readonly Address[] = NO_EXTRA_TOKENS): ReadonlyMap<Address, TokenState> {
  const { deployment } = useRuntime()
  const { address } = useConnection()
  const { data: blockNumber } = useBlockNumber({ watch: true })
  const tokens = useMemo(
    () => [...deployment.tokens.map((token) => token.address), ...extraTokens],
    [deployment.tokens, extraTokens],
  )
  const contracts = useMemo(
    () =>
      address
        ? tokens.flatMap((token) => [
            { address: token, abi: erc20Abi, functionName: 'balanceOf', args: [address] } as const,
            { address: token, abi: erc20Abi, functionName: 'allowance', args: [address, deployment.router] } as const,
          ])
        : [],
    [address, tokens, deployment.router],
  )
  const { data, refetch } = useReadContracts({ contracts, allowFailure: false, query: { enabled: !!address } })

  useEffect(() => {
    if (blockNumber !== undefined && address) void refetch()
  }, [blockNumber, address, refetch])

  return useMemo(() => {
    const state = new Map<Address, TokenState>()
    if (data) {
      tokens.forEach((token, i) => {
        state.set(token, { balance: data[i * 2] as bigint, allowance: data[i * 2 + 1] as bigint })
      })
    }
    return state
  }, [data, tokens])
}
