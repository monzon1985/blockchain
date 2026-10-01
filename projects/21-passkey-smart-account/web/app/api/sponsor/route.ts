// SPDX-License-Identifier: MIT
// Demo sponsor: signs a TokenPaymaster guarantee for one user operation hash. A production sponsor service would
// apply a policy (allowlists, rate limits, spend caps) before signing; this local one signs every request.
import { isHex, type Hex } from 'viem'

import { deployment, devToolsEnabled } from '@/lib/server/env'
import { jsonError } from '@/lib/server/http'
import { nodeRpc } from '@/lib/server/node'

export const dynamic = 'force-dynamic'

export async function POST(request: Request): Promise<Response> {
  if (!devToolsEnabled()) return jsonError(404, 'not found')
  const body = (await request.json()) as { userOpHash?: unknown; validUntil?: unknown; validAfter?: unknown }
  const { userOpHash, validUntil, validAfter } = body
  if (typeof userOpHash !== 'string' || !isHex(userOpHash) || userOpHash.length !== 66) {
    return jsonError(400, 'userOpHash must be a 32-byte hex string')
  }
  if (typeof validUntil !== 'number' || typeof validAfter !== 'number') {
    return jsonError(400, 'validity window required')
  }
  const d = deployment()
  const typedData = {
    domain: { name: 'TokenPaymaster', version: '1', chainId: d.chainId, verifyingContract: d.paymaster },
    types: {
      EIP712Domain: [
        { name: 'name', type: 'string' },
        { name: 'version', type: 'string' },
        { name: 'chainId', type: 'uint256' },
        { name: 'verifyingContract', type: 'address' },
      ],
      SponsorGuarantee: [
        { name: 'userOpHash', type: 'bytes32' },
        { name: 'validUntil', type: 'uint48' },
        { name: 'validAfter', type: 'uint48' },
      ],
    },
    primaryType: 'SponsorGuarantee',
    message: { userOpHash, validUntil, validAfter },
  }
  const signature = await nodeRpc<Hex>('eth_signTypedData_v4', [d.sponsor, JSON.stringify(typedData)])
  return Response.json({ signature })
}
