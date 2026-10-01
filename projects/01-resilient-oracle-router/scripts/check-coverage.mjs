#!/usr/bin/env node
// SPDX-License-Identifier: MIT
//
// Coverage gate for production code: reads an lcov report, keeps only files under the given prefixes (default
// `src/`), prints a per-file table and fails when line (or, optionally, branch / function) coverage is below the
// threshold. Zero dependencies (Node >= 20).
//
// Usage: node scripts/check-coverage.mjs lcov.info --min-lines 95 [--min-branches N] [--min-functions N]
//        [--include src/] [--exclude src/mocks/]

import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

/** Parses lcov text into one record per source file. */
export function parseLcov(text) {
  const files = [];
  let current = null;
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (line.startsWith("SF:")) {
      current = { file: normalize(line.slice(3)), lines: new Map(), lf: 0, lh: 0, brf: 0, brh: 0, fnf: 0, fnh: 0 };
    } else if (!current) {
      continue;
    } else if (line.startsWith("DA:")) {
      const [lineNo, hits] = line.slice(3).split(",");
      // A line can appear more than once (e.g. modifiers inlined twice): covered if any occurrence is hit.
      const previous = current.lines.get(lineNo) ?? 0;
      current.lines.set(lineNo, Math.max(previous, Number(hits)));
    } else if (line.startsWith("LF:")) {
      current.lf = Number(line.slice(3));
    } else if (line.startsWith("LH:")) {
      current.lh = Number(line.slice(3));
    } else if (line.startsWith("BRF:")) {
      current.brf = Number(line.slice(4));
    } else if (line.startsWith("BRH:")) {
      current.brh = Number(line.slice(4));
    } else if (line.startsWith("FNF:")) {
      current.fnf = Number(line.slice(4));
    } else if (line.startsWith("FNH:")) {
      current.fnh = Number(line.slice(4));
    } else if (line === "end_of_record") {
      // Prefer the DA entries (deduplicated) over LF/LH, which some tools double-count.
      if (current.lines.size > 0) {
        current.lf = current.lines.size;
        current.lh = [...current.lines.values()].filter((hits) => hits > 0).length;
      }
      files.push(current);
      current = null;
    }
  }
  return files;
}

/** Forward slashes and no leading `./`, so Windows and Linux reports compare equal. */
export function normalize(path) {
  return path.replaceAll("\\", "/").replace(/^\.\//, "");
}

/** Sums the selected files and checks them against the thresholds. */
export function evaluate(files, { include = ["src/"], exclude = [], minLines = 0, minBranches = 0, minFunctions = 0 }) {
  const selected = files.filter(
    (f) => include.some((p) => f.file.startsWith(p)) && !exclude.some((p) => f.file.startsWith(p)),
  );
  const total = selected.reduce(
    (acc, f) => ({
      lf: acc.lf + f.lf,
      lh: acc.lh + f.lh,
      brf: acc.brf + f.brf,
      brh: acc.brh + f.brh,
      fnf: acc.fnf + f.fnf,
      fnh: acc.fnh + f.fnh,
    }),
    { lf: 0, lh: 0, brf: 0, brh: 0, fnf: 0, fnh: 0 },
  );
  const pct = (hit, found) => (found === 0 ? 100 : (100 * hit) / found);
  const summary = {
    files: selected,
    lines: pct(total.lh, total.lf),
    branches: pct(total.brh, total.brf),
    functions: pct(total.fnh, total.fnf),
    total,
  };
  const failures = [];
  if (selected.length === 0) failures.push(`no files matched ${include.join(", ")}`);
  if (summary.lines < minLines) failures.push(`lines ${summary.lines.toFixed(2)}% < ${minLines}%`);
  if (summary.branches < minBranches) failures.push(`branches ${summary.branches.toFixed(2)}% < ${minBranches}%`);
  if (summary.functions < minFunctions) failures.push(`functions ${summary.functions.toFixed(2)}% < ${minFunctions}%`);
  return { ...summary, failures };
}

/** Parses `--flag value` pairs after the positional lcov path. */
export function parseArgs(argv) {
  const options = { include: [], exclude: [], minLines: 0, minBranches: 0, minFunctions: 0 };
  let path;
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    const value = () => {
      if (i + 1 >= argv.length) throw new Error(`missing value for ${arg}`);
      return argv[++i];
    };
    if (arg === "--min-lines") options.minLines = Number(value());
    else if (arg === "--min-branches") options.minBranches = Number(value());
    else if (arg === "--min-functions") options.minFunctions = Number(value());
    else if (arg === "--include") options.include.push(normalize(value()));
    else if (arg === "--exclude") options.exclude.push(normalize(value()));
    else if (arg.startsWith("--")) throw new Error(`unknown option ${arg}`);
    else if (path === undefined) path = arg;
    else throw new Error(`unexpected argument ${arg}`);
  }
  if (path === undefined) throw new Error("usage: check-coverage.mjs <lcov.info> --min-lines <pct>");
  for (const key of ["minLines", "minBranches", "minFunctions"]) {
    if (!Number.isFinite(options[key]) || options[key] < 0 || options[key] > 100) {
      throw new Error(`invalid threshold for ${key}`);
    }
  }
  if (options.include.length === 0) options.include.push("src/");
  return { path, options };
}

function format(result) {
  const rows = result.files.map((f) => [
    f.file,
    `${f.lh}/${f.lf}`,
    `${(f.lf === 0 ? 100 : (100 * f.lh) / f.lf).toFixed(2)}%`,
    `${f.brh}/${f.brf}`,
    `${f.fnh}/${f.fnf}`,
  ]);
  const t = result.total;
  rows.push([
    "TOTAL",
    `${t.lh}/${t.lf}`,
    `${result.lines.toFixed(2)}%`,
    `${t.brh}/${t.brf} (${result.branches.toFixed(2)}%)`,
    `${t.fnh}/${t.fnf} (${result.functions.toFixed(2)}%)`,
  ]);
  const header = ["File", "Lines", "Line %", "Branches", "Functions"];
  const widths = header.map((h, c) => Math.max(h.length, ...rows.map((r) => r[c].length)));
  const render = (r) => r.map((cell, c) => cell.padEnd(widths[c])).join("  ");
  return [render(header), widths.map((w) => "-".repeat(w)).join("  "), ...rows.map(render)].join("\n");
}

function main() {
  let parsed;
  try {
    parsed = parseArgs(process.argv.slice(2));
  } catch (error) {
    console.error(error.message);
    process.exit(2);
  }
  const result = evaluate(parseLcov(readFileSync(parsed.path, "utf8")), parsed.options);
  console.log(format(result));
  if (result.failures.length > 0) {
    console.error(`\nCoverage gate FAILED: ${result.failures.join("; ")}`);
    process.exit(1);
  }
  console.log(`\nCoverage gate passed (lines >= ${parsed.options.minLines}%).`);
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? "").href) main();
