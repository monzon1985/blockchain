#!/usr/bin/env node
// SPDX-License-Identifier: MIT
//
// Mutation smoke test for the UUPS-vs-diamond differential harness.
//
// Each mutant is a one-line behavioural change in ONE of the two architectures. The differential suite
// (test/differential: stateless fuzzing, stateful invariants and a scripted program, comparing return data, revert
// data and event logs) must fail for every mutant; a surviving mutant means the harness cannot see that class of
// divergence.
//
//   node scripts/mutants.mjs            run every mutant (restores each file afterwards)
//   node scripts/mutants.mjs --list     print the mutants without running anything
//   node scripts/mutants.mjs --restore  only undo a mutant left behind by a run that was killed
//
// Safety of the working tree: before a mutant is written, the original file is recorded in .mutant-journal.json.
// The file is restored after every run, on SIGINT/SIGTERM/SIGHUP, and, if the process was killed outright, at the
// start of the next run (the journal survives the crash). A final check verifies that every mutated file is back
// to its original bytes.

import { spawn } from "node:child_process";
import { existsSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const JOURNAL = join(root, ".mutant-journal.json");
const FUZZ_SEED = "0x6d7574616e7473"; // fixed: the verdict must not depend on luck

const MUTANTS = [
  {
    id: "D1",
    what: "diamond: paid renewals are not counted",
    file: "src/diamond/facets/SubscriptionFacet.sol",
    from: "if (renewal) $.renewals[msg.sender] += 1;",
    to: "if (renewal && p.price == 0) $.renewals[msg.sender] += 1;",
  },
  {
    id: "D2",
    what: "diamond: access still granted at the exact end second",
    file: "src/diamond/facets/SubscriptionFacet.sol",
    from: "block.timestamp < uint256(expiresAt) + $.gracePeriod",
    to: "block.timestamp <= uint256(expiresAt) + $.gracePeriod",
  },
  {
    id: "D3",
    what: "diamond: a subscription expiring this second still counts as renewable",
    file: "src/diamond/facets/SubscriptionFacet.sol",
    from: "bool renewal = s.planId == planId && s.expiresAt > nowTs;",
    to: "bool renewal = s.planId == planId && s.expiresAt >= nowTs;",
  },
  {
    id: "D4",
    what: "diamond: revenue is not accumulated",
    file: "src/diamond/facets/SubscriptionFacet.sol",
    from: "$.totalRevenue += p.price;",
    to: "$.totalRevenue += 0;",
  },
  {
    id: "D5",
    what: "diamond: accepting ownership leaves the nomination behind",
    file: "src/diamond/libraries/LibOwnership.sol",
    from: "delete $.pendingOwner;",
    to: "$.pendingOwner = $.pendingOwner;",
  },
  {
    id: "D6",
    what: "diamond: pausing twice is accepted",
    file: "src/diamond/facets/AdminFacet.sol",
    from: "function pause() external onlyOwner whenNotPaused {",
    to: "function pause() external onlyOwner {",
  },
  {
    id: "D7",
    what: "diamond: the maximum grace period is rejected (off by one)",
    file: "src/diamond/facets/AdminFacet.sol",
    from: "if (newGracePeriod > RegistryLimits.MAX_GRACE_PERIOD) {",
    to: "if (newGracePeriod >= RegistryLimits.MAX_GRACE_PERIOD) {",
  },
  {
    id: "D8",
    what: "diamond: the maximum plan duration is rejected (off by one)",
    file: "src/diamond/facets/PlanFacet.sol",
    from: "if (duration == 0 || duration > RegistryLimits.MAX_DURATION) {",
    to: "if (duration == 0 || duration >= RegistryLimits.MAX_DURATION) {",
  },
  {
    id: "D9",
    what: "diamond: setTreasury emits but does not store",
    file: "src/diamond/facets/AdminFacet.sol",
    from: "        $.treasury = newTreasury;",
    to: "        newTreasury;",
  },
  {
    id: "D10",
    what: "diamond: renewals are logged as fresh subscriptions (event only, state unchanged)",
    file: "src/diamond/facets/SubscriptionFacet.sol",
    from: "emit Subscribed(msg.sender, planId, expiresAt, renewal);",
    to: "emit Subscribed(msg.sender, planId, expiresAt, false);",
  },
  {
    id: "U1",
    what: "uups V3: renewals are free",
    file: "src/uups/v3/SubscriptionRegistryV3.sol",
    from: "        if (price != 0) {",
    to: "        if (price != 0 && !renewal) {",
  },
  {
    id: "U2",
    what: "uups V3: cancel keeps the plan id",
    file: "src/uups/v3/SubscriptionRegistryV3.sol",
    from: "        delete _subscriptions[msg.sender];",
    to: "        _subscriptions[msg.sender].expiresAt = 0;",
  },
  {
    id: "U3",
    what: "uups V3: the grace period is ignored",
    file: "src/uups/v3/SubscriptionRegistryV3.sol",
    from: "block.timestamp < uint256(expiresAt) + _registry().gracePeriod",
    to: "block.timestamp < uint256(expiresAt)",
  },
  {
    id: "U4",
    what: "uups V3: closing a plan is logged as opening it (event only, state unchanged)",
    file: "src/uups/v3/SubscriptionRegistryV3.sol",
    from: "emit PlanStatusChanged(planId, active);",
    to: "emit PlanStatusChanged(planId, true);",
  },
  {
    id: "U5",
    what: "uups V3: the max-price guard lets one unit above the bound through",
    file: "src/uups/v3/SubscriptionRegistryV3.sol",
    from: "if (price > maxPrice) revert PriceAboveMax(planId, price, maxPrice);",
    to: "if (price > maxPrice + 1) revert PriceAboveMax(planId, price, maxPrice);",
  },
];

function count(haystack, needle) {
  return haystack.split(needle).length - 1;
}

/** Restores the file recorded in the journal (if any) and deletes the journal. */
function recover(reason) {
  if (!existsSync(JOURNAL)) return false;
  const { file, original } = JSON.parse(readFileSync(JOURNAL, "utf8"));
  writeFileSync(join(root, file), original);
  rmSync(JOURNAL);
  console.error(`restored ${file} (${reason})`);
  return true;
}

for (const signal of ["SIGINT", "SIGTERM", "SIGHUP"]) {
  process.on(signal, () => {
    recover(`interrupted by ${signal}`);
    process.exit(130);
  });
}

/** Runs the differential suite asynchronously, so that a signal is handled (and the mutant undone) at once. */
function runSuite() {
  return new Promise((resolve, reject) => {
    const child = spawn("forge", ["test", "--match-path", "test/differential/*", "--fuzz-seed", FUZZ_SEED], {
      cwd: root,
    });
    let output = "";
    child.stdout.on("data", (d) => (output += d));
    child.stderr.on("data", (d) => (output += d));
    child.on("error", reject);
    child.on("close", (status) => resolve({ status, output }));
  });
}

// A previous run that was killed outright left its mutant in place: undo it before anything else.
recover("left behind by an interrupted run");

if (process.argv.includes("--restore")) process.exit(0);
if (process.argv.includes("--list")) {
  for (const m of MUTANTS) console.log(`${m.id}  ${m.what}\n     ${m.file}`);
  process.exit(0);
}

const originals = new Map();
for (const m of MUTANTS) {
  if (!originals.has(m.file)) originals.set(m.file, readFileSync(join(root, m.file), "utf8"));
  if (count(originals.get(m.file), m.from) !== 1) {
    console.error(`${m.id}: expected exactly one occurrence of the pattern in ${m.file}`);
    process.exit(2);
  }
}

// Sanity: the unmutated tree must pass, otherwise every mutant would look "killed".
const baseline = await runSuite();
if (baseline.status !== 0) {
  console.error(baseline.output);
  console.error("baseline differential suite fails; fix it before running mutants");
  process.exit(2);
}

const results = [];
for (const m of MUTANTS) {
  const path = join(root, m.file);
  const original = originals.get(m.file);
  writeFileSync(JOURNAL, JSON.stringify({ file: m.file, original }));
  writeFileSync(path, original.replace(m.from, m.to));
  let verdict;
  try {
    const run = await runSuite();
    // A FAIL line ends with the test name; its reason may itself contain brackets (fuzz counterexamples).
    const failing = run.output
      .split(/\r?\n/)
      .filter((line) => line.startsWith("[FAIL"))
      .map((line) => [...line.matchAll(/\b((?:test|invariant)\w*)/g)].at(-1)?.[1])
      .filter(Boolean);
    verdict = run.status !== 0 ? `killed by ${[...new Set(failing)].join(", ") || "compilation/test failure"}` : "SURVIVED";
  } finally {
    writeFileSync(path, original);
    rmSync(JOURNAL, { force: true });
  }
  results.push({ ...m, verdict });
  console.log(`${m.id.padEnd(3)}  ${verdict.startsWith("killed") ? "killed  " : "SURVIVED"}  ${m.what}`);
}

for (const [file, original] of originals) {
  if (readFileSync(join(root, file), "utf8") !== original) {
    console.error(`${file} was not restored to its original content`);
    process.exit(2);
  }
}

const survivors = results.filter((r) => r.verdict === "SURVIVED");
console.log(`\n${results.length - survivors.length}/${results.length} mutants killed`);
for (const r of results) console.log(`  ${r.id}: ${r.verdict}`);
process.exit(survivors.length === 0 ? 0 : 1);
