// SPDX-License-Identifier: MIT
import { devToolsEnabled } from '@/lib/server/env'
import { jsonError } from '@/lib/server/http'
import { nodeRpc } from '@/lib/server/node'

export const dynamic = 'force-dynamic'

const MAX_SECONDS = 30 * 86_400

/** Moves the devnet clock forward (used to demonstrate the 48 hour recovery timelock). */
export async function POST(request: Request): Promise<Response> {
  if (!devToolsEnabled()) return jsonError(404, 'not found')
  const { seconds } = (await request.json()) as { seconds?: unknown }
  if (typeof seconds !== 'number' || !Number.isInteger(seconds) || seconds <= 0 || seconds > MAX_SECONDS) {
    return jsonError(400, 'seconds must be a positive integer up to 30 days')
  }
  await nodeRpc('evm_increaseTime', [seconds])
  await nodeRpc('evm_mine', [])
  return Response.json({ ok: true })
}
