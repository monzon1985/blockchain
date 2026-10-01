// SPDX-License-Identifier: MIT
//
// Run circomspect over the PRODUCTION circuits (never the zoo) and fail on any
// finding that is not explicitly triaged in circuits/circomspect-triage.json.
//
// The gate fails closed:
//   1. Self-test: circomspect must report the known `<--` bug in
//      circuits/zoo/nullifier_unconstrained.circom (CS0005/CS0013). A missing,
//      broken or mis-invoked circomspect therefore cannot print "clean".
//   2. Any error-level result (e.g. a parse error), wherever it points, fails.
//   3. Any warning in circuits/lib or circuits/main that is not matched by a
//      triage entry fails; so does any triage entry that matches nothing
//      (stale suppressions are removed, not kept "just in case").
import * as path from "node:path";
import { ROOT, DIRS } from "./config.mjs";
import { loadTriage, runCircomspect, suppressionFor } from "./circomspect-lib.mjs";

function log(msg) {
  process.stdout.write(`[lint:circuits] ${msg}\n`);
}

const PRODUCTION_ENTRIES = [
  path.join(DIRS.circuits, "lib", "credential_lib.circom"),
  path.join(DIRS.circuits, "lib", "credential_core.circom"),
  path.join(DIRS.circuits, "main", "credential.circom"),
];
const CANARY = path.join(DIRS.circuits, "zoo", "nullifier_unconstrained.circom");
const TRIAGE_FILE = path.join(DIRS.circuits, "circomspect-triage.json");
const rel = (f) => path.relative(ROOT, f).replace(/\\/g, "/");

function sarifFor(entry) {
  return path.join(DIRS.build, "circomspect", `${path.basename(entry, ".circom")}.sarif`);
}

function main() {
  // 1. Self-test on a circuit that MUST be flagged.
  const canary = runCircomspect(CANARY, { includeDir: DIRS.circomlib, sarifPath: sarifFor(CANARY) });
  const canaryHits = canary.filter(
    (f) => f.file.endsWith("circuits/zoo/nullifier_unconstrained.circom") && ["CS0005", "CS0013"].includes(f.ruleId),
  );
  if (canaryHits.length === 0) {
    log("FAIL: self-test: circomspect did not flag the known `<--` bug in the zoo canary circuit");
    process.exit(1);
  }
  log(`self-test ok: circomspect flags the zoo canary (${canaryHits.map((f) => f.ruleId).join(", ")})`);

  // 2-3. Production circuits.
  const triage = loadTriage(TRIAGE_FILE);
  const seen = new Set();
  const findings = [];
  for (const entry of PRODUCTION_ENTRIES) {
    for (const f of runCircomspect(entry, { includeDir: DIRS.circomlib, sarifPath: sarifFor(entry) })) {
      const key = `${f.ruleId}@${f.file}:${f.line}`;
      if (seen.has(key)) continue;
      seen.add(key);
      findings.push(f);
    }
  }

  const errors = findings.filter((f) => f.level === "error");
  const gated = findings.filter(
    (f) => f.level !== "error" && /\/circuits\/(lib|main)\//.test(f.file) && !f.file.includes("/node_modules/"),
  );
  const untriaged = gated.filter((f) => !suppressionFor(triage, f));
  const triaged = gated.filter((f) => suppressionFor(triage, f));
  const unused = triage.filter((t) => !gated.some((f) => suppressionFor([t], f)));

  log(`analyzed ${PRODUCTION_ENTRIES.length} production entrypoints`);
  log(
    `findings: ${gated.length} (triaged: ${triaged.length}, untriaged: ${untriaged.length}); ` +
      `error-level: ${errors.length}; unused suppressions: ${unused.length}`,
  );
  for (const f of triaged) {
    const t = suppressionFor(triage, f);
    log(`  triaged   ${f.ruleId} ${rel(f.file)}:${f.line} (${t?.match}) - ${t?.justification}`);
  }
  for (const f of [...errors, ...untriaged]) {
    log(`  UNTRIAGED ${f.level} ${f.ruleId} ${rel(f.file)}:${f.line} - ${f.message}`);
  }
  for (const t of unused) log(`  UNUSED    suppression ${t.ruleId} ${t.file} (${t.match})`);

  if (errors.length > 0 || untriaged.length > 0 || unused.length > 0) {
    log("FAIL: fix the circuit, or triage with a justification in circuits/circomspect-triage.json");
    process.exit(1);
  }
  log("clean");
}

try {
  main();
} catch (err) {
  log(`FAIL: ${err instanceof Error ? err.message : err}`);
  process.exit(1);
}
