// SPDX-License-Identifier: MIT
import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    projects: [
      {
        test: {
          name: 'unit',
          include: ['sdk/test/**/*.test.ts'],
          environment: 'node',
        },
      },
      {
        test: {
          name: 'e2e',
          include: ['sdk/e2e/**/*.e2e.test.ts'],
          environment: 'node',
          // The suite boots `sui start --force-regenesis` on free ports, publishes
          // both Move packages and drives them through real transactions.
          testTimeout: 180_000,
          hookTimeout: 600_000,
          fileParallelism: false,
        },
      },
    ],
    coverage: {
      provider: 'v8',
      include: ['sdk/src/**/*.ts'],
      reporter: ['text-summary', 'text'],
      thresholds: { lines: 90, statements: 90, functions: 90, branches: 85 },
    },
  },
});
