#!/usr/bin/env node
// SPDX-License-Identifier: MIT
//
// Every gate of .github/workflows/07-upgrade-safety-lab.yml, run locally in the same order and with the same
// profiles, so a contributor who is green here is green in CI.
//
//   node scripts/ci-local.mjs               every gate
//   node scripts/ci-local.mjs --skip slither,mutants
//
// Gates: soldeer, fmt, build, lint, test (CI profile: fixed seed, 4,000 fuzz runs, 256 x 100 invariants),
// gas-json, gas-snapshot, rust-fmt, clippy, rust-test, layout-gate, slither, coverage, anvil-demo, mutants.
// The per-call gas snapshot is checked the way CI checks it (the file `forge test` writes must not change); here the
// committed copy is read before the tests run and put back if they change it, so the check leaves no trace.

import { spawnSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const skipArg = process.argv.indexOf("--skip");
const skip = new Set(skipArg >= 0 ? (process.argv[skipArg + 1] ?? "").split(",") : []);
const GAS_JSON = join(root, "snapshots", "GasBench.json");
let gasJsonBefore = null;

function sh(cmd, args, { cwd = root, env = {} } = {}) {
  const res = spawnSync(cmd, args, { cwd, stdio: "inherit", env: { ...process.env, ...env }, shell: false });
  if (res.error) throw new Error(`${cmd}: ${res.error.message}`);
  return res.status === 0;
}

function coverageGate() {
  if (!sh("forge", ["coverage", "--report", "summary", "--report", "lcov", "--no-match-coverage", "(test|script|dependencies)/"], { env: { FOUNDRY_PROFILE: "coverage" } })) {
    return false;
  }
  let hit = 0;
  let found = 0;
  let inSrc = false;
  for (const line of readFileSync(join(root, "lcov.info"), "utf8").split(/\r?\n/)) {
    if (line.startsWith("SF:")) inSrc = line.slice(3).replaceAll("\\", "/").startsWith("src/");
    else if (inSrc && line.startsWith("LH:")) hit += Number(line.slice(3));
    else if (inSrc && line.startsWith("LF:")) found += Number(line.slice(3));
  }
  const pct = (100 * hit) / found;
  console.log(`src line coverage: ${pct.toFixed(2)}% (${hit}/${found})`);
  return pct >= 90;
}

const layoutDiff = join(root, "layout-diff");
const GATES = [
  ["soldeer", () => sh("forge", ["soldeer", "install"])],
  ["fmt", () => sh("forge", ["fmt", "--check"])],
  ["build", () => sh("forge", ["build", "--deny", "warnings"], { env: { FOUNDRY_PROFILE: "ci" } })],
  ["lint", () => sh("forge", ["lint", "--deny", "warnings"], { env: { FOUNDRY_PROFILE: "ci" } })],
  [
    "test",
    () => {
      gasJsonBefore = readFileSync(GAS_JSON, "utf8");
      return sh("forge", ["test"], { env: { FOUNDRY_PROFILE: "ci" } });
    },
  ],
  [
    "gas-json",
    () => {
      const after = readFileSync(GAS_JSON, "utf8");
      if (gasJsonBefore === null || after === gasJsonBefore) return gasJsonBefore !== null;
      const [before, now] = [JSON.parse(gasJsonBefore), JSON.parse(after)];
      for (const key of new Set([...Object.keys(before), ...Object.keys(now)])) {
        if (before[key] !== now[key]) console.log(`  ${key}: committed ${before[key]}, measured ${now[key]}`);
      }
      writeFileSync(GAS_JSON, gasJsonBefore);
      console.log("snapshots/GasBench.json is stale (restored); run `forge test --match-contract GasBench` to update it");
      return false;
    },
  ],
  ["gas-snapshot", () => sh("forge", ["snapshot", "--check", "--match-contract", "GasBench"], { env: { FOUNDRY_PROFILE: "ci" } })],
  ["rust-fmt", () => sh("cargo", ["fmt", "--check"], { cwd: layoutDiff })],
  ["clippy", () => sh("cargo", ["clippy", "--locked", "--all-targets", "--", "-D", "warnings"], { cwd: layoutDiff })],
  ["rust-test", () => sh("cargo", ["test", "--locked"], { cwd: layoutDiff, env: { CI: "true" } })],
  ["layout-gate", () => sh("node", ["scripts/check-layouts.mjs"])],
  ["slither", () => sh("slither", [".", "--config-file", "slither.config.json"], { env: { FOUNDRY_PROFILE: "slither" } })],
  ["coverage", coverageGate],
  ["anvil-demo", () => sh("node", ["scripts/demo-anvil.mjs"])],
  ["mutants", () => sh("node", ["scripts/mutants.mjs"])],
];

const results = [];
for (const [name, gate] of GATES) {
  if (skip.has(name)) {
    results.push([name, "skipped", 0]);
    continue;
  }
  console.log(`\n==> ${name}`);
  const started = Date.now();
  let ok;
  try {
    ok = gate();
  } catch (error) {
    console.error(error.message);
    ok = false;
  }
  results.push([name, ok ? "ok" : "FAILED", (Date.now() - started) / 1000]);
}

console.log("\nsummary");
for (const [name, verdict, seconds] of results) console.log(`  ${verdict.padEnd(7)} ${name.padEnd(13)} ${seconds.toFixed(0)}s`);
const failed = results.filter(([, verdict]) => verdict === "FAILED");
process.exit(failed.length === 0 ? 0 : 1);
