// SPDX-License-Identifier: MIT
import type { Address, Hex } from 'viem'

/** One ERC-20 of the deployment manifest written by contracts/script/DeployLocal.s.sol. */
export interface TokenInfo {
  address: Address
  symbol: string
  name: string
  decimals: number
}

/** A pair of the manifest, with both tokens resolved and sorted like the contract sorts them. */
export interface PairInfo {
  address: Address
  token0: TokenInfo
  token1: TokenInfo
}

/** Deployment manifest (deployments/local.json). */
export interface Deployment {
  chainId: number
  startBlock: number
  factory: Address
  router: Address
  pairInitCodeHash: Hex
  tokens: TokenInfo[]
  pairs: PairInfo[]
}

/** Everything the browser needs, resolved on the server at request time (no build-time chain coupling). */
export interface RuntimeConfig {
  rpcUrl: string
  deployment: Deployment
  mockConnector: {
    enabled: boolean
    accounts: Address[]
  }
}
