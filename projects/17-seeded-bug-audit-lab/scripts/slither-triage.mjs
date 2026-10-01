#!/usr/bin/env node
// SPDX-License-Identifier: MIT
// Slither gate for the fixed tree (Engineering Standards §6): every finding, standard or custom,
// must be triaged in slither.triage.json with a justification, and every triage entry must still
// match a finding (no stale suppressions). The source carries no `slither-disable` comments.
//
//   node scripts/slither-triage.mjs <normalized-slither-fixed.json>

import { readFileSync } from "node:fs";
import { fail, readJson } from "./lib.mjs";

const evidencePath = process.argv[2];
if (!evidencePath) {
  console.error("usage: slither-triage.mjs <normalized slither evidence (fixed tree)>");
  process.exit(2);
}
const evidence = JSON.parse(readFileSync(evidencePath, "utf8"));
if (evidence.tree !== "fixed") fail("slither-triage", [`expected fixed-tree evidence, got ${evidence.tree}`]);
const triage = readJson("slither.triage.json");

const errors = [];
const triaged = new Map();
for (const entry of triage.entries) {
  if (!entry.id || !entry.justification || entry.justification.length < 40) {
    errors.push(`triage entry ${entry.id ?? "?"} needs a justification of at least one sentence`);
  }
  triaged.set(entry.id, entry);
}
const found = new Set(evidence.results.map((r) => r.id));
for (const r of evidence.results) {
  if (!triaged.has(r.id)) errors.push(`untriaged finding [${r.impact}] ${r.id} (${r.path})`);
}
for (const id of triaged.keys()) {
  if (!found.has(id)) errors.push(`stale triage entry (no longer reported): ${id}`);
}
if (errors.length) fail("slither-triage", errors);

const byImpact = {};
for (const r of evidence.results) byImpact[r.impact] = (byImpact[r.impact] ?? 0) + 1;
console.log(
  `slither-triage: all ${evidence.results.length} fixed-tree findings triaged ` +
    `(${Object.entries(byImpact).map(([k, v]) => `${k} ${v}`).join(", ")}).`,
);
