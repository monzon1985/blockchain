// SPDX-License-Identifier: MIT
import { bundlerUrl } from '@/lib/server/env'
import { forwardJsonRpc } from '@/lib/server/http'

export const dynamic = 'force-dynamic'

const ALLOWED = new Set([
  'eth_chainId',
  'eth_supportedEntryPoints',
  'eth_estimateUserOperationGas',
  'eth_sendUserOperation',
  'eth_getUserOperationReceipt',
  'eth_getUserOperationByHash',
])

export function POST(request: Request): Promise<Response> {
  return forwardJsonRpc(request, bundlerUrl(), ALLOWED)
}
