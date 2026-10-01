// SPDX-License-Identifier: MIT
// Playwright webServer: a fresh anvil on a free port, the forge deploy, then `next build` and `next start` on the
// port Playwright chose (E2E_PORT). Writes .e2e/runtime.json so the specs can reach the same chain.
// E2E_SKIP_BUILD=1 reuses the existing .next production build (CI builds it in the step before; the build does not
// depend on the chain, which the server reads per request).
import { spawn, spawnSync } from 'node:child_process'
import { existsSync, mkdirSync, writeFileSync } from 'node:fs'
import path from 'node:path'

import {
  ANVIL_ACCOUNTS,
  WEB_DIR,
  appEnv,
  deployLocal,
  nextBin,
  onShutdown,
  rpc,
  startAnvil,
  stopProcess,
} from './lib/chain.mjs'

const port = process.env.E2E_PORT
if (!port) throw new Error('E2E_PORT is not set (it is chosen by playwright.config.ts)')

const children = []
onShutdown(() => {
  for (const child of children.reverse()) stopProcess(child)
})

const e2eDir = path.join(WEB_DIR, '.e2e')
mkdirSync(e2eDir, { recursive: true })

const anvil = await startAnvil()
children.push(anvil.child)
const deploymentFile = path.join(e2eDir, 'deployment.json')
const manifest = deployLocal(anvil.url, deploymentFile)
// Baseline snapshot: every spec reverts to it, so specs are independent of each other and of execution order.
const baseline = await rpc(anvil.url, 'evm_snapshot')
writeFileSync(
  path.join(e2eDir, 'runtime.json'),
  JSON.stringify({ rpcUrl: anvil.url, baseline, accounts: ANVIL_ACCOUNTS, manifest }, null, 2),
)
console.log(`[e2e-chain] anvil ${anvil.url}, router ${manifest.router}`)

const env = { ...process.env, ...appEnv(anvil.url, deploymentFile) }
if (process.env.E2E_SKIP_BUILD === '1') {
  if (!existsSync(path.join(WEB_DIR, '.next', 'BUILD_ID'))) {
    stopProcess(anvil.child)
    throw new Error('E2E_SKIP_BUILD=1 but there is no production build in .next (run `npm run build` first)')
  }
  console.log('[e2e-chain] E2E_SKIP_BUILD=1: reusing the existing .next production build')
} else {
  const build = spawnSync(process.execPath, [nextBin(), 'build'], { cwd: WEB_DIR, stdio: 'inherit', env })
  if (build.status !== 0) {
    stopProcess(anvil.child)
    process.exit(build.status ?? 1)
  }
}

const server = spawn(process.execPath, [nextBin(), 'start', '--port', port, '--hostname', '127.0.0.1'], {
  cwd: WEB_DIR,
  stdio: 'inherit',
  env,
})
children.push(server)
server.on('exit', (code) => process.exit(code ?? 0))
