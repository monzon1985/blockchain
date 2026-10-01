// SPDX-License-Identifier: MIT
import { defineConfig } from 'vitest/config'

export default defineConfig({
  test: {
    include: ['test/**/*.test.ts'],
    // Integration tests start their own anvil instances on random ports; keep a small pool to be a good neighbour.
    pool: 'forks',
    maxWorkers: 4,
    testTimeout: 120_000,
    hookTimeout: 120_000,
  },
})
