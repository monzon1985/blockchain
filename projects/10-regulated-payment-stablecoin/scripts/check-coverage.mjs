#!/usr/bin/env node
// SPDX-License-Identifier: MIT
//
// Coverage gate for `forge coverage --report lcov`.
//
//   node scripts/check-coverage.mjs lcov.info [--min-branches 90] [--min-lines 90] [--src src]
//
// * Totals are recomputed from the per-line (DA) and per-branch (BRDA) records rather than trusting the summary
//   counters, and only for files under `--src` (production code).
// * Completeness check: every Solidity file under `--src` that contains at least one function body must appear in
//   the report. A path filter such as `--no-match-coverage '(test|script)'` silently drops any file whose path
//   happens to contain "test" (e.g. "Attestation.sol"); this gate fails loudly instead of reporting inflated numbers.
//
// Exit codes: 0 pass, 1 threshold missed or file missing, 2 usage error.

import { readFileSync, readdirSync, statSync } from "node:fs";
import { join, relative, sep } from "node:path";
import { pathToFileURL } from "node:url";

/**
 * Parses an lcov tracefile into per-file line / branch / function counters.
 * @param {string} text lcov contents
 */
export function parseLcov(text) {
  const records = [];
  let current = null;
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (line.startsWith("SF:")) {
      current = { file: normalize(line.slice(3)), lines: new Map(), branches: new Map(), functions: new Map() };
    } else if (current === null) {
      continue;
    } else if (line.startsWith("DA:")) {
      const [lineNo, hits] = line.slice(3).split(",");
      current.lines.set(lineNo, (current.lines.get(lineNo) ?? 0) + Number(hits));
    } else if (line.startsWith("BRDA:")) {
      const [lineNo, block, branch, taken] = line.slice(5).split(",");
      const key = `${lineNo}:${block}:${branch}`;
      current.branches.set(key, (current.branches.get(key) ?? 0) + (taken === "-" ? 0 : Number(taken)));
    } else if (line.startsWith("FNDA:")) {
      const comma = line.indexOf(",");
      const name = line.slice(comma + 1);
      current.functions.set(name, (current.functions.get(name) ?? 0) + Number(line.slice(5, comma)));
    } else if (line === "end_of_record") {
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

/** Forward slashes, no leading "./". */
export function normalize(path) {
  return path.replaceAll("\\", "/").replace(/^\.\//, "");
}

/**
 * Sums the counters of the records under `srcDir`.
 * @param {ReturnType<typeof parseLcov>} records
 * @param {string} srcDir e.g. "src"
 */
export function summarize(records, srcDir) {
  const prefix = `${normalize(srcDir).replace(/\/$/, "")}/`;
  const selected = records.filter((r) => r.file.startsWith(prefix) || r.file.includes(`/${prefix}`));
  const total = { lines: { found: 0, hit: 0 }, branches: { found: 0, hit: 0 }, functions: { found: 0, hit: 0 } };
  for (const r of selected) {
    for (const kind of ["lines", "branches", "functions"]) {
      total[kind].found += r[kind].found;
      total[kind].hit += r[kind].hit;
    }
  }
  return { selected, total };
}

/** Percentage floored to two decimals; an empty set counts as fully covered. */
export function pct({ found, hit }) {
  return found === 0 ? 100 : Math.floor((hit / found) * 10_000) / 100;
}

/** True when Solidity source text contains at least one function (or modifier / constructor) with a body. */
export function hasExecutableCode(source) {
  const withoutComments = source.replace(/\/\*[\s\S]*?\*\//g, "").replace(/\/\/.*$/gm, "");
  return /\b(function|constructor|modifier)\b[^;{]*\{/.test(withoutComments);
}

/**
 * Lists the Solidity files under `srcDir` that contain executable code and are missing from `records`.
 * @param {string} srcDir
 * @param {ReturnType<typeof parseLcov>} records
 * @param {(path: string) => string} read file reader (injectable for tests)
 * @param {(dir: string) => string[]} list recursive lister (injectable for tests)
 */
export function missingFiles(srcDir, records, read = (p) => readFileSync(p, "utf8"), list = listSolidity) {
  const covered = new Set(records.map((r) => r.file));
  return list(srcDir)
    .map((p) => normalize(p))
    .filter((p) => hasExecutableCode(read(p)))
    .filter((p) => ![...covered].some((c) => c === p || c.endsWith(`/${p}`)));
}

/** Recursively lists `.sol` files under `dir`, as paths relative to the current directory. */
export function listSolidity(dir) {
  const out = [];
  for (const entry of readdirSync(dir)) {
    const full = join(dir, entry);
    if (statSync(full).isDirectory()) out.push(...listSolidity(full));
    else if (entry.endsWith(".sol")) out.push(relative(process.cwd(), full).split(sep).join("/"));
  }
  return out;
}

export function parseArgs(argv) {
  const args = { file: null, minBranches: null, minLines: null, src: "src" };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--min-branches") args.minBranches = Number(argv[++i]);
    else if (arg === "--min-lines") args.minLines = Number(argv[++i]);
    else if (arg === "--src") args.src = argv[++i];
    else if (!arg.startsWith("--") && args.file === null) args.file = arg;
    else throw new Error(`unknown argument: ${arg}`);
  }
  if (!args.file) throw new Error("usage: check-coverage.mjs <lcov.info> [--min-branches N] [--min-lines N] [--src dir]");
  for (const [name, value] of [
    ["--min-branches", args.minBranches],
    ["--min-lines", args.minLines],
  ]) {
    if (value !== null && !(value >= 0 && value <= 100)) throw new Error(`${name} must be within 0..100`);
  }
  return args;
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const records = parseLcov(readFileSync(args.file, "utf8"));
  const { selected, total } = summarize(records, args.src);
  const missing = missingFiles(args.src, records);

  const rows = selected.map((r) => [r.file, pct(r.lines), pct(r.branches), pct(r.functions)]);
  const width = Math.max(...rows.map((r) => r[0].length), 4);
  console.log(`${"file".padEnd(width)}  lines%  branches%  funcs%`);
  for (const [file, l, b, f] of rows) {
    console.log(`${file.padEnd(width)}  ${String(l).padStart(6)}  ${String(b).padStart(9)}  ${String(f).padStart(6)}`);
  }
  const fmt = (k) => `${total[k].hit}/${total[k].found} (${pct(total[k])}%)`;
  console.log(`\nTOTAL  lines ${fmt("lines")}  branches ${fmt("branches")}  functions ${fmt("functions")}`);

  let failed = false;
  if (missing.length > 0) {
    console.error(`files with executable code missing from ${args.file}: ${missing.join(", ")}`);
    failed = true;
  }
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

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    main();
  } catch (error) {
    console.error(error.message);
    process.exit(2);
  }
}
