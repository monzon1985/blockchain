// SPDX-License-Identifier: MIT
import { spawn, type ChildProcess } from 'node:child_process'

/** A running local anvil node. */
export interface AnvilInstance {
  readonly rpcUrl: string
  readonly port: number
  readonly process: ChildProcess
  stop(): Promise<void>
}

export interface AnvilOptions {
  /** EVM hardfork. Osaka enables the EIP-7951 P-256 precompile at 0x100. */
  readonly hardfork?: string
  readonly chainId?: number
  /** Path to the anvil binary (defaults to `anvil` on PATH). */
  readonly binary?: string
  readonly extraArgs?: readonly string[]
  readonly startupTimeoutMs?: number
}

/**
 * Starts anvil on an OS-assigned port (`--port 0`) and resolves once it prints its listening address. The caller
 * owns the returned process and must call `stop()`; it is killed by PID only.
 */
export async function startAnvil(options: AnvilOptions = {}): Promise<AnvilInstance> {
  const args = [
    '--host',
    '127.0.0.1',
    '--port',
    '0',
    '--hardfork',
    options.hardfork ?? 'osaka',
    '--chain-id',
    String(options.chainId ?? 31337),
    // EntryPoint v0.9 and the account stay well under 24 KiB; the limit stays enforced.
    ...(options.extraArgs ?? []),
  ]
  const child = spawn(options.binary ?? 'anvil', args, { stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true })
  const timeoutMs = options.startupTimeoutMs ?? 30_000

  const port = await new Promise<number>((resolve, reject) => {
    let buffer = ''
    const timer = setTimeout(() => {
      child.kill()
      reject(new Error(`anvil did not start within ${timeoutMs} ms`))
    }, timeoutMs)
    const onData = (chunk: Buffer): void => {
      buffer += chunk.toString('utf8')
      const match = /Listening on 127\.0\.0\.1:(\d+)/.exec(buffer)
      if (match?.[1] !== undefined) {
        clearTimeout(timer)
        child.stdout.off('data', onData)
        resolve(Number(match[1]))
      }
    }
    child.stdout.on('data', onData)
    child.stderr.on('data', (chunk: Buffer) => {
      buffer += chunk.toString('utf8')
    })
    child.once('error', (err) => {
      clearTimeout(timer)
      reject(err)
    })
    child.once('exit', (code) => {
      clearTimeout(timer)
      reject(new Error(`anvil exited early with code ${String(code)}: ${buffer.slice(-2000)}`))
    })
  })
  // Keep draining output so the pipe never fills up.
  child.stdout.resume()
  child.stderr.resume()

  return {
    rpcUrl: `http://127.0.0.1:${port}`,
    port,
    process: child,
    stop: () => stopProcess(child),
  }
}

/** Terminates a child process by PID and waits for it to exit. */
export async function stopProcess(child: ChildProcess): Promise<void> {
  if (child.exitCode !== null || child.signalCode !== null) return
  await new Promise<void>((resolve) => {
    const timer = setTimeout(resolve, 5_000)
    child.once('exit', () => {
      clearTimeout(timer)
      resolve()
    })
    child.kill()
  })
}
