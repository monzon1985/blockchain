#!/usr/bin/env node
// SPDX-License-Identifier: MIT
//
// Mutation smoke test: re-injects realistic bugs into the production contracts, one at a time, and checks that the
// test suite catches each of them with every test named in `expect`. Mutants are written into a throwaway copy of
// the project in the OS temp directory, never into this checkout, so an interrupted run (Ctrl-C, SIGTERM, a closed
// terminal, a CI cancellation, a power loss) cannot leave a seeded bug in src/. Run from the project root:
//
//   node scripts/mutation-smoke.mjs            # every mutation
//   node scripts/mutation-smoke.mjs 1 3        # only mutations #1 and #3
//
// The child `forge test` runs use FOUNDRY_PROFILE=ci (the CI settings: 128 x 128 invariant calls) unless
// FOUNDRY_PROFILE is already set. Exit code 0 means every mutation was killed by all of its expected tests.

import { cpSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import { pathToFileURL } from "node:url";

export const MUTATIONS = [
  {
    id: 1,
    name: "_update no longer checks the sender",
    file: "src/TestPaymentDollarV1.sol",
    edits: [["        if (from != address(0)) _requireUnrestricted(from);\n", ""]],
    match: "StablecoinInvariants",
    expect: ["invariant_restrictedBalancesOnlyMoveThroughLawfulOrders"],
  },
  {
    id: 2,
    name: "seize may credit a restricted recipient",
    file: "src/modules/ComplianceControls.sol",
    edits: [["        _requireUnrestricted(to);\n        // Lawful-order path", "        // Lawful-order path"]],
    match: "StablecoinInvariants",
    expect: ["invariant_restrictedBalancesOnlyMoveThroughLawfulOrders"],
  },
  {
    id: 3,
    name: "pause is not enforced in _update",
    file: "src/TestPaymentDollarV1.sol",
    edits: [["        _requireNotPaused();\n        if (from != address(0))", "        if (from != address(0))"]],
    match: "StablecoinInvariants",
    expect: ["invariant_nothingMovesWhilePaused"],
  },
  {
    id: 4,
    name: "minter mint skips the reserve gate",
    file: "src/modules/MintController.sol",
    edits: [["        _requireReserveHeadroom(amount);\n", ""]],
    match: "StablecoinInvariants",
    expect: ["invariant_supplyBoundedByAttestedReserves"],
  },
  {
    id: 5,
    name: "mint does not consume the minter allowance",
    file: "src/modules/MintController.sol",
    edits: [["$.allowance[minter] = remaining - amount;", "$.allowance[minter] = remaining;"]],
    match: "StablecoinInvariants",
    expect: ["invariant_minterAllowanceConservation"],
  },
  {
    id: 6,
    name: "v2 _update bypasses the v1 choke point (bug introduced by the upgrade)",
    file: "src/TestPaymentDollarV2.sol",
    edits: [
      [
        'import {TestPaymentDollarV1} from "./TestPaymentDollarV1.sol";',
        'import {TestPaymentDollarV1} from "./TestPaymentDollarV1.sol";\n' +
          'import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";',
      ],
      ["        super._update(from, to, value);", "        ERC20Upgradeable._update(from, to, value);"],
    ],
    match: "StablecoinInvariants",
    expect: ["invariant_restrictedBalancesOnlyMoveThroughLawfulOrders", "invariant_nothingMovesWhilePaused"],
  },
  {
    id: 7,
    name: "minter rolling window is never consumed",
    file: "src/modules/MintController.sol",
    edits: [["if (!window.tryConsume(MINTER_KEY, amount)) {", "if (false && !window.tryConsume(MINTER_KEY, amount)) {"]],
    match: "RateLimitFuzzTest|MintingTest",
    expect: ["testFuzz_rollingLimitMatchesReferenceModel"],
  },
  {
    id: 8,
    name: "attestations may be replayed (no monotonic timestamp)",
    file: "src/modules/ReserveGate.sol",
    edits: [["        require(asOf > latest, AttestationNotNewer(asOf, latest));\n", ""]],
    match: "SignatureFuzzTest|ReservesTest",
    expect: ["testFuzz_attestation_replayRejected"],
  },
  {
    id: 9,
    name: "configureMinter installs twice the requested rolling limit",
    file: "src/modules/MintController.sol",
    edits: [
      [
        "$.minterWindow[minter].updateSettings(RATE_LIMIT_WINDOW, dailyLimit);",
        "$.minterWindow[minter].updateSettings(RATE_LIMIT_WINDOW, dailyLimit * 2);",
      ],
    ],
    match: "StablecoinInvariants",
    expect: ["invariant_rollingLimitsRespected"],
  },
];

/** What a throwaway copy of the project needs for `forge test`. */
export const WORKSPACE_ENTRIES = ["src", "test", "script", "dependencies", "foundry.toml", "remappings.txt"];

/** Applies the edits of `mutation` to `source`; every search string must occur exactly once. */
export function applyMutation(source, mutation) {
  let out = source;
  for (const [search, replace] of mutation.edits) {
    const count = out.split(search).length - 1;
    if (count !== 1) throw new Error(`mutation #${mutation.id}: expected 1 match in ${mutation.file}, found ${count}`);
    out = out.replace(search, () => replace);
  }
  return out;
}

/** Names of the failing tests in `forge test` output (unit, fuzz and invariant result lines). */
export function failingTests(output) {
  const failing = new Set();
  for (const line of output.split(/\r?\n/)) {
    const m = line.match(/^\[FAIL.*\]\s+(\w+)/);
    if (m) failing.add(m[1]);
  }
  return failing;
}

/** A mutant counts as killed only if forge failed and every expected test is among the failures. */
export function isKilled(status, failing, expect) {
  return status !== 0 && expect.length > 0 && expect.every((t) => failing.has(t));
}

/** Environment of the child `forge test`: the CI profile unless the caller chose one. */
export function childEnv(env) {
  return { ...env, FOUNDRY_PROFILE: env.FOUNDRY_PROFILE || "ci" };
}

/** Copies what `forge test` needs from `root` into a fresh temporary directory and returns its path. */
export function createWorkspace(root, parent = tmpdir()) {
  const dir = mkdtempSync(join(parent, "tpd-mutation-"));
  for (const entry of WORKSPACE_ENTRIES) {
    cpSync(join(root, entry), join(dir, entry), { recursive: true });
  }
  return dir;
}

/** Writes the mutant of `mutation` into `workspace`, starting from the pristine `source`. */
export function writeMutant(workspace, mutation, source) {
  writeFileSync(join(workspace, mutation.file), applyMutation(source, mutation));
}

const sha256 = (path) => createHash("sha256").update(readFileSync(path)).digest("hex");

function run(workspace, mutation, env) {
  const original = readFileSync(mutation.file, "utf8"); // from this checkout, which is never written
  try {
    writeMutant(workspace, mutation, original);
    const res = spawnSync("forge", ["test", "--match-contract", mutation.match], {
      cwd: workspace,
      encoding: "utf8",
      env,
      maxBuffer: 64 * 1024 * 1024,
    });
    const output = `${res.stdout}\n${res.stderr}`;
    if (/Compiler run failed/.test(output)) return { killed: false, detail: "mutant does not compile" };
    const failing = failingTests(output);
    const hit = mutation.expect.filter((t) => failing.has(t));
    const missed = mutation.expect.filter((t) => !failing.has(t));
    return {
      killed: isKilled(res.status, failing, mutation.expect),
      detail:
        missed.length === 0
          ? `killed by ${hit.join(", ")}`
          : `survived: ${missed.join(", ")} did not fail (failing: ${[...failing].join(", ") || "none"})`,
    };
  } finally {
    writeFileSync(join(workspace, mutation.file), original); // the next mutant of this file starts clean
  }
}

function main() {
  const only = process.argv.slice(2).map(Number);
  const selected = only.length > 0 ? MUTATIONS.filter((m) => only.includes(m.id)) : MUTATIONS;
  const env = childEnv(process.env);
  const guarded = [...new Set(selected.map((m) => m.file))];
  const before = guarded.map(sha256);
  const workspace = createWorkspace(process.cwd());
  const cleanup = () => rmSync(workspace, { recursive: true, force: true });
  for (const signal of ["SIGINT", "SIGTERM", "SIGHUP"]) {
    process.once(signal, () => {
      cleanup();
      process.exit(128 + (signal === "SIGINT" ? 2 : signal === "SIGTERM" ? 15 : 1));
    });
  }
  console.log(`workspace ${workspace} (FOUNDRY_PROFILE=${env.FOUNDRY_PROFILE}); this checkout is never modified`);
  let survivors = 0;
  try {
    for (const mutation of selected) {
      const { killed, detail } = run(workspace, mutation, env);
      if (!killed) survivors++;
      console.log(`#${mutation.id} ${killed ? "KILLED  " : "SURVIVED"} ${mutation.name}: ${detail}`);
    }
  } finally {
    cleanup();
  }
  if (guarded.some((file, i) => sha256(file) !== before[i])) throw new Error("a production source changed");
  console.log(`\n${selected.length - survivors}/${selected.length} mutations killed; src/ unchanged`);
  process.exit(survivors === 0 ? 0 : 1);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main();
}
