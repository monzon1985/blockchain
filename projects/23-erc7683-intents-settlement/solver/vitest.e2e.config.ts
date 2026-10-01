// SPDX-License-Identifier: MIT
import { defineConfig } from "vitest/config";

// Two anvil chains per test file, so files run one at a time and tests inside a file run in order.
export default defineConfig({
  test: {
    include: ["e2e/**/*.e2e.test.ts"],
    environment: "node",
    pool: "forks",
    fileParallelism: false,
    sequence: { concurrent: false },
    testTimeout: 180_000,
    hookTimeout: 180_000,
  },
});
