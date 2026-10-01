// SPDX-License-Identifier: MIT
import { isAddress } from 'viem'

import { erc20Abi } from '@/lib/abis'
import { deployment, devToolsEnabled } from '@/lib/server/env'
import { jsonError } from '@/lib/server/http'
import { sendFromUnlocked } from '@/lib/server/node'

export const dynamic = 'force-dynamic'

/** Mints 100 TestUSD (a valueless local test token) to an address. */
export async function POST(request: Request): Promise<Response> {
  if (!devToolsEnabled()) return jsonError(404, 'not found')
  const { to } = (await request.json()) as { to?: unknown }
  if (typeof to !== 'string' || !isAddress(to)) return jsonError(400, 'invalid address')
  const d = deployment()
  const hash = await sendFromUnlocked(d.admin, d.testUsd, erc20Abi, 'mint', [to, 100_000_000n])
  return Response.json({ hash })
}
