// SPDX-License-Identifier: MIT
import { isAddress, isHex } from 'viem'

import { accountAbi } from '@/lib/abis'
import { deployment, devToolsEnabled } from '@/lib/server/env'
import { jsonError } from '@/lib/server/http'
import { sendFromUnlocked } from '@/lib/server/node'

export const dynamic = 'force-dynamic'

interface GuardianRequest {
  guardianIndex?: unknown
  account?: unknown
  newPasskey?: { qx?: unknown; qy?: unknown; rpIdHash?: unknown }
}

/** Guardian console: a devnet guardian (unlocked node account) approves replacing an account's passkey. */
export async function POST(request: Request): Promise<Response> {
  if (!devToolsEnabled()) return jsonError(404, 'not found')
  const body = (await request.json()) as GuardianRequest
  const d = deployment()
  const guardian = typeof body.guardianIndex === 'number' ? d.guardians[body.guardianIndex] : undefined
  if (guardian === undefined) return jsonError(400, 'unknown guardian')
  if (typeof body.account !== 'string' || !isAddress(body.account)) return jsonError(400, 'invalid account')
  const key = body.newPasskey
  const { qx, qy, rpIdHash } = key ?? {}
  if (typeof qx !== 'string' || typeof qy !== 'string' || typeof rpIdHash !== 'string') {
    return jsonError(400, 'invalid passkey')
  }
  if (!isHex(qx) || !isHex(qy) || !isHex(rpIdHash)) return jsonError(400, 'invalid passkey')
  try {
    const hash = await sendFromUnlocked(guardian, body.account, accountAbi, 'approveRecovery', [{ qx, qy, rpIdHash }])
    return Response.json({ hash })
  } catch (error) {
    return jsonError(409, error instanceof Error ? error.message : 'approveRecovery failed')
  }
}
