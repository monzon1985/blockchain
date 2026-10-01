// SPDX-License-Identifier: MIT
// Test-side access to the chain started by scripts/e2e-chain.mjs (details in .e2e/runtime.json).
import { readFileSync } from 'node:fs'
import path from 'node:path'

import { expect, test as base, type Page } from '@playwright/test'
import {
  createPublicClient,
  createWalletClient,
  defineChain,
  erc20Abi,
  http,
  maxUint256,
  type Address,
  type Hex,
} from 'viem'

import { ammRouterAbi } from '../src/generated'
import { withGasMargin } from '../src/lib/gas'
import { parseDeployment } from '../src/lib/manifest'

interface Runtime {
  rpcUrl: string
  baseline: Hex
  accounts: Address[]
  manifest: unknown
}

// Read lazily: the file only exists once Playwright's webServer (scripts/e2e-chain.mjs) is up.
let cached: ReturnType<typeof load> | undefined
function load() {
  const runtime = JSON.parse(
    readFileSync(path.join(import.meta.dirname, '..', '.e2e', 'runtime.json'), 'utf8'),
  ) as Runtime
  const deployment = parseDeployment(runtime.manifest)
  const chain = defineChain({
    id: deployment.chainId,
    name: 'Anvil (e2e)',
    nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
    rpcUrls: { default: { http: [runtime.rpcUrl] } },
  })
  const publicClient = createPublicClient({ chain, transport: http(runtime.rpcUrl), pollingInterval: 100 })
  return { runtime, deployment, chain, publicClient }
}
export function env() {
  cached ??= load()
  return cached
}

/** Account #1: the dApp user behind the mock connector. */
export const user = () => env().runtime.accounts[1]!
/** Account #2: a second trader (the front-runner in the slippage spec). */
export const other = () => env().runtime.accounts[2]!
export const token = (symbol: string) => env().deployment.tokens.find((t) => t.symbol === symbol)!

export async function rpc<T = unknown>(method: string, params: unknown[] = []): Promise<T> {
  return (await env().publicClient.request({ method, params } as never)) as T
}

/** Sends a contract call from an unlocked anvil account (with the dApp's gas margin) and waits for success. */
export async function sendFrom(
  account: Address,
  call: {
    address: Address
    abi: typeof erc20Abi | typeof ammRouterAbi
    functionName: string
    args: readonly unknown[]
  },
  overrides: { maxPriorityFeePerGas?: bigint; maxFeePerGas?: bigint; gas?: bigint; wait?: boolean } = {},
): Promise<Hex> {
  const { chain, runtime, publicClient } = env()
  const wallet = createWalletClient({ chain, transport: http(runtime.rpcUrl), account })
  const gas = overrides.gas ?? withGasMargin(await publicClient.estimateContractGas({ ...call, account } as never))
  const hash = await wallet.writeContract({ ...call, gas, ...overrides } as never)
  if (overrides.wait !== false) {
    const receipt = await publicClient.waitForTransactionReceipt({ hash })
    expect(receipt.status).toBe('success')
  }
  return hash
}

export async function approveRouter(account: Address, tokenAddress: Address) {
  const { router } = env().deployment
  await sendFrom(account, { address: tokenAddress, abi: erc20Abi, functionName: 'approve', args: [router, maxUint256] })
}

export const balanceOf = (tokenAddress: Address, owner: Address) =>
  env().publicClient.readContract({ address: tokenAddress, abi: erc20Abi, functionName: 'balanceOf', args: [owner] })

let snapshotId: Hex | undefined

/** Every spec starts from the freshly deployed state and with automine on. */
export const test = base.extend<{ page: Page }>({
  page: async ({ page }, runTest) => {
    await rpc('evm_setAutomine', [true])
    await rpc('evm_revert', [snapshotId ?? env().runtime.baseline])
    snapshotId = await rpc<Hex>('evm_snapshot')
    await runTest(page)
    await rpc('evm_setAutomine', [true])
  },
})
export { expect }

/** Opens `path` and connects the mock connector (anvil account #1) through the custom connect UI. */
export async function openConnected(page: Page, url = '/') {
  await page.goto(url)
  await page.getByTestId('connect-open').click()
  await page.getByTestId('connector-mock').click()
  await expect(page.getByTestId('connected-address')).toHaveAttribute('title', user())
}

/** Waits for a toast with the given title prefix to reach `kind`. */
export async function expectToast(page: Page, title: string, kind: 'success' | 'error') {
  const toast = page.getByTestId('toast').filter({ hasText: title }).last()
  await expect(toast).toHaveAttribute('data-kind', kind, { timeout: 60_000 })
  return toast
}
