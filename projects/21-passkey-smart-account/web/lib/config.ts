// SPDX-License-Identifier: MIT
import type { Address } from 'viem'

/** Public wallet configuration served by /api/config (addresses of the local deployment). */
export interface WalletConfig {
  readonly chainId: number
  readonly entryPoint: Address
  readonly factory: Address
  readonly accountImplementation: Address
  readonly testUsd: Address
  readonly paymaster: Address
  readonly guardians: readonly Address[]
  /** A sweeper-like contract deployed on the devnet so the wallet can demonstrate the 7702 target check. */
  readonly demoSweeper?: Address
  readonly devTools: boolean
}
