// SPDX-License-Identifier: MIT
import { ConfigError, publicConfig } from '@/lib/server/env'
import { jsonError } from '@/lib/server/http'

export const dynamic = 'force-dynamic'

/** Public addresses of the connected devnet deployment. */
export function GET(): Response {
  try {
    return Response.json(publicConfig())
  } catch (error) {
    if (error instanceof ConfigError) return jsonError(503, error.message)
    throw error
  }
}
