// SPDX-License-Identifier: MIT
// Server-side only: reads the chain endpoint and the deployment manifest at request time, so one `next build`
// works against any anvil port and any fresh deployment.
import { readFile } from 'node:fs/promises'
import path from 'node:path'

import { getAddress, isAddress, type Address } from 'viem'

import { parseDeployment } from './manifest'
import type { RuntimeConfig } from './types'

export type RuntimeConfigResult = { ok: true; config: RuntimeConfig } | { ok: false; reason: string }

export async function loadRuntimeConfig(): Promise<RuntimeConfigResult> {
  const rpcUrl = process.env['AMM_RPC_URL']
  if (!rpcUrl) {
    return { ok: false, reason: 'AMM_RPC_URL is not set. Start the local stack with `npm run dev`.' }
  }
  // The manifest path is runtime configuration, not a bundled asset: keep the file tracer from following it.
  const file = path.resolve(
    /* turbopackIgnore: true */ process.cwd(),
    process.env['AMM_DEPLOYMENT_FILE'] ?? 'deployments/local.json',
  )
  let raw: unknown
  try {
    raw = JSON.parse(await readFile(file, 'utf8'))
  } catch {
    return { ok: false, reason: `No deployment manifest at ${file}. Start the local stack with \`npm run dev\`.` }
  }
  const mockEnabled = ['1', 'true'].includes(process.env['AMM_ENABLE_MOCK_CONNECTOR'] ?? '')
  const accounts: Address[] = (process.env['AMM_MOCK_ACCOUNTS'] ?? '')
    .split(',')
    .map((value) => value.trim())
    .filter((value) => isAddress(value))
    .map((value) => getAddress(value))
  try {
    return {
      ok: true,
      config: {
        rpcUrl,
        deployment: parseDeployment(raw),
        mockConnector: { enabled: mockEnabled && accounts.length > 0, accounts },
      },
    }
  } catch (error) {
    return { ok: false, reason: error instanceof Error ? error.message : String(error) }
  }
}
