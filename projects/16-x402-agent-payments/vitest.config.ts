// SPDX-License-Identifier: MIT
import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    projects: [
      {
        test: {
          name: 'unit',
          include: ['test/**/*.test.ts'],
          environment: 'node',
        },
      },
      {
        test: {
          name: 'e2e',
          include: ['e2e/**/*.e2e.test.ts'],
          environment: 'node',
          // Each e2e file boots its own anvil, deploys with `forge script` and serves both apps on port 0.
          testTimeout: 120_000,
          hookTimeout: 300_000,
          fileParallelism: false,
        },
      },
    ],
    coverage: {
      provider: 'v8',
      include: ['src/**/*.ts'],
      exclude: ['src/chain/abis.ts', 'src/demo/cli.ts'],
      reporter: ['text-summary', 'text'],
      // Enforced on `npm run coverage` (unit + e2e); the unit project alone does not reach the agent/server code.
      thresholds: { lines: 90, statements: 90, functions: 90 },
    },
  },
});
