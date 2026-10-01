// SPDX-License-Identifier: MIT
import { isAddress } from 'viem'

import { accountAbi } from '@/lib/abis'
import { deployment, devToolsEnabled } from '@/lib/server/env'
import { jsonError } from '@/lib/server/http'
import { sendFromUnlocked } from '@/lib/server/node'

export const dynamic = 'force-dynamic'

/** `executeRecovery` is permissionless once the timelock has elapsed; the devnet admin relays it. */
export async function POST(request: Request): Promise<Response> {
  if (!devToolsEnabled()) return jsonError(404, 'not found')
  const { account } = (await request.json()) as { account?: unknown }
  if (typeof account !== 'string' || !isAddress(account)) return jsonError(400, 'invalid account')
  try {
    const hash = await sendFromUnlocked(deployment().admin, account, accountAbi, 'executeRecovery', [])
    return Response.json({ hash })
  } catch (error) {
    return jsonError(409, error instanceof Error ? error.message : 'executeRecovery failed')
  }
}
