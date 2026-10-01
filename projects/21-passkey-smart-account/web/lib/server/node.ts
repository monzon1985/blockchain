// SPDX-License-Identifier: MIT
import 'server-only'
import { encodeFunctionData, type Abi, type Address, type Hex } from 'viem'

import { nodeUrl } from './env'

let id = 1

export async function nodeRpc<T>(method: string, params: unknown[]): Promise<T> {
  const response = await fetch(nodeUrl(), {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: id++, method, params }),
    cache: 'no-store',
  })
  const body = (await response.json()) as { result?: T; error?: { message: string } }
  if (body.error !== undefined) throw new Error(body.error.message)
  return body.result as T
}

/** Sends a transaction from an account the devnet node holds unlocked, and waits for it to be mined. */
export async function sendFromUnlocked(
  from: Address,
  to: Address,
  abi: Abi,
  functionName: string,
  args: readonly unknown[],
): Promise<Hex> {
  const data = encodeFunctionData({ abi, functionName, args })
  const hash = await nodeRpc<Hex>('eth_sendTransaction', [{ from, to, data }])
  for (let i = 0; i < 50; i++) {
    const receipt = await nodeRpc<{ status: Hex } | null>('eth_getTransactionReceipt', [hash])
    if (receipt !== null) {
      if (receipt.status !== '0x1') throw new Error(`transaction ${hash} reverted`)
      return hash
    }
    await new Promise((r) => setTimeout(r, 100))
  }
  throw new Error(`transaction ${hash} not mined`)
}
