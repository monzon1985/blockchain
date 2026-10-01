// SPDX-License-Identifier: MIT
import { defineConfig } from "vitest/config";

// Line coverage of the solver's production code over the unit AND e2e suites (`npm run coverage`). Files run one at
// a time because the e2e starts its own anvil chains. Excluded: the generated ABIs (src/abi.ts) and the CLI shim
// src/main.ts, which the e2e runs as a child process that V8 coverage does not follow (the actor code it calls,
// src/actors.ts, is covered in-process by test/actors.test.ts).
export default defineConfig({
  test: {
    include: ["test/**/*.test.ts", "e2e/**/*.e2e.test.ts"],
    environment: "node",
    pool: "forks",
    fileParallelism: false,
    sequence: { concurrent: false },
    testTimeout: 180_000,
    hookTimeout: 180_000,
    coverage: {
      provider: "v8",
      include: ["src/**/*.ts"],
      exclude: ["src/abi.ts", "src/main.ts"],
      reporter: ["text", "text-summary", "lcov"],
      reportsDirectory: "coverage",
      thresholds: { lines: 90 },
    },
  },
});
