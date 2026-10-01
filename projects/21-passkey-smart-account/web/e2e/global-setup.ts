// SPDX-License-Identifier: MIT
// Starts the devnet (anvil + EntryPoint v0.9 + bundler-lite) and the built wallet (`next start`) on OS-assigned
// ports, exports E2E_BASE_URL and E2E_RPC_URL, and returns the teardown that stops both by PID. Both processes log
// to .e2e/chain.log and .e2e/next.log (uploaded by CI when the e2e job fails).
import { spawn, spawnSync, type ChildProcess } from 'node:child_process'
import { createWriteStream, mkdirSync, writeFileSync, type WriteStream } from 'node:fs'
import net from 'node:net'
import path from 'node:path'

const webRoot = path.resolve(import.meta.dirname, '..')
const logDir = path.join(webRoot, '.e2e')

/** Appends a child's stdout and stderr to `.e2e/<name>.log`, keeping the pipes drained. */
function logTo(child: ChildProcess, name: string): WriteStream {
  const log = createWriteStream(path.join(logDir, `${name}.log`), { flags: 'w' })
  child.stdout?.pipe(log, { end: false })
  child.stderr?.pipe(log, { end: false })
  child.once('exit', () => log.end())
  return log
}

function freePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const server = net.createServer()
    server.once('error', reject)
    server.listen(0, '127.0.0.1', () => {
      const address = server.address()
      if (address === null || typeof address === 'string') return reject(new Error('no port'))
      server.close(() => resolve(address.port))
    })
  })
}

function waitForLine(child: ChildProcess, pattern: RegExp, timeoutMs: number): Promise<RegExpExecArray> {
  return new Promise((resolve, reject) => {
    let buffer = ''
    let errors = ''
    const timer = setTimeout(() => reject(new Error(`timed out waiting for ${pattern}\n${buffer}\n${errors}`)), timeoutMs)
    child.stdout?.on('data', (chunk: Buffer) => {
      buffer += chunk.toString()
      const match = pattern.exec(buffer)
      if (match !== null) {
        clearTimeout(timer)
        resolve(match)
      }
    })
    child.stderr?.on('data', (chunk: Buffer) => {
      errors += chunk.toString()
    })
    child.once('exit', (code) => {
      clearTimeout(timer)
      reject(new Error(`process exited with ${String(code)}\n${buffer}\n${errors}`))
    })
  })
}

async function waitForHttp(url: string, timeoutMs: number): Promise<void> {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    try {
      const response = await fetch(url)
      if (response.ok) return
    } catch {
      // not up yet
    }
    await new Promise((r) => setTimeout(r, 250))
  }
  throw new Error(`${url} did not come up`)
}

/** Kills a process and its children by PID only (never by image name: other tools may run anvil too). */
function killTree(child: ChildProcess): void {
  if (child.pid === undefined || child.exitCode !== null) return
  if (process.platform === 'win32') {
    spawnSync('taskkill', ['/PID', String(child.pid), '/T', '/F'], { stdio: 'ignore' })
  } else {
    try {
      process.kill(-child.pid, 'SIGTERM')
    } catch {
      child.kill('SIGTERM')
    }
  }
}

/** Child environment without Playwright's own loader hooks (NODE_OPTIONS), which must not leak into the servers. */
function childEnv(extra: Record<string, string> = {}): NodeJS.ProcessEnv {
  const env: NodeJS.ProcessEnv = { ...process.env, ...extra }
  delete env['NODE_OPTIONS']
  return env
}

export default async function globalSetup(): Promise<() => Promise<void>> {
  mkdirSync(logDir, { recursive: true })
  const detached = process.platform !== 'win32'
  const chain = spawn(process.execPath, ['scripts/e2e-chain.mjs'], {
    cwd: webRoot,
    stdio: ['ignore', 'pipe', 'pipe'],
    detached,
    windowsHide: true,
    env: childEnv(),
  })
  logTo(chain, 'chain')
  let match: RegExpExecArray
  try {
    match = await waitForLine(chain, /E2E_CHAIN_READY (.+)\n/, 180_000)
  } catch (error) {
    killTree(chain)
    throw error
  }
  const info = JSON.parse(match[1] ?? '{}') as { rpcUrl: string; bundlerUrl: string; deployment: unknown }

  const port = await freePort()
  const nextBin = path.join(webRoot, 'node_modules', 'next', 'dist', 'bin', 'next')
  const next = spawn(process.execPath, [nextBin, 'start', '--port', String(port), '--hostname', '127.0.0.1'], {
    cwd: webRoot,
    stdio: ['ignore', 'pipe', 'pipe'],
    detached,
    windowsHide: true,
    env: childEnv({
      WALLET_RPC_URL: info.rpcUrl,
      WALLET_BUNDLER_URL: info.bundlerUrl,
      WALLET_DEPLOYMENT: JSON.stringify(info.deployment),
      WALLET_DEV_TOOLS: '1',
    }),
  })
  logTo(next, 'next')

  const baseUrl = `http://localhost:${port}`
  try {
    await waitForHttp(`${baseUrl}/api/config`, 120_000)
  } catch (error) {
    killTree(next)
    killTree(chain)
    throw error
  }
  process.env['E2E_BASE_URL'] = baseUrl
  process.env['E2E_RPC_URL'] = info.rpcUrl
  writeFileSync(path.join(logDir, 'processes.json'), JSON.stringify({ chain: chain.pid, next: next.pid, baseUrl, ...info }, null, 2))

  return async () => {
    killTree(next)
    killTree(chain)
  }
}
