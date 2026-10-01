// SPDX-License-Identifier: MIT
import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    include: ["test/**/*.test.ts"],
    environment: "node",
    pool: "forks",
    // The solver tests drive real viem clients against fake chains; a tick is fast but not instant.
    testTimeout: 60_000,
  },
});
