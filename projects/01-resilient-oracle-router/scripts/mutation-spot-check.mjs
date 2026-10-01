#!/usr/bin/env node
// SPDX-License-Identifier: MIT
//
// Mutation spot-check: injects realistic oracle bugs (code mutants) and documentation drift (doc mutants: README
// matrix cells that no longer match the behavior) into a temporary copy of the project, one at a time, and requires
// the test suite to fail for each. The working tree is never touched.
//
// Usage: node scripts/mutation-spot-check.mjs [--kind code|docs] [--only <id>]   (code: ~2 min per mutant)
// Env:   FOUNDRY_INVARIANT_RUNS / FOUNDRY_FUZZ_RUNS / FOUNDRY_INVARIANT_SHRINK_RUN_LIMIT are honoured (defaults: 32 / 256 /
//        0, to keep a run short).

import { execFileSync } from "node:child_process";
import { cpSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");

/** Each mutant: a one-line bug a reviewer could plausibly miss, and the exact text it replaces. */
export const CODE_MUTANTS = [
  {
    id: "stale-slack",
    what: "staleness check tolerates one extra minute",
    file: "src/OracleRouter.sol",
    from: "if (age > heartbeat) {",
    to: "if (age > heartbeat + 60) {",
  },
  {
    id: "fallback-any-failure",
    what: "soft mode bridges every failure, not only STALE",
    file: "src/OracleRouter.sol",
    from: "} else if (status == Status.STALE && config.mode == Mode.Soft) {",
    to: "} else if (config.mode == Mode.Soft) {",
  },
  {
    id: "collateral-rounds-up",
    what: "collateral normalization rounds up",
    file: "src/libraries/PriceMath.sol",
    from: "return intent == IPriceOracle.Intent.Debt ? Math.ceilDiv(answer, divisor) : answer / divisor;",
    to: "return intent == IPriceOracle.Intent.Debt ? Math.ceilDiv(answer, divisor) : Math.ceilDiv(answer, divisor);",
  },
  {
    id: "grace-exclusive",
    what: "grace period ends one second early",
    file: "src/OracleRouter.sol",
    from: "if (upFor <= grace) {",
    to: "if (upFor < grace) {",
  },
  {
    id: "breaker-slack",
    what: "deviation breaker tolerates one extra basis point",
    file: "src/OracleRouter.sol",
    from: "if (deviation <= maxDeviation) return",
    to: "if (deviation <= maxDeviation + 1) return",
  },
  {
    id: "conservative-swapped",
    what: "soft deviation quotes the higher price for collateral",
    file: "src/OracleRouter.sol",
    from: "price = candidate.price < secondaryPrice ? candidate.price : secondaryPrice;",
    to: "price = candidate.price < secondaryPrice ? secondaryPrice : candidate.price;",
  },
  {
    id: "twap-never-expires",
    what: "TWAP fallback never expires",
    file: "src/libraries/ObservationRing.sol",
    from: "if (ageOfNewest > window || span < window)",
    to: "if ((ageOfNewest > window && false) || span < window)",
  },
  {
    id: "twap-no-interpolation",
    what: "TWAP window start not interpolated",
    file: "src/libraries/ObservationRing.sol",
    from: "uint224 cumulativeAtStart = before.answerCumulative + answer * intoInterval;",
    to: "uint224 cumulativeAtStart = before.answerCumulative + 0 * answer * intoInterval;",
  },
  {
    id: "no-delay-floor",
    what: "router trusts the AccessManager's delay configuration",
    file: "src/OracleRouter.sol",
    from: "if (immediate || delay != 0) {",
    to: "if ((immediate || delay != 0) && false) {",
  },
  {
    id: "no-round-check",
    what: "answeredInRound < roundId accepted",
    file: "src/OracleRouter.sol",
    from: "if (round.answeredInRound < round.roundId) {",
    to: "if (round.answeredInRound < round.roundId && false) {",
  },
  {
    id: "sequencer-uninitialized-ok",
    what: "uninitialized sequencer feed (startedAt == 0) treated as up",
    file: "src/OracleRouter.sol",
    from: "if (round.answer != 0 || round.startedAt == 0) {",
    to: "if (round.answer != 0) {",
  },
  {
    id: "record-deviating",
    what: "observations recorded while the breaker is tripped",
    file: "src/OracleRouter.sol",
    from: "require(status == Status.OK, PriceNotObservable(asset, status));",
    to: "require(status == Status.OK || status == Status.DEVIATION, PriceNotObservable(asset, status));",
  },
  {
    id: "twap-carries-across-gaps",
    what: "an answer is carried across any recording gap (the ring never restarts)",
    file: "src/libraries/ObservationRing.sol",
    from: "restarted = elapsed > maxGap;",
    to: "restarted = elapsed > maxGap && false;",
  },
  {
    id: "gap-limit-ignores-heartbeat",
    what: "the gap limit is the TWAP window even when the heartbeat is shorter",
    file: "src/OracleRouter.sol",
    from: "maxGap = heartbeat < window ? heartbeat : window;",
    to: "maxGap = heartbeat < window ? window : window;",
  },
  {
    id: "outage-carried-over",
    what: "observations carried across a sequencer outage shorter than the gap limit",
    file: "src/OracleRouter.sol",
    from: "if (upFor < maxGap) maxGap = uint32(upFor);",
    to: "if (upFor < maxGap && false) maxGap = uint32(upFor);",
  },
  {
    id: "record-without-witness",
    what: "a soft asset records its primary while the witness is dead",
    file: "src/OracleRouter.sol",
    from: "if (config.mode == Mode.Soft && config.secondary.feed != address(0)) {",
    to: "if (config.mode == Mode.Soft && config.secondary.feed != address(0) && false) {",
  },
  {
    id: "consult-ignores-sequencer",
    what: "consultTwap reports a TWAP during a sequencer outage",
    file: "src/OracleRouter.sol",
    from: "if (window != 0 && sequencerStatus == Status.OK) {",
    to: "if (window != 0 && (sequencerStatus == Status.OK || true)) {",
  },
];

/** README drift: each edit makes a documented matrix cell disagree with the code, and must fail the build. */
export const DOC_MUTANTS = [
  {
    id: "doc-wrong-status",
    what: "soft STALE cell claims status OK",
    file: "README.md",
    from: "`(TWAP, FALLBACK_USED)` · `test_Matrix_Stale_Soft`",
    to: "`(TWAP, OK)` · `test_Matrix_Stale_Soft`",
  },
  {
    id: "doc-missing-test",
    what: "cell names a test that does not exist",
    file: "README.md",
    from: "`test_Matrix_Zero_Soft`",
    to: "`test_Matrix_Zero_Softer`",
  },
  {
    id: "doc-wrong-error",
    what: "strict ZERO cell names the wrong custom error",
    file: "README.md",
    from: "reverts `ZeroAnswer` → `(0, ZERO)` · `test_Matrix_Zero_Strict`",
    to: "reverts `NegativeAnswer` → `(0, ZERO)` · `test_Matrix_Zero_Strict`",
  },
  {
    id: "doc-dropped-row",
    what: "GRACE_PERIOD row removed from the matrix",
    file: "README.md",
    from: "| 6 | `GRACE_PERIOD` | ",
    to: "",
  },
  {
    id: "doc-false-fallback",
    what: "soft OUT_OF_BOUNDS cell claims a TWAP fallback",
    file: "README.md",
    from: "reverts `AnswerOutOfBounds` → `(0, OUT_OF_BOUNDS)` · `test_Matrix_OutOfBounds_Soft`",
    to: "returns `TWAP` → `(TWAP, FALLBACK_USED)` · `test_Matrix_OutOfBounds_Soft`",
  },
];

export const MUTANTS = [...CODE_MUTANTS, ...DOC_MUTANTS];

function main() {
  const flag = (name) => (process.argv.includes(name) ? process.argv[process.argv.indexOf(name) + 1] : undefined);
  const only = flag("--only");
  const kind = flag("--kind");
  const pool = kind === "code" ? CODE_MUTANTS : kind === "docs" ? DOC_MUTANTS : MUTANTS;
  const selected = pool.filter((m) => only === undefined || m.id === only);
  if (selected.length === 0) throw new Error(`no mutant named ${only}`);

  const work = mkdtempSync(join(tmpdir(), "oracle-mutants-"));
  try {
    for (const entry of ["src", "test", "script", "dependencies", "foundry.toml", "soldeer.lock", "README.md"]) {
      cpSync(join(root, entry), join(work, entry), { recursive: true });
    }
    // Mutants are deliberately odd code (`&& false`, `0 *`): keep the compiler strict but skip the linter.
    const toml = join(work, "foundry.toml");
    writeFileSync(toml, readFileSync(toml, "utf8").replace("[lint]\n", "[lint]\nlint_on_build = false\n"));
    const env = {
      ...process.env,
      FOUNDRY_PROFILE: "default",
      FOUNDRY_INVARIANT_RUNS: process.env.FOUNDRY_INVARIANT_RUNS ?? "32",
      FOUNDRY_FUZZ_RUNS: process.env.FOUNDRY_FUZZ_RUNS ?? "256",
      // A kill only needs a failure, not a minimal counterexample: shrinking ten failing invariants takes minutes.
      FOUNDRY_INVARIANT_SHRINK_RUN_LIMIT: process.env.FOUNDRY_INVARIANT_SHRINK_RUN_LIMIT ?? "0",
    };
    // Baseline: the unmutated copy must pass, otherwise every "kill" would be meaningless.
    execFileSync("forge", ["test"], { cwd: work, env, stdio: "pipe" });
    console.log("baseline: all tests pass\n");

    const rows = [];
    for (const m of selected) {
      const path = join(work, m.file);
      const original = readFileSync(path, "utf8");
      const occurrences = original.split(m.from).length - 1;
      if (occurrences !== 1) throw new Error(`${m.id}: expected exactly one match, found ${occurrences}`);
      writeFileSync(path, original.replace(m.from, m.to));
      let killedBy = null;
      // Foundry replays persisted fuzz and invariant counterexamples first; a previous mutant's must not judge this one.
      for (const kind of ["fuzz", "invariant"]) rmSync(join(work, "cache", kind), { recursive: true, force: true });
      try {
        // A mutant that does not compile proves nothing: build first and let that error escape.
        execFileSync("forge", ["build"], { cwd: work, env, stdio: "pipe" });
        // README edits can only affect the executable matrix; code mutants run the whole suite.
        const filter = m.file === "README.md" ? ["--match-contract", "FailureMatrixTest"] : [];
        execFileSync("forge", ["test", ...filter], { cwd: work, env, stdio: "pipe" });
      } catch (error) {
        const out = `${error.stdout ?? ""}${error.stderr ?? ""}`;
        if (!out.includes("[FAIL")) throw new Error(`${m.id}: build or runner error\n${out}`);
        killedBy = failingTests(out);
      } finally {
        writeFileSync(path, original);
      }
      rows.push({ ...m, killedBy });
      const more = killedBy && killedBy.length > 3 ? ", ..." : "";
      const detail = killedBy ? `${killedBy.length} failing: ${killedBy.slice(0, 3).join(", ")}${more}` : "";
      console.log(`${killedBy ? "KILLED  " : "SURVIVED"}  ${m.id.padEnd(28)} ${detail}`);
    }
    const survivors = rows.filter((r) => !r.killedBy);
    console.log(`\n${rows.length - survivors.length}/${rows.length} mutants killed`);
    if (survivors.length > 0) process.exit(1);
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
}

/**
 * Names of the failing tests in forge's output (deduplicated, in order of appearance). Unit, fuzz and table tests
 * are printed with their signature (`test_X() (gas: ...)`); a failing invariant is printed by name alone at the end
 * of the line (`[FAIL: reason] invariant_X`), followed by its call sequence.
 */
export function failingTests(output) {
  const names = [];
  for (const line of output.split(/\r?\n/)) {
    if (!line.startsWith("[FAIL")) continue;
    const found = [...line.matchAll(/\b((?:test|invariant|table)\w*)(?:\(|\s*$)/g)].map((match) => match[1]);
    const name = found.length > 0 ? found[found.length - 1] : "unknown";
    if (!names.includes(name)) names.push(name);
  }
  return names;
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? "").href) main();
