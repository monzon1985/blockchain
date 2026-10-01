#!/usr/bin/env node
// SPDX-License-Identifier: MIT
// Normalize raw tool output into deterministic evidence files (scoreboard/evidence/*.json).
//
//   node scripts/evidence.mjs <kind> <raw-input> <out.json> --tree <vulnerable|fixed> \
//        --command "<exact command>" [--version "<tool version>"] [--budget '<json>']
//
// kinds: forge   (text output of `forge test --color never`)
//        medusa  (text log of `medusa fuzz`)
//        halmos  (file written by `halmos --json-output`)
//        slither (JSON written by `slither --json -`)
//
// Normalized files keep what a reviewer needs to re-check a claim (per-test status and reason,
// per-finding check/function/source) and drop what changes run to run (timings, absolute paths,
// counterexample traces), so a re-run of a deterministic tool reproduces the file byte for byte.

import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname } from "node:path";
import { flags, stringify } from "./lib.mjs";

const ANSI = /\x1b\[[0-9;]*m/g;

/** Keep the assertion message, drop run-specific values (counterexamples, compared numbers). */
function normalizeReason(reason) {
  return reason
    .split("; counterexample")[0]
    .replace(/\s+\[[^\]]*\]/g, "")
    .replace(/: [^:]*\d[^:]*$/, "");
}

function forge(raw) {
  const results = new Map();
  let suite = null;
  for (const line0 of raw.split(/\r?\n/)) {
    const line = line0.replace(ANSI, "").trimEnd();
    // Suite headers: the per-suite "Ran N tests for <file>:<Contract>" line, and the trailing
    // summary's "Encountered N failing test(s) in <file>:<Contract>" line.
    const header = line.match(/^(?:Ran \d+ tests? for|Encountered \d+ failing tests? in) (\S+):(\w+)$/);
    if (header) {
      suite = header[2];
      continue;
    }
    const m = line.match(/^\[(PASS|FAIL)(?:: (.*))?\] (\w+)(?:\(([^)]*)\))?/);
    if (!m || !suite) continue;
    const [, status, reason, name] = m;
    const id = `${suite}.${name}`;
    if (results.has(id)) continue;
    const entry = { id, status: status === "PASS" ? "pass" : "fail" };
    // A fuzzed failure's message depends on which counterexample the fuzzer kept, which is not
    // reproducible across runs; keep the reason only for deterministic (unit) failures.
    if (reason && !reason.includes("; counterexample")) entry.reason = normalizeReason(reason);
    results.set(id, entry);
  }
  return [...results.values()].sort((a, b) => a.id.localeCompare(b.id));
}

function medusa(raw) {
  const results = new Map();
  for (const line0 of raw.split(/\r?\n/)) {
    const line = line0.replace(ANSI, "");
    const m = line.match(/\[(PASSED|FAILED)\] (Property|Assertion) Test: \w+\.(\w+)\(/);
    if (!m) continue;
    results.set(m[3], { id: m[3], kind: m[2].toLowerCase(), status: m[1] === "PASSED" ? "pass" : "fail" });
  }
  const summary = raw.match(/Test summary: (\d+) test\(s\) passed, (\d+) test\(s\) failed/);
  return {
    results: [...results.values()].sort((a, b) => a.id.localeCompare(b.id)),
    summary: summary ? { passed: Number(summary[1]), failed: Number(summary[2]) } : null,
  };
}

function halmos(raw) {
  const json = JSON.parse(raw);
  const results = [];
  for (const tests of Object.values(json.test_results)) {
    for (const t of tests) {
      // Counterexample values are solver-dependent; the raw output is kept as a CI artifact.
      const status = t.exitcode === 0 ? "pass" : t.num_models > 0 ? "fail" : "error";
      results.push({ id: t.name.split("(")[0], status });
    }
  }
  return results.sort((a, b) => a.id.localeCompare(b.id));
}

/** `Contract.member(sig)` owning a Slither result element. */
function memberOf(el) {
  const tsf = el.type_specific_fields ?? {};
  if (el.type === "function") return `${tsf.parent?.name}.${tsf.signature ?? el.name}`;
  if (el.type === "node") {
    const fn = tsf.parent;
    return `${fn?.type_specific_fields?.parent?.name}.${fn?.type_specific_fields?.signature ?? fn?.name}`;
  }
  if (el.type === "contract") return el.name;
  const parent = tsf.parent;
  if (parent?.type === "function") {
    const fts = parent.type_specific_fields ?? {};
    return `${fts.parent?.name}.${fts.signature ?? parent.name}.${el.name}`;
  }
  return `${parent?.name}.${el.name}`;
}

function slither(raw) {
  const json = JSON.parse(raw);
  if (!json.success) throw new Error(`slither reported failure: ${json.error}`);
  const results = new Map();
  for (const r of json.results?.detectors ?? []) {
    const el = r.elements.find((e) => ["function", "node", "event", "variable", "contract"].includes(e.type)) ?? r.elements[0];
    const member = memberOf(el);
    const detail = r.additional_fields?.detail;
    const id = `${r.check}@${member}${detail ? `#${detail}` : ""}`;
    const path = (el.source_mapping?.filename_relative ?? "").replace(/\\/g, "/");
    const prev = results.get(id);
    if (prev) {
      prev.count += 1;
      continue;
    }
    results.set(id, {
      id,
      check: r.check,
      custom: r.check.startsWith("kestrel-"),
      impact: r.impact,
      confidence: r.confidence,
      member,
      path,
      count: 1,
    });
  }
  return [...results.values()].sort((a, b) => a.id.localeCompare(b.id));
}

const [kind, input, output, ...rest] = process.argv.slice(2);
const opts = flags(rest);
if (!kind || !input || !output || !opts.tree || !opts.command) {
  console.error("usage: evidence.mjs <forge|medusa|halmos|slither> <raw> <out.json> --tree <t> --command <cmd>");
  process.exit(2);
}
const raw = readFileSync(input, "utf8");
const doc = { tool: kind, tree: opts.tree, command: opts.command };
if (opts.version) doc.version = opts.version;
if (opts.budget) doc.budget = JSON.parse(opts.budget);
if (kind === "forge") doc.results = forge(raw);
else if (kind === "medusa") Object.assign(doc, medusa(raw));
else if (kind === "halmos") doc.results = halmos(raw);
else if (kind === "slither") doc.results = slither(raw);
else {
  console.error(`unknown kind ${kind}`);
  process.exit(2);
}
if ((doc.results ?? []).length === 0) {
  console.error(`evidence.mjs: no ${kind} results parsed from ${input}`);
  process.exit(1);
}
mkdirSync(dirname(output), { recursive: true });
writeFileSync(output, stringify(doc));
console.log(`evidence: ${doc.results.length} ${kind} results -> ${output}`);
