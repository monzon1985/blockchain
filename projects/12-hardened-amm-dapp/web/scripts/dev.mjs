// SPDX-License-Identifier: MIT
// Local development: boots anvil on a free port, deploys the protocol and demo pools with the forge script, writes
// deployments/local.json and starts `next dev` on another free port. Ctrl+C stops everything it started.
//
//   node scripts/dev.mjs
import { spawn } from 'node:child_process'
import path from 'node:path'

import { WEB_DIR, appEnv, deployLocal, freePort, nextBin, onShutdown, startAnvil, stopProcess } from './lib/chain.mjs'

const children = []
onShutdown(() => {
  for (const child of children.reverse()) stopProcess(child)
})

const anvil = await startAnvil()
children.push(anvil.child)
console.log(`anvil         ${anvil.url} (chain id 31337)`)

const deploymentFile = path.join(WEB_DIR, 'deployments', 'local.json')
const manifest = deployLocal(anvil.url, deploymentFile)
console.log(`deployed      factory ${manifest.factory}, router ${manifest.router}`)
console.log(`manifest      ${path.relative(WEB_DIR, deploymentFile)}`)

const port = await freePort()
const next = spawn(process.execPath, [nextBin(), 'dev', '--port', String(port), '--hostname', '127.0.0.1'], {
  cwd: WEB_DIR,
  stdio: 'inherit',
  env: { ...process.env, ...appEnv(anvil.url, deploymentFile) },
})
children.push(next)
console.log(`dApp          http://127.0.0.1:${port}  (connect with "Anvil test account")`)

next.on('exit', (code) => process.exit(code ?? 0))
