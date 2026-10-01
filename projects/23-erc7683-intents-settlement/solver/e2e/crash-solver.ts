// SPDX-License-Identifier: MIT
// TEST-ONLY entry point for the crash-recovery e2e: the production solver (same actor code as src/main.ts) plus a
// fault-injection hook that kills the process at a checkpoint. It is never shipped as a CLI; src/main.ts has no
// such hook and ignores any crash-related environment.
//
//   node e2e/crash-solver.ts --config <file> --crash-at after-fill-persist|after-fill-broadcast
import { parseArgs } from "node:util";

import { buildActor, runActor } from "../src/actors.ts";
import { loadSolverConfig } from "../src/config.ts";
import { createLogger } from "../src/log.ts";
import { CHECKPOINTS, type Checkpoint } from "../src/solver.ts";

const { values } = parseArgs({
  options: {
    config: { type: "string" },
    "crash-at": { type: "string" },
  },
});
if (values.config === undefined) throw new Error("--config <file> is required");
const crashAt = CHECKPOINTS.find((c: Checkpoint) => c === values["crash-at"]);
if (crashAt === undefined) {
  throw new Error(`--crash-at must be one of ${CHECKPOINTS.join(", ")}`);
}
const config = loadSolverConfig(values.config);
const log = createLogger({ role: "solver", testBuild: true });
log.warn("TEST BUILD: crash injection armed", { crashAt });
const actor = buildActor("solver", config, log, {
  onCheckpoint: (point) => {
    if (point !== crashAt) return;
    log.warn("crash injected", { point });
    // A hard kill, like `kill -9` or a power cut: no cleanup, no flushing beyond what is already durable.
    process.kill(process.pid, "SIGKILL");
  },
});
await runActor(actor, config, log);
