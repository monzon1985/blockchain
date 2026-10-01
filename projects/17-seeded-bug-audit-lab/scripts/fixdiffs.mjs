#!/usr/bin/env node
// SPDX-License-Identifier: MIT
// One minimal, documented fix diff per finding, derived from the two source trees.
//
//   node scripts/fixdiffs.mjs           # (re)write report/diffs/<BUG>.diff
//   node scripts/fixdiffs.mjs --check   # CI: fail if the diffs drift from the trees
//
// How it works. `git diff --no-index -U0` lists every changed region between src/vulnerable and
// src/fixed. Each region must carry exactly one fix tag (`[SC05]`, `[REPLAY]`, ...) in its added
// lines, or sit at most three unchanged lines from a region that does (a code line under its
// tagged comment, a moved statement); otherwise the script fails. Nothing
// else may differ between the trees: NatSpec, layout and refactors are identical by construction.
// The patches are cumulative in the bug order of scoreboard/detection.json: patch k applies to
// src/vulnerable with patches 1..k-1 already applied, and applying all twelve reproduces
// src/fixed byte for byte, which --check verifies with an independent patch applier.

import { execFileSync } from "node:child_process";
import { readdirSync, statSync } from "node:fs";
import { join } from "node:path";
import { Outputs, ROOT, fail, readJson, readText } from "./lib.mjs";

const TAG = /\[(SC\d\d[ab]?|REPLAY)\]/g;
const CONTEXT = 3;

function listSol(dir, prefix = "") {
  const out = [];
  for (const name of readdirSync(join(ROOT, dir, prefix)).sort()) {
    const rel = prefix ? `${prefix}/${name}` : name;
    if (statSync(join(ROOT, dir, rel)).isDirectory()) out.push(...listSol(dir, rel));
    else if (name.endsWith(".sol")) out.push(rel);
  }
  return out;
}

function lines(text) {
  return (text.endsWith("\n") ? text.slice(0, -1) : text).split("\n");
}

/** Changed regions between the two versions of `rel`, from `git diff -U0`. */
function regions(rel) {
  let stdout = "";
  try {
    stdout = execFileSync(
      "git",
      ["diff", "--no-index", "--no-color", "--minimal", "-U0", `src/vulnerable/${rel}`, `src/fixed/${rel}`],
      { cwd: ROOT, encoding: "utf8" },
    );
  } catch (err) {
    if (err.status !== 1) throw err;
    stdout = err.stdout;
  }
  const out = [];
  let current = null;
  for (const line of stdout.replace(/\r\n/g, "\n").split("\n")) {
    const h = line.match(/^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/);
    if (h) {
      const oldStart = Number(h[1]);
      const oldCount = h[2] === undefined ? 1 : Number(h[2]);
      current = { file: rel, start: oldCount === 0 ? oldStart : oldStart - 1, oldLines: [], newLines: [] };
      out.push(current);
      continue;
    }
    if (!current) continue;
    if (line.startsWith("-") && !line.startsWith("---")) current.oldLines.push(line.slice(1));
    else if (line.startsWith("+") && !line.startsWith("+++")) current.newLines.push(line.slice(1));
  }
  return out;
}

/** Lines between two regions of the same file, in vulnerable-file coordinates. */
function gap(a, b) {
  const [first, second] = a.start <= b.start ? [a, b] : [b, a];
  return second.start - (first.start + first.oldLines.length);
}

function tagRegions(list, errors) {
  for (const r of list) {
    const tags = new Set([...r.newLines.join(" ").matchAll(TAG)].map((m) => m[1]));
    if (tags.size > 1) errors.push(`${r.file}:${r.start + 1}: one change region carries several tags ${[...tags]}`);
    r.tag = tags.size === 1 ? [...tags][0] : null;
  }
  // An untagged region (typically the code line under a tagged comment, or a moved line) belongs
  // to the fix whose tagged region is at most MAX_GAP unchanged lines away; anything else fails.
  const MAX_GAP = 3;
  for (const r of list.filter((x) => !x.tag)) {
    const near = new Set(list.filter((x) => x.tag && gap(x, r) <= MAX_GAP).map((x) => x.tag));
    if (near.size === 1) r.inherited = [...near][0];
    else {
      const what = r.newLines[0]?.trim() ?? `deletion of "${r.oldLines[0]?.trim()}"`;
      errors.push(`${r.file}:${r.start + 1}: cannot attribute untagged change ${JSON.stringify(what)} to one fix`);
    }
  }
  for (const r of list) if (r.inherited) r.tag = r.inherited;
}

function applyRegions(base, list) {
  const out = [...base];
  for (const r of [...list].sort((a, b) => b.start - a.start)) out.splice(r.start, r.oldLines.length, ...r.newLines);
  return out;
}

/** Unified-diff hunks turning `base` into base-with-`list`-applied (positions in `base`). */
function hunks(base, list) {
  const sorted = [...list].sort((a, b) => a.pos - b.pos);
  const groups = [];
  for (const r of sorted) {
    const s = Math.max(0, r.pos - CONTEXT);
    const e = Math.min(base.length, r.pos + r.oldLines.length + CONTEXT);
    const last = groups.at(-1);
    if (last && s <= last.e) {
      last.e = Math.max(last.e, e);
      last.items.push(r);
    } else groups.push({ s, e, items: [r] });
  }
  const text = [];
  let shift = 0;
  for (const g of groups) {
    const body = [];
    let i = g.s;
    let added = 0;
    let removed = 0;
    for (const r of g.items) {
      while (i < r.pos) body.push(" " + base[i++]);
      for (const l of r.oldLines) body.push("-" + l);
      for (const l of r.newLines) body.push("+" + l);
      i += r.oldLines.length;
      removed += r.oldLines.length;
      added += r.newLines.length;
    }
    while (i < g.e) body.push(" " + base[i++]);
    const oldCount = g.e - g.s;
    const newCount = oldCount - removed + added;
    text.push(`@@ -${g.s + 1},${oldCount} +${g.s + 1 + shift},${newCount} @@`, ...body);
    shift += added - removed;
  }
  return text;
}

/** Independent applier used by --check: strict context matching, no fuzz. */
function applyPatch(files, patch, errors, label) {
  let file = null;
  let lines_ = null;
  let offset = 0;
  const all = patch.split("\n");
  for (let k = 0; k < all.length; k++) {
    const line = all[k];
    if (line.startsWith("+++ b/")) {
      file = line.slice(6);
      lines_ = files.get(file);
      offset = 0;
      if (!lines_) errors.push(`${label}: patch touches unknown file ${file}`);
      continue;
    }
    const h = line.match(/^@@ -(\d+),(\d+) \+(\d+),(\d+) @@/);
    if (!h || !lines_) continue;
    let at = Number(h[1]) - 1 + offset;
    const replacement = [];
    let consumed = 0;
    let j = k + 1;
    for (; j < all.length && /^[ +-]/.test(all[j]) && !all[j].startsWith("--- ") && !all[j].startsWith("+++ "); j++) {
      const op = all[j][0];
      const content = all[j].slice(1);
      if (op === " " || op === "-") {
        if (lines_[at + consumed] !== content) {
          errors.push(`${label}: ${file}: context mismatch at line ${at + consumed + 1}`);
          return;
        }
        consumed++;
      }
      if (op === " " || op === "+") replacement.push(content);
    }
    lines_.splice(at, consumed, ...replacement);
    offset += replacement.length - consumed;
    k = j - 1;
  }
}

const check = process.argv.includes("--check");
const errors = [];
const detection = readJson("scoreboard/detection.json");
const order = detection.bugs.map((b) => b.id);

const vulnFiles = listSol("src/vulnerable");
const fixedFiles = listSol("src/fixed");
if (vulnFiles.join() !== fixedFiles.join()) errors.push(`the trees list different files: ${vulnFiles} vs ${fixedFiles}`);

const vuln = new Map(vulnFiles.map((f) => [f, lines(readText(`src/vulnerable/${f}`))]));
const fixed = new Map(fixedFiles.map((f) => [f, lines(readText(`src/fixed/${f}`))]));
const all = [];
for (const f of vulnFiles) {
  const list = regions(f);
  tagRegions(list, errors);
  all.push(...list);
}
for (const r of all) if (r.tag && !order.includes(r.tag)) errors.push(`${r.file}: tag [${r.tag}] is not a bug id`);
for (const id of order) if (!all.some((r) => r.tag === id)) errors.push(`no fix region is tagged [${id}]`);
if (errors.length) fail("fixdiffs", errors);

const outputs = new Outputs(check);
const patches = [];
order.forEach((id, k) => {
  const bug = detection.bugs[k];
  const earlier = new Set(order.slice(0, k));
  const out = [
    `# ${bug.finding} [${id}] ${bug.title}`,
    `# Fix ${k + 1} of ${order.length}. Apply the patches in order (${order[0]} ... ${order.at(-1)}) on top of`,
    "# src/vulnerable/ to obtain src/fixed/ exactly; `node scripts/fixdiffs.mjs --check` verifies this.",
  ];
  const files = [...new Set(all.filter((r) => r.tag === id).map((r) => r.file))];
  for (const f of files) {
    const prior = all.filter((r) => r.file === f && earlier.has(r.tag));
    const base = applyRegions(vuln.get(f), prior);
    const mine = all
      .filter((r) => r.file === f && r.tag === id)
      .map((r) => ({
        ...r,
        pos:
          r.start +
          prior.filter((e) => e.start < r.start).reduce((acc, e) => acc + e.newLines.length - e.oldLines.length, 0),
      }));
    out.push(`diff --git a/${f} b/${f}`, `--- a/${f}`, `+++ b/${f}`, ...hunks(base, mine));
  }
  const text = out.join("\n") + "\n";
  patches.push(text);
  outputs.emit(`report/diffs/${id}.diff`, text);
});

// Independent verification: the cumulative patches turn the vulnerable tree into the fixed one.
const working = new Map([...vuln].map(([f, l]) => [f, [...l]]));
patches.forEach((p, k) => applyPatch(working, p, errors, order[k]));
for (const [f, l] of working) {
  if (l.join("\n") !== fixed.get(f).join("\n")) errors.push(`applying all patches does not reproduce src/fixed/${f}`);
}
if (errors.length) fail("fixdiffs", errors);
const changed = all.reduce((acc, r) => acc + r.oldLines.length + r.newLines.length, 0);
console.log(`fixdiffs: ${all.length} tagged regions, ${changed} changed lines across ${new Set(all.map((r) => r.file)).size} files.`);
outputs.finish("fixdiffs");
