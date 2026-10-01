// SPDX-License-Identifier: MIT
import { connection } from 'next/server'

/** Readiness probe used by the Playwright webServer. */
export async function GET() {
  await connection()
  return Response.json({ ok: true })
}
