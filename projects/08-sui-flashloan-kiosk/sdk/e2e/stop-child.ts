// SPDX-License-Identifier: MIT
//
// Stops a child process by PID, escalating when it does not exit on its own.
// Used by the localnet harness for `sui start`, so a hung node can never
// outlive the test run.

import { type ChildProcess, execFile } from 'node:child_process';

/** `true` once `child` has exited (immediately if it already has), `false` after `ms`. */
function exitWithin(child: ChildProcess, ms: number): Promise<boolean> {
  if (child.exitCode !== null || child.signalCode !== null) return Promise.resolve(true);
  return new Promise((resolve) => {
    const onExit = (): void => {
      clearTimeout(timer);
      resolve(true);
    };
    const timer = setTimeout(() => {
      child.off('exit', onExit);
      resolve(false);
    }, ms);
    child.once('exit', onExit);
  });
}

/** Force-kills `pid` and its descendants: `taskkill /T /F` on Windows, SIGKILL elsewhere. */
function forceKill(child: ChildProcess): Promise<void> {
  const { pid } = child;
  if (process.platform !== 'win32' || pid === undefined) {
    child.kill('SIGKILL');
    return Promise.resolve();
  }
  return new Promise((resolve) => {
    execFile('taskkill', ['/PID', String(pid), '/T', '/F'], () => {
      resolve();
    });
  });
}

/**
 * Asks `child` to stop (SIGTERM) and waits up to `graceMs` for it to exit. If it
 * is still running, kills it by PID (with its descendants on Windows) and waits
 * again; throws if even that does not stop it.
 */
export async function stopChild(child: ChildProcess, graceMs = 10_000): Promise<void> {
  if (await exitWithin(child, 0)) return;
  child.kill('SIGTERM');
  if (await exitWithin(child, graceMs)) return;
  await forceKill(child);
  if (!(await exitWithin(child, graceMs))) {
    throw new Error(`process ${String(child.pid)} is still running after a forced kill`);
  }
}
