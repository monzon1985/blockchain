// SPDX-License-Identifier: MIT
// One-command local demo: starts the devnet (scripts/e2e-chain.mjs) and `next dev` on OS-assigned ports, wires them
// together through environment variables, and prints the URL to open. Ctrl+C stops everything (by PID).
import { spawn, spawnSync } from 'node:child_process'
import net from 'node:net'

function freePort() {
  return new Promise((resolve, reject) => {
    const server = net.createServer()
    server.once('error', reject)
    server.listen(0, '127.0.0.1', () => {
      const { port } = server.address()
      server.close(() => resolve(port))
    })
  })
}

function killTree(child) {
  if (child.pid === undefined || child.exitCode !== null) return
  if (process.platform === 'win32') spawnSync('taskkill', ['/PID', String(child.pid), '/T', '/F'], { stdio: 'ignore' })
  else child.kill('SIGTERM')
}

const env = { ...process.env }
delete env.NODE_OPTIONS

const chain = spawn(process.execPath, ['scripts/e2e-chain.mjs'], { stdio: ['ignore', 'pipe', 'inherit'], env })
const info = await new Promise((resolve, reject) => {
  let buffer = ''
  chain.stdout.on('data', (chunk) => {
    buffer += chunk.toString()
    const match = /E2E_CHAIN_READY (.+)\n/.exec(buffer)
    if (match) resolve(JSON.parse(match[1]))
  })
  chain.once('exit', (code) => reject(new Error(`devnet exited with ${code}`)))
})

const port = await freePort()
const next = spawn(process.execPath, ['node_modules/next/dist/bin/next', 'dev', '--port', String(port), '--hostname', '127.0.0.1'], {
  stdio: 'inherit',
  env: {
    ...env,
    WALLET_RPC_URL: info.rpcUrl,
    WALLET_BUNDLER_URL: info.bundlerUrl,
    WALLET_DEPLOYMENT: JSON.stringify(info.deployment),
    WALLET_DEV_TOOLS: '1',
  },
})

process.stdout.write(`\nDevnet RPC ${info.rpcUrl}, bundler-lite ${info.bundlerUrl}\nOpen http://localhost:${port}\n\n`)

const stop = () => {
  killTree(next)
  killTree(chain)
  process.exit(0)
}
process.on('SIGINT', stop)
process.on('SIGTERM', stop)
