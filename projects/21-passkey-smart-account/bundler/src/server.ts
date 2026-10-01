// SPDX-License-Identifier: MIT
import { createServer, type IncomingMessage, type Server, type ServerResponse } from 'node:http'
import type { AddressInfo } from 'node:net'
import { numberToHex } from 'viem'

import type { BundlerLite } from './bundler.ts'
import { RpcError, RpcErrorCode } from './errors.ts'

interface JsonRpcRequest {
  jsonrpc?: string
  id?: string | number | null
  method?: unknown
  params?: unknown
}

type JsonRpcResponse =
  | { jsonrpc: '2.0'; id: string | number | null; result: unknown }
  | { jsonrpc: '2.0'; id: string | number | null; error: { code: number; message: string; data?: unknown } }

const MAX_BODY_BYTES = 1_000_000

function params(req: JsonRpcRequest): unknown[] {
  return Array.isArray(req.params) ? req.params : []
}

/** Dispatches one JSON-RPC request to the bundler. */
export async function dispatch(bundler: BundlerLite, req: JsonRpcRequest): Promise<unknown> {
  const p = params(req)
  switch (req.method) {
    case 'eth_chainId':
      return numberToHex(await bundler.chainId())
    case 'eth_supportedEntryPoints':
      return bundler.supportedEntryPoints()
    case 'eth_sendUserOperation':
      return bundler.sendUserOperation(p[0], p[1])
    case 'eth_estimateUserOperationGas': {
      const gas = await bundler.estimateUserOperationGas(p[0], p[1], p[2])
      return Object.fromEntries(
        Object.entries(gas)
          .filter(([, v]) => v !== undefined)
          .map(([k, v]) => [k, numberToHex(v as bigint)]),
      )
    }
    case 'eth_getUserOperationReceipt':
      return bundler.getUserOperationReceipt(p[0])
    case 'eth_getUserOperationByHash':
      return bundler.getUserOperationByHash(p[0])
    default:
      throw new RpcError(RpcErrorCode.MethodNotFound, `method ${String(req.method)} not supported by bundler-lite`)
  }
}

async function handleOne(bundler: BundlerLite, req: JsonRpcRequest): Promise<JsonRpcResponse> {
  const id = req.id ?? null
  try {
    if (typeof req.method !== 'string') throw new RpcError(RpcErrorCode.InvalidRequest, 'missing method')
    return { jsonrpc: '2.0', id, result: await dispatch(bundler, req) }
  } catch (error) {
    if (error instanceof RpcError) {
      return {
        jsonrpc: '2.0',
        id,
        error: { code: error.code, message: error.message, ...(error.data === undefined ? {} : { data: error.data }) },
      }
    }
    const message = error instanceof Error ? error.message : String(error)
    return { jsonrpc: '2.0', id, error: { code: RpcErrorCode.Internal, message } }
  }
}

function readBody(req: IncomingMessage): Promise<string> {
  return new Promise((resolve, reject) => {
    let size = 0
    const chunks: Buffer[] = []
    req.on('data', (chunk: Buffer) => {
      size += chunk.length
      if (size > MAX_BODY_BYTES) {
        reject(new RpcError(RpcErrorCode.InvalidRequest, 'request body too large'))
        req.destroy()
        return
      }
      chunks.push(chunk)
    })
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')))
    req.on('error', reject)
  })
}

function reply(res: ServerResponse, status: number, body: unknown): void {
  res.writeHead(status, {
    'content-type': 'application/json',
    'access-control-allow-origin': '*',
    'access-control-allow-headers': 'content-type',
    'access-control-allow-methods': 'POST, OPTIONS',
  })
  res.end(
    body === undefined
      ? undefined
      : JSON.stringify(body, (_key, value: unknown) => (typeof value === 'bigint' ? numberToHex(value) : value)),
  )
}

export interface RunningServer {
  readonly url: string
  readonly port: number
  readonly server: Server
  close(): Promise<void>
}

/** Starts the JSON-RPC HTTP server. `port: 0` lets the OS pick a free port. */
export async function startBundlerServer(bundler: BundlerLite, port = 0, host = '127.0.0.1'): Promise<RunningServer> {
  const server = createServer((req, res) => {
    if (req.method === 'OPTIONS') {
      reply(res, 204, undefined)
      return
    }
    if (req.method !== 'POST') {
      reply(res, 405, { error: 'POST only' })
      return
    }
    readBody(req)
      .then(async (text) => {
        let payload: unknown
        try {
          payload = JSON.parse(text)
        } catch {
          reply(res, 200, { jsonrpc: '2.0', id: null, error: { code: -32700, message: 'parse error' } })
          return
        }
        if (Array.isArray(payload)) {
          reply(res, 200, await Promise.all(payload.map((r) => handleOne(bundler, r as JsonRpcRequest))))
          return
        }
        reply(res, 200, await handleOne(bundler, payload as JsonRpcRequest))
      })
      .catch((error: unknown) => reply(res, 413, { error: String(error) }))
  })
  await new Promise<void>((resolve) => server.listen(port, host, resolve))
  const actualPort = (server.address() as AddressInfo).port
  return {
    url: `http://${host}:${actualPort}`,
    port: actualPort,
    server,
    close: () =>
      new Promise<void>((resolve, reject) => {
        server.closeAllConnections()
        server.close((err) => (err === undefined ? resolve() : reject(err)))
      }),
  }
}
