// SPDX-License-Identifier: MIT
import { nodeUrl } from '@/lib/server/env'
import { forwardJsonRpc } from '@/lib/server/http'

export const dynamic = 'force-dynamic'

/** Read-only node methods the browser may call. Anvil admin methods are never proxied. */
const ALLOWED = new Set([
  'eth_chainId',
  'eth_blockNumber',
  'eth_call',
  'eth_getBalance',
  'eth_getCode',
  'eth_getTransactionCount',
  'eth_getBlockByNumber',
  'eth_estimateGas',
  'eth_feeHistory',
  'eth_gasPrice',
  'eth_maxPriorityFeePerGas',
  'eth_getTransactionReceipt',
  'eth_getLogs',
  'net_version',
])

export function POST(request: Request): Promise<Response> {
  return forwardJsonRpc(request, nodeUrl(), ALLOWED)
}
