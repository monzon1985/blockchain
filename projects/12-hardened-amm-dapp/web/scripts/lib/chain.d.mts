// SPDX-License-Identifier: MIT
// Type declarations for chain.mjs (consumed by the TypeScript test setup).
import type { ChildProcess } from 'node:child_process'

export declare const WEB_DIR: string
export declare const CONTRACTS_DIR: string
export declare const ANVIL_ACCOUNTS: readonly `0x${string}`[]
export declare function freePort(): Promise<number>
export declare function rpc(url: string, method: string, params?: unknown[]): Promise<unknown>
export declare function stopProcess(child: ChildProcess | undefined): void
export declare function startAnvil(options?: {
  log?: boolean
}): Promise<{ url: string; port: number; child: ChildProcess; stop: () => void }>
export declare function deployLocal(rpcUrl: string, outFile: string, options?: { log?: boolean }): unknown
export declare function nextBin(): string
export declare function appEnv(rpcUrl: string, deploymentFile: string): Record<string, string>
export declare function onShutdown(cleanup: () => void): void
