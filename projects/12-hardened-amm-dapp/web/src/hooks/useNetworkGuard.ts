// SPDX-License-Identifier: MIT
'use client'

import { useConnection } from 'wagmi'

import { useRuntime } from '@/components/RuntimeContext'

export interface NetworkGuard {
  /** Chain id of the deployment manifest: every read, write and signature targets this chain. */
  expectedChainId: number
  /** Chain the connected wallet reports, or undefined when no wallet is connected. */
  walletChainId: number | undefined
  /** A wallet is connected and it is on another chain: writes and signatures must be blocked. */
  wrongNetwork: boolean
}

/**
 * Compares the chain the wallet is actually on with the deployment's chain.
 *
 * This must read the connection's chain (`useConnection().chainId`), not wagmi's `useChainId()`: the latter only
 * follows *configured* chains, so with a wallet on mainnet or any chain this dApp does not configure it keeps
 * returning the local chain id and the wallet looks correct.
 */
export function useNetworkGuard(): NetworkGuard {
  const { deployment } = useRuntime()
  const { chainId, status } = useConnection()
  return {
    expectedChainId: deployment.chainId,
    walletChainId: chainId,
    wrongNetwork: status === 'connected' && chainId !== deployment.chainId,
  }
}
