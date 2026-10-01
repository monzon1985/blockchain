// SPDX-License-Identifier: MIT
// Shared local-chain orchestration for scripts/dev.mjs, scripts/e2e-chain.mjs and the anvil-backed vitest suites.
// Ports are never hard-coded: every server binds a port the OS just reported as free.
import { spawn, spawnSync } from 'node:child_process'
import { copyFileSync, mkdirSync, readFileSync, rmSync } from 'node:fs'
import net from 'node:net'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

export const WEB_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..')
export const CONTRACTS_DIR = path.resolve(WEB_DIR, '..', 'contracts')

/**
 * Public addresses of anvil's default dev accounts (derived from the well-known test mnemonic). anvil keeps them
 * unlocked, so the deploy script and the dApp's mock connector use them through RPC; no key material is needed.
 * #0 deploys and seeds the pools, #1 is the dApp user, #2 plays the front-runner in the e2e slippage test.
 */
export const ANVIL_ACCOUNTS = Object.freeze([
  '0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266',
  '0x70997970C51812dc3A010C7d01b50e0d17dc79C8',
  '0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC',
  '0x90F79bf6EB2c4f870365E785982E1f101E93b906',
])

/** Asks the OS for a free TCP port on the loopback interface. */
export function freePort() {
  return new Promise((resolve, reject) => {
    const server = net.createServer()
    server.unref()
    server.on('error', reject)
    server.listen(0, '127.0.0.1', () => {
      const { port } = server.address()
      server.close(() => resolve(port))
    })
  })
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

/** Minimal JSON-RPC call (used before viem is available, e.g. while waiting for anvil). */
export async function rpc(url, method, params = []) {
  const response = await fetch(url, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }),
  })
  const body = await response.json()
  if (body.error) throw new Error(`${method}: ${body.error.message}`)
  return body.result
}

/** Terminates a child process and its descendants, by PID only. */
export function stopProcess(child) {
  if (!child || child.exitCode !== null || child.signalCode !== null) return
  if (process.platform === 'win32') {
    spawnSync('taskkill', ['/PID', String(child.pid), '/T', '/F'], { stdio: 'ignore' })
  } else {
    child.kill('SIGTERM')
  }
}

/** Starts anvil on a free port and resolves once it answers JSON-RPC. */
export async function startAnvil({ log = false } = {}) {
  const port = await freePort()
  const url = `http://127.0.0.1:${port}`
  const child = spawn('anvil', ['--host', '127.0.0.1', '--port', String(port), '--chain-id', '31337'], {
    stdio: log ? 'inherit' : 'ignore',
  })
  let exited = false
  child.on('exit', () => {
    exited = true
  })
  for (let attempt = 0; attempt < 200; attempt++) {
    if (exited) throw new Error('anvil exited during startup (is Foundry installed and on PATH?)')
    try {
      await rpc(url, 'eth_chainId')
      return { url, port, child, stop: () => stopProcess(child) }
    } catch {
      await sleep(100)
    }
  }
  stopProcess(child)
  throw new Error(`anvil did not start on ${url}`)
}

/**
 * Runs script/DeployLocal.s.sol against `rpcUrl` with anvil's unlocked deployer account and copies the manifest to
 * `outFile` (absolute). Returns the parsed manifest.
 */
export function deployLocal(rpcUrl, outFile, { log = false } = {}) {
  const manifestName = `deployments/${path.basename(outFile, '.json')}-${process.pid}.json`
  mkdirSync(path.join(CONTRACTS_DIR, 'deployments'), { recursive: true })
  const result = spawnSync(
    'forge',
    [
      'script',
      'script/DeployLocal.s.sol:DeployLocal',
      '--rpc-url',
      rpcUrl,
      '--broadcast',
      '--unlocked',
      '--sender',
      ANVIL_ACCOUNTS[0],
      '--slow',
    ],
    {
      cwd: CONTRACTS_DIR,
      encoding: 'utf8',
      env: {
        ...process.env,
        AMM_FUND_ACCOUNTS: ANVIL_ACCOUNTS.slice(1).join(','),
        AMM_DEPLOYMENT_OUT: manifestName,
      },
      maxBuffer: 64 * 1024 * 1024,
    },
  )
  if (log || result.status !== 0) {
    process.stdout.write(result.stdout ?? '')
    process.stderr.write(result.stderr ?? '')
  }
  if (result.status !== 0) throw new Error(`forge script failed with exit code ${result.status}`)
  const source = path.join(CONTRACTS_DIR, manifestName)
  mkdirSync(path.dirname(outFile), { recursive: true })
  copyFileSync(source, outFile)
  rmSync(source, { force: true })
  return JSON.parse(readFileSync(outFile, 'utf8'))
}

/** Path of the Next.js CLI entry point, so it can be spawned with node directly (no shell, no .cmd shims). */
export function nextBin() {
  return path.join(WEB_DIR, 'node_modules', 'next', 'dist', 'bin', 'next')
}

/** Environment consumed by src/lib/runtime-config.ts on the Next.js server. */
export function appEnv(rpcUrl, deploymentFile) {
  return {
    AMM_RPC_URL: rpcUrl,
    AMM_DEPLOYMENT_FILE: deploymentFile,
    AMM_ENABLE_MOCK_CONNECTOR: '1',
    AMM_MOCK_ACCOUNTS: ANVIL_ACCOUNTS.slice(1).join(','),
  }
}

/** Registers cleanup for every exit path of a long-running orchestrator. */
export function onShutdown(cleanup) {
  let done = false
  const run = (code) => {
    if (done) return
    done = true
    try {
      cleanup()
    } finally {
      if (code !== undefined) process.exit(code)
    }
  }
  process.on('SIGINT', () => run(130))
  process.on('SIGTERM', () => run(143))
  process.on('SIGHUP', () => run(129))
  process.on('exit', () => run())
  process.on('uncaughtException', (error) => {
    console.error(error)
    run(1)
  })
}
