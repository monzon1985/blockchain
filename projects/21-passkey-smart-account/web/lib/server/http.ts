// SPDX-License-Identifier: MIT
import 'server-only'

export function jsonError(status: number, message: string): Response {
  return Response.json({ error: message }, { status })
}

/** Forwards a JSON-RPC request (single or batch) upstream after checking every method against an allowlist. */
export async function forwardJsonRpc(request: Request, upstream: string, allowed: ReadonlySet<string>): Promise<Response> {
  let payload: unknown
  try {
    payload = await request.json()
  } catch {
    return Response.json({ jsonrpc: '2.0', id: null, error: { code: -32700, message: 'parse error' } })
  }
  const calls = Array.isArray(payload) ? payload : [payload]
  for (const call of calls) {
    const method = (call as { method?: unknown }).method
    if (typeof method !== 'string' || !allowed.has(method)) {
      const callId = (call as { id?: unknown }).id ?? null
      return Response.json({ jsonrpc: '2.0', id: callId, error: { code: -32601, message: `method not allowed: ${String(method)}` } })
    }
  }
  const upstreamResponse = await fetch(upstream, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(payload),
    cache: 'no-store',
  })
  return new Response(await upstreamResponse.text(), {
    status: upstreamResponse.status,
    headers: { 'content-type': 'application/json' },
  })
}
