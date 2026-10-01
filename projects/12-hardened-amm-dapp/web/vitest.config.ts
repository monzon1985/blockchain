// SPDX-License-Identifier: MIT
import path from 'node:path'

import react from '@vitejs/plugin-react'
import { defineConfig } from 'vitest/config'

export default defineConfig({
  plugins: [react()],
  resolve: { alias: { '@': path.resolve(import.meta.dirname, 'src') } },
  test: {
    include: ['test/**/*.test.{ts,tsx}'],
    environment: 'node',
    // One anvil + one forge deployment for the whole run (test/setup/anvil.global.ts); suites isolate themselves
    // with evm_snapshot / evm_revert, so files run one at a time against the shared chain.
    globalSetup: ['test/setup/anvil.global.ts'],
    fileParallelism: false,
    // Worker threads instead of child processes: on Windows a forked worker re-reads viem / wagmi / jsdom from disk
    // (about 70 s of module loading for this suite on a loaded machine, enough to hit Vitest's 60 s worker-start
    // timeout); threads bring the whole run down to about 20 s. Nothing here needs process isolation.
    pool: 'threads',
    testTimeout: 120_000,
    hookTimeout: 300_000,
  },
})
