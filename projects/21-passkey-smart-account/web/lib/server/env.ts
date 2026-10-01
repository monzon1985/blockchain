// SPDX-License-Identifier: MIT
// Server-only runtime configuration. Everything comes from the environment at request time, so one `next build`
// works against any devnet (ports are chosen at runtime by scripts/e2e-chain.mjs).
import 'server-only'
import type { Address } from 'viem'

import type { WalletConfig } from '../config'

export interface Deployment {
  chainId: number
  entryPoint: Address
  factory: Address
  accountImplementation: Address
  testUsd: Address
  paymaster: Address
  admin: Address
  bundler: Address
  sponsor: Address
  guardians: Address[]
  demoSweeper?: Address
}

export class ConfigError extends Error {}

function required(name: string): string {
  const value = process.env[name]
  if (value === undefined || value === '') throw new ConfigError(`${name} is not set`)
  return value
}

export function nodeUrl(): string {
  return required('WALLET_RPC_URL')
}

export function bundlerUrl(): string {
  return required('WALLET_BUNDLER_URL')
}

export function deployment(): Deployment {
  return JSON.parse(required('WALLET_DEPLOYMENT')) as Deployment
}

/** Dev helpers (faucet, time travel, guardian console, demo sponsor) only exist on local devnets. */
export function devToolsEnabled(): boolean {
  return process.env['WALLET_DEV_TOOLS'] === '1'
}

export function publicConfig(): WalletConfig {
  const d = deployment()
  return {
    chainId: d.chainId,
    entryPoint: d.entryPoint,
    factory: d.factory,
    accountImplementation: d.accountImplementation,
    testUsd: d.testUsd,
    paymaster: d.paymaster,
    guardians: d.guardians,
    ...(d.demoSweeper === undefined ? {} : { demoSweeper: d.demoSweeper }),
    devTools: devToolsEnabled(),
  }
}
