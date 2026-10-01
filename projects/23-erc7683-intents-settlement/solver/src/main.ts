// SPDX-License-Identifier: MIT
// CLI entry point: `node src/main.ts --config <file> --role solver|header-relayer|mailbox-relayer|watchtower`.
// Keys come from the environment (SOLVER_PRIVATE_KEY, RELAYER_PRIVATE_KEY, WATCHER_PRIVATE_KEY); Node does not read
// .env files by itself, so export them or pass `--env-file=../.env` to node. This entry point has no test hooks.
import { parseArgs } from "node:util";

import { buildActor, parseRole, runActor } from "./actors.ts";
import { loadSolverConfig } from "./config.ts";
import { createLogger } from "./log.ts";

const { values } = parseArgs({
  options: {
    config: { type: "string" },
    role: { type: "string", default: "solver" },
    ticks: { type: "string" },
  },
});
if (values.config === undefined) throw new Error("--config <file> is required");
const role = parseRole(values.role);
const config = loadSolverConfig(values.config);
const log = createLogger({ role });
const maxTicks = values.ticks === undefined ? Infinity : Number(values.ticks);
await runActor(buildActor(role, config, log), config, log, maxTicks);
