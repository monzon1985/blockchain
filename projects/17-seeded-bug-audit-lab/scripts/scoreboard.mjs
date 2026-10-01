#!/usr/bin/env node
// SPDX-License-Identifier: MIT
// Blind tool-detection scoreboard, derived from stored tool evidence.
//
//   node scripts/scoreboard.mjs           # write scoreboard/DETECTION_TABLE.md and the report/README blocks
//   node scripts/scoreboard.mjs --check   # CI: fail on any inconsistency or drift
//
// Inputs: scoreboard/detection.json (the auditor's attribution of signals to bugs) and the
// normalized evidence in scoreboard/evidence/ (written by scripts/blind-run.sh). Detections are
// DERIVED: a tool is credited with a bug only if its signal fires on the vulnerable build, does
// not fire on the fixed build, and is attributed to that bug. The script also verifies the
// closure of every finding: each exploit passes on v1 and fails on v2, each attack regression
// passes on v2 and fails on v1, and every property-based tool is clean on v2.

import { Outputs, fail, readJson, readText, replaceBlock } from "./lib.mjs";

const check = process.argv.includes("--check");
const detection = readJson("scoreboard/detection.json");
const errors = [];

function evidence(name, tree) {
  const doc = readJson(`scoreboard/evidence/${name}-${tree}.json`);
  if (doc.tree !== tree) errors.push(`evidence ${name}-${tree}.json declares tree ${doc.tree}`);
  return doc;
}

const ev = {};
for (const name of ["foundry-invariants", "medusa", "halmos", "slither", "exploits", "regressions"]) {
  ev[name] = { vulnerable: evidence(name, "vulnerable"), fixed: evidence(name, "fixed") };
}

// --- Signals per tool: ids present (failing / reported) on each tree -------------------------

function signalSet(tool, tree) {
  const spec = detection.tools[tool];
  const doc = ev[spec.evidence][tree];
  if (spec.evidence === "slither") {
    return new Set(doc.results.filter((r) => r.custom === spec.custom).map((r) => r.id));
  }
  // Invariants are reported as `Suite.invariant_x`; the attribution uses the invariant name.
  const name = (id) => (spec.evidence === "foundry-invariants" ? id.split(".").at(-1) : id);
  return new Set(doc.results.filter((r) => r.status !== "pass").map((r) => name(r.id)));
}

const tools = Object.keys(detection.tools);
const signals = {};
for (const tool of tools) {
  const v1 = signalSet(tool, "vulnerable");
  const v2 = signalSet(tool, "fixed");
  signals[tool] = { v1, v2, v1only: new Set([...v1].filter((id) => !v2.has(id))) };
}

// Property-based tools must be clean on the fixed build.
for (const name of ["foundry-invariants", "medusa", "halmos"]) {
  for (const r of ev[name].fixed.results) {
    if (r.status !== "pass") errors.push(`${name}: ${r.id} is not green on the fixed build (${r.status})`);
  }
}

// --- Attribution ----------------------------------------------------------------------------

const attributed = new Map();
for (const bug of detection.bugs) {
  bug.detectedBy = [];
  for (const s of bug.signals) {
    if (!signals[s.tool]) {
      errors.push(`${bug.id}: unknown tool ${s.tool}`);
      continue;
    }
    const key = `${s.tool}:${s.id}`;
    if (attributed.has(key)) errors.push(`${key} attributed to both ${attributed.get(key)} and ${bug.id}`);
    attributed.set(key, bug.id);
    if (!signals[s.tool].v1.has(s.id)) errors.push(`${bug.id}: ${key} does not fire on the vulnerable build`);
    else if (signals[s.tool].v2.has(s.id)) errors.push(`${bug.id}: ${key} also fires on the fixed build`);
    if (detection.tools[s.tool].evidence === "slither") {
      const member = s.id.split("@")[1].split("#")[0];
      if (!bug.sites.includes(member)) errors.push(`${bug.id}: ${key} is not at one of the bug's sites`);
    }
    if (!bug.detectedBy.includes(s.tool)) bug.detectedBy.push(s.tool);
  }
}
for (const u of detection.unattributed) attributed.set(`${u.tool}:${u.id}`, "unattributed");
for (const tool of tools) {
  for (const id of signals[tool].v1only) {
    if (!attributed.has(`${tool}:${id}`)) errors.push(`untriaged v1-only signal ${tool}:${id}`);
  }
}

// --- Closure: exploit on v1 / revert on v2, regression on v2 / failure on v1 -----------------

function statusMap(doc) {
  return new Map(doc.results.map((r) => [r.id, r.status]));
}
const exV1 = statusMap(ev.exploits.vulnerable);
const exV2 = statusMap(ev.exploits.fixed);
const reV1 = statusMap(ev.regressions.vulnerable);
const reV2 = statusMap(ev.regressions.fixed);
const listedExploits = new Set();
const listedRegressions = new Set(detection.controls);
for (const bug of detection.bugs) {
  for (const t of bug.exploits) {
    listedExploits.add(t);
    if (exV1.get(t) !== "pass") errors.push(`${bug.id}: exploit ${t} does not pass on v1 (${exV1.get(t)})`);
    if (exV2.get(t) !== "fail") errors.push(`${bug.id}: exploit ${t} does not fail on v2 (${exV2.get(t)})`);
  }
  for (const t of bug.regressions) {
    listedRegressions.add(t);
    if (reV2.get(t) !== "pass") errors.push(`${bug.id}: regression ${t} does not pass on v2 (${reV2.get(t)})`);
    if (reV1.get(t) !== "fail") errors.push(`${bug.id}: regression ${t} does not fail on v1 (${reV1.get(t)})`);
  }
}
for (const t of exV1.keys()) if (!listedExploits.has(t)) errors.push(`exploit ${t} is not attributed to a bug`);
for (const [t, status] of reV2) {
  const suite = t.split(".")[0];
  if (detection.controls.includes(t)) {
    if (status !== "pass") errors.push(`control ${t} must pass on v2`);
    if (reV1.get(t) !== "pass") errors.push(`control ${t} must also pass on v1 (it exercises unchanged behavior)`);
  } else if (detection.reviewSuites.includes(suite)) {
    // Review regressions guard shared code; on v1 they may fail where a seeded bug sits in the
    // path they exercise (e.g. the stale-oracle test needs the SC03 fix to consult the oracle).
    if (status !== "pass") errors.push(`review regression ${t} must pass on v2`);
  } else if (!listedRegressions.has(t)) errors.push(`regression ${t} is not attributed to a bug`);
}

if (errors.length) fail("scoreboard", errors);

// --- Rendering ------------------------------------------------------------------------------

const label = (tool) => detection.tools[tool].label;
const mark = (on) => (on ? "✅" : "—");
const n = detection.bugs.length;
const counts = Object.fromEntries(tools.map((t) => [t, detection.bugs.filter((b) => b.detectedBy.includes(t)).length]));
const caught = detection.bugs.filter((b) => b.detectedBy.length > 0);
const staticTools = ["slitherStd", "slitherCustom"];
const staticCaught = detection.bugs.filter((b) => b.detectedBy.some((t) => staticTools.includes(t)));
const staticMissed = detection.bugs.filter((b) => !b.detectedBy.some((t) => staticTools.includes(t)));
const inv = ev["foundry-invariants"].vulnerable.budget ?? {};
const med = ev.medusa.vulnerable.budget ?? {};

const summary =
  `**${caught.length}/${n}** seeded bugs were surfaced by at least one tool on the vulnerable build without hints ` +
  `(${tools.map((t) => `${label(t)} ${counts[t]}`).join(", ")}). ` +
  `Static analysis alone (standard + custom Slither detectors) surfaced **${staticCaught.length}/${n}**; the other ` +
  `${staticMissed.length} needed a property written from the specification and a stateful or symbolic tool to falsify it. ` +
  `All ${n} are closed by an exploit that passes on v1 and fails on v2 and by attack regressions that pass on v2 and fail on v1.`;

const table = [];
table.push(`| Bug | Finding | OWASP SC Top 10:2026 | Title | ${tools.map(label).join(" | ")} | Exploit v1 ✓ / v2 ✗ | Regression v2 ✓ / v1 ✗ |`);
table.push(`| ${["---", "---", "---", "---", ...tools.map(() => ":---:"), ":---:", ":---:"].join(" | ")} |`);
for (const b of detection.bugs) {
  table.push(
    `| \`${b.id}\` | [${b.finding}](../report/REPORT.md#${b.finding.toLowerCase()}) | ${b.owasp} | ${b.title} | ` +
      `${tools.map((t) => mark(b.detectedBy.includes(t))).join(" | ")} | ${b.exploits.length}/${b.exploits.length} | ` +
      `${b.regressions.length}/${b.regressions.length} |`,
  );
}

const signalLines = detection.bugs.map(
  (b) => `- \`${b.id}\`: ${b.signals.map((s) => `${label(s.tool)} \`${s.id}\``).join("; ")}. ${b.triage}`,
);

// Custom detector precision on the protocol: credited v1 hits are true positives; every other hit
// (v1 or v2) is a false positive or an accepted risk.
const customRows = [];
const v1Custom = ev.slither.vulnerable.results.filter((r) => r.custom);
const v2Custom = ev.slither.fixed.results.filter((r) => r.custom);
const credited = new Set(detection.bugs.flatMap((b) => b.signals.filter((s) => s.tool === "slitherCustom").map((s) => s.id)));
for (const checkName of ["kestrel-spot-price-collateral", "kestrel-unchecked-callback", "kestrel-div-before-mul-loop"]) {
  const h1 = v1Custom.filter((r) => r.check === checkName);
  const h2 = v2Custom.filter((r) => r.check === checkName);
  const tp = h1.filter((r) => credited.has(r.id)).length;
  const prec = h1.length ? `${Math.round((100 * tp) / h1.length)}%` : "n/a";
  customRows.push(`| \`${checkName}\` | ${h1.length} | ${tp} | ${prec} | ${h2.length} |`);
}

const detectionTable = [
  "<!-- GENERATED by scripts/scoreboard.mjs from scoreboard/detection.json and scoreboard/evidence/. Do not edit. -->",
  "",
  `**Crediting rule.** ${detection.rule}`,
  "",
  ...table,
  "",
  summary,
  "",
  `Budgets: Foundry invariants ${inv.runs} runs x depth ${inv.depth} (${inv.runs * inv.depth} calls, seed ${inv.seed}, ` +
    `${inv.workers} worker); Medusa ${med.timeout} s on ${med.workers} workers (Medusa 1.5.1 exposes no RNG seed; the ` +
    `corpus is kept as a CI artifact); Halmos ${ev.halmos.vulnerable.results.length} properties; Slither 0.11.6 with the kestrel plugin.`,
  "",
  "### Signals per bug",
  "",
  ...signalLines,
  "",
  "### Custom detector precision on the protocol",
  "",
  "A hit is a true positive when it is credited above (fires on v1 at the bug site and not on v2); every other hit is a false positive or a triaged accepted risk.",
  "",
  "| Detector | v1 hits | True positives | Precision on v1 | v2 hits (triaged) |",
  "| --- | ---: | ---: | ---: | ---: |",
  ...customRows,
  "",
].join("\n");

const outputs = new Outputs(check);
outputs.emit("scoreboard/DETECTION_TABLE.md", detectionTable);
let report = readText("report/REPORT.md");
report = replaceBlock(report, "scoreboard-summary", summary);
report = replaceBlock(report, "scoreboard-table", detectionTable.split("\n").slice(2).join("\n").replaceAll("../report/REPORT.md#", "#"));
outputs.emit("report/REPORT.md", report);
let readme = readText("README.md");
readme = replaceBlock(readme, "scoreboard-summary", summary);
outputs.emit("README.md", readme);
console.log(`scoreboard: ${caught.length}/${n} tool-detected, ${staticCaught.length}/${n} by static analysis.`);
outputs.finish("scoreboard");
