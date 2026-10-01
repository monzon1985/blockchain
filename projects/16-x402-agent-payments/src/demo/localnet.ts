// SPDX-License-Identifier: MIT
/**
 * Local chain orchestration: spawns anvil on an OS-assigned port (`--port 0`, read back from its banner), deploys
 * the contracts with `forge script` from an unlocked anvil account (no private key on the command line), and stops
 * the child process by PID.
 */
import { spawn, type ChildProcess } from 'node:child_process';
import { existsSync, rmSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { loadDeployment, type Deployment } from '../chain/deployment.js';

export const PROJECT_ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
export const CONTRACTS_DIR = join(PROJECT_ROOT, 'contracts');

export interface Anvil {
  readonly rpcUrl: string;
  readonly port: number;
  readonly pid: number;
  stop(): Promise<void>;
}

const LISTENING_RE = /Listening on (?:[\d.]+|\[[^\]]*\]):(\d+)/;

function waitForExit(child: ChildProcess): Promise<void> {
  return new Promise((resolve) => {
    if (child.exitCode !== null || child.signalCode !== null) {
      resolve();
      return;
    }
    child.once('exit', () => {
      resolve();
    });
  });
}

/** Starts anvil on a free port chosen by the OS. */
export async function startAnvil(timeoutMs = 30_000): Promise<Anvil> {
  const child = spawn(
    'anvil',
    ['--port', '0', '--host', '127.0.0.1', '--chain-id', '31337', '--hardfork', 'osaka'],
    {
      stdio: ['ignore', 'pipe', 'pipe'],
    },
  );
  const port = await new Promise<number>((resolve, reject) => {
    let output = '';
    const timer = setTimeout(() => {
      reject(new Error(`anvil did not start within ${timeoutMs} ms:\n${output}`));
    }, timeoutMs);
    const onData = (chunk: Buffer): void => {
      output += chunk.toString();
      const match = LISTENING_RE.exec(output);
      if (match?.[1] !== undefined) {
        clearTimeout(timer);
        resolve(Number(match[1]));
      }
    };
    child.stdout.on('data', onData);
    child.stderr.on('data', onData);
    child.once('error', (error) => {
      clearTimeout(timer);
      reject(error);
    });
    child.once('exit', (code) => {
      clearTimeout(timer);
      reject(new Error(`anvil exited early with code ${String(code)}:\n${output}`));
    });
  });
  // Keep draining stdout so anvil never blocks on a full pipe.
  child.stdout.resume();
  child.stderr.resume();
  const pid = child.pid;
  if (pid === undefined) throw new Error('anvil has no pid');
  return {
    rpcUrl: `http://127.0.0.1:${port}`,
    port,
    pid,
    async stop() {
      // Kill exactly this child (by PID), never by image name: other anvils on the machine are not ours.
      child.kill();
      await waitForExit(child);
    },
  };
}

function run(command: string, args: readonly string[], env: NodeJS.ProcessEnv, cwd: string): Promise<string> {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      cwd,
      env: { ...process.env, ...env },
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let output = '';
    child.stdout.on('data', (chunk: Buffer) => (output += chunk.toString()));
    child.stderr.on('data', (chunk: Buffer) => (output += chunk.toString()));
    child.once('error', reject);
    child.once('exit', (code) => {
      if (code === 0) resolve(output);
      else reject(new Error(`${command} ${args.join(' ')} exited with ${String(code)}:\n${output}`));
    });
  });
}

/**
 * Deploys the stack with `forge script script/Deploy.s.sol` against `rpcUrl`, broadcasting from the unlocked anvil
 * account `deployer`, and returns the address book the script wrote.
 */
export async function deployContracts(rpcUrl: string, deployer: string, name: string): Promise<Deployment> {
  await run(
    'forge',
    [
      'script',
      'script/Deploy.s.sol:Deploy',
      '--rpc-url',
      rpcUrl,
      '--broadcast',
      '--unlocked',
      '--sender',
      deployer,
      '--non-interactive',
    ],
    { DEPLOYMENT_NAME: name },
    CONTRACTS_DIR,
  );
  const path = join(CONTRACTS_DIR, 'deployments', `${name}.json`);
  if (!existsSync(path)) throw new Error(`deploy script did not write ${path}`);
  const deployment = loadDeployment(path);
  rmSync(path, { force: true });
  return deployment;
}
