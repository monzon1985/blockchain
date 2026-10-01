#!/usr/bin/env node
// SPDX-License-Identifier: MIT
//
// Coverage gate for `forge coverage --report lcov`.
//
// Usage: node scripts/check-coverage.mjs lcov.info [--min-branches 90] [--min-lines 90] [--include src/]
//
// Totals are recomputed from the per-line (DA) and per-branch (BRDA) records instead of trusting the summary
// counters, restricted to files under `--include` (production code only). Exits 1 if a threshold is missed.

import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

/**
 * Parses an lcov tracefile into per-file line / branch / function counters.
 * @param {string} text lcov contents
 * @returns {Array<{file: string, lines: {found: number, hit: number}, branches: {found: number, hit: number},
 *   functions: {found: number, hit: number}}>}
 */
export function parseLcov(text) {
  const records = [];
  let current = null;
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (line.startsWith("SF:")) {
      current = {
        file: line.slice(3).replaceAll("\\", "/"),
        lines: new Map(),
        branches: new Map(),
        functions: new Map(),
      };
    } else if (current && line.startsWith("DA:")) {
      const [lineNo, hits] = line.slice(3).split(",");
      current.lines.set(lineNo, (current.lines.get(lineNo) ?? 0) + Number(hits));
    } else if (current && line.startsWith("BRDA:")) {
      const [lineNo, block, branch, taken] = line.slice(5).split(",");
      const key = `${lineNo}:${block}:${branch}`;
      const hits = taken === "-" ? 0 : Number(taken);
      current.branches.set(key, (current.branches.get(key) ?? 0) + hits);
    } else if (current && line.startsWith("FNDA:")) {
      const comma = line.indexOf(",");
      const hits = Number(line.slice(5, comma));
      const name = line.slice(comma + 1);
      current.functions.set(name, (current.functions.get(name) ?? 0) + hits);
    } else if (current && line === "end_of_record") {
      const count = (map) => ({ found: map.size, hit: [...map.values()].filter((h) => h > 0).length });
      records.push({
        file: current.file,
        lines: count(current.lines),
        branches: count(current.branches),
        functions: count(current.functions),
      });
      current = null;
    }
  }
  return records;
}

/**
 * Sums counters over the records whose path contains `include`.
 * @param {ReturnType<typeof parseLcov>} records
 * @param {string} include path fragment, e.g. "src/"
 */
export function summarize(records, include) {
  const selected = records.filter((r) => r.file.includes(include));
  const total = { lines: { found: 0, hit: 0 }, branches: { found: 0, hit: 0 }, functions: { found: 0, hit: 0 } };
  for (const r of selected) {
    for (const kind of ["lines", "branches", "functions"]) {
      total[kind].found += r[kind].found;
      total[kind].hit += r[kind].hit;
    }
  }
  return { selected, total };
}

/** Percentage with two decimals; an empty set counts as fully covered. */
export function pct({ found, hit }) {
  return found === 0 ? 100 : Math.floor((hit / found) * 10_000) / 100;
}

function parseArgs(argv) {
  const args = { file: null, minBranches: null, minLines: null, include: "src/" };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--min-branches") args.minBranches = Number(argv[++i]);
    else if (arg === "--min-lines") args.minLines = Number(argv[++i]);
    else if (arg === "--include") args.include = argv[++i];
    else if (!arg.startsWith("--") && args.file === null) args.file = arg;
    else throw new Error(`unknown argument: ${arg}`);
  }
  if (!args.file) throw new Error("usage: check-coverage.mjs <lcov.info> [--min-branches N] [--min-lines N]");
  for (const [name, value] of [["--min-branches", args.minBranches], ["--min-lines", args.minLines]]) {
    if (value !== null && !(value >= 0 && value <= 100)) throw new Error(`${name} must be within 0..100`);
  }
  return args;
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const { selected, total } = summarize(parseLcov(readFileSync(args.file, "utf8")), args.include);
  if (selected.length === 0) {
    console.error(`no coverage records under "${args.include}" in ${args.file}`);
    process.exit(1);
  }
  const rows = selected.map((r) => [r.file, pct(r.lines), pct(r.branches), pct(r.functions)]);
  const width = Math.max(...rows.map((r) => r[0].length), 5);
  console.log(`${"file".padEnd(width)}  lines%  branches%  funcs%`);
  for (const [file, l, b, f] of rows) {
    console.log(`${file.padEnd(width)}  ${String(l).padStart(6)}  ${String(b).padStart(9)}  ${String(f).padStart(6)}`);
  }
  const line = (k) => `${total[k].hit}/${total[k].found} (${pct(total[k])}%)`;
  console.log(`\nTOTAL  lines ${line("lines")}  branches ${line("branches")}  functions ${line("functions")}`);

  let failed = false;
  if (args.minBranches !== null && pct(total.branches) < args.minBranches) {
    console.error(`branch coverage ${pct(total.branches)}% is below the ${args.minBranches}% gate`);
    failed = true;
  }
  if (args.minLines !== null && pct(total.lines) < args.minLines) {
    console.error(`line coverage ${pct(total.lines)}% is below the ${args.minLines}% gate`);
    failed = true;
  }
  if (failed) process.exit(1);
  console.log("coverage gate passed");
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    main();
  } catch (error) {
    console.error(error.message);
    process.exit(2);
  }
}
