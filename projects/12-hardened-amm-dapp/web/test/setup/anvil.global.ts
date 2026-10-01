// SPDX-License-Identifier: MIT
// Vitest global setup: one fresh anvil on a free port and one forge deployment, shared by every test file.
import { rmSync } from 'node:fs'
import path from 'node:path'

import type { TestProject } from 'vitest/node'

import { WEB_DIR, deployLocal, startAnvil } from '../../scripts/lib/chain.mjs'

declare module 'vitest' {
  export interface ProvidedContext {
    rpcUrl: string
    manifest: unknown
  }
}

export default async function setup(project: TestProject) {
  // Load jsdom once in the main process before any worker starts. Vitest gives a worker a fixed 60 s to set up its
  // test environment; right after `npm ci` on Windows, the first read of jsdom's files (each scanned on access by the
  // antivirus) can exceed that on a busy machine. Afterwards the files come from the OS cache. (A variable specifier
  // keeps this a plain runtime import: jsdom ships no type declarations and none are needed here.)
  const testEnvironment = 'jsdom'
  await import(testEnvironment)

  const anvil = await startAnvil()
  const manifestFile = path.join(WEB_DIR, 'deployments', `vitest-${process.pid}.json`)
  try {
    const manifest = deployLocal(anvil.url, manifestFile)
    project.provide('rpcUrl', anvil.url)
    project.provide('manifest', manifest)
  } catch (error) {
    anvil.stop()
    throw error
  }
  return () => {
    anvil.stop()
    rmSync(manifestFile, { force: true })
  }
}
