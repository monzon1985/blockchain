// SPDX-License-Identifier: MIT
// The localnet harness's process teardown (sdk/e2e/stop-child.ts).
import { type ChildProcess, spawn } from 'node:child_process';
import { once } from 'node:events';
import { describe, expect, it } from 'vitest';
import { stopChild } from '../e2e/stop-child.js';

/** Spawns a Node child running `script` and resolves once it printed "ready". */
async function nodeChild(script: string): Promise<ChildProcess> {
  const child = spawn(process.execPath, ['-e', script], { stdio: ['ignore', 'pipe', 'ignore'] });
  await once(child.stdout, 'data');
  return child;
}

const isRunning = (child: ChildProcess): boolean => child.exitCode === null && child.signalCode === null;

describe('stopChild', () => {
  it('stops a cooperative process with SIGTERM', async () => {
    const child = await nodeChild("setInterval(() => {}, 1000); console.log('ready');");
    await stopChild(child, 5_000);
    expect(isRunning(child)).toBe(false);
  });

  // On POSIX the child survives SIGTERM, so only the escalation can stop it.
  // (On Windows `kill('SIGTERM')` already terminates the process forcibly.)
  it('escalates to a forced kill when the process ignores SIGTERM', async () => {
    const child = await nodeChild(
      "process.on('SIGTERM', () => {}); setInterval(() => {}, 1000); console.log('ready');",
    );
    await stopChild(child, 300);
    expect(isRunning(child)).toBe(false);
  });

  it('returns at once for a process that has already exited', async () => {
    const child = await nodeChild("console.log('ready');");
    if (isRunning(child)) await once(child, 'exit');
    const started = Date.now();
    await stopChild(child, 5_000);
    expect(Date.now() - started).toBeLessThan(1_000);
  });
});
