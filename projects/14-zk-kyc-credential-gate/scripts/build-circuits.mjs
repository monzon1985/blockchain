// SPDX-License-Identifier: MIT
// Compile every circuit (production, the four zoo variants and the gas
// baseline) to r1cs + wasm + sym.
import { execFileSync } from "node:child_process";
import * as fs from "node:fs";
import { CIRCUITS, DIRS, circuitPaths } from "./config.mjs";

function log(msg) {
  process.stdout.write(`[circuits:build] ${msg}\n`);
}

fs.mkdirSync(DIRS.build, { recursive: true });

for (const circuit of CIRCUITS) {
  const paths = circuitPaths(circuit.name);
  fs.mkdirSync(paths.dir, { recursive: true });
  log(`compiling ${circuit.name} (${circuit.kind})`);
  execFileSync(
    "circom",
    [
      circuit.source,
      "--r1cs",
      "--wasm",
      "--sym",
      "-o",
      paths.dir,
      "-l",
      DIRS.circomlib,
    ],
    { stdio: "inherit" },
  );
  if (!fs.existsSync(paths.r1cs) || !fs.existsSync(paths.wasm)) {
    throw new Error(`compilation did not produce artifacts for ${circuit.name}`);
  }
}

log(`done: ${CIRCUITS.length} circuits compiled`);
