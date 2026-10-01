// SPDX-License-Identifier: MIT
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import { parseLcov, pct, summarize } from "../check-coverage.mjs";

const SAMPLE = [
  "TN:",
  "SF:src/A.sol",
  "FN:3,A.f",
  "FNDA:2,A.f",
  "FN:9,A.g",
  "FNDA:0,A.g",
  "DA:3,2",
  "DA:4,2",
  "DA:9,0",
  "BRDA:4,0,0,2",
  "BRDA:4,0,1,-",
  "BRDA:5,1,0,1",
  "BRDA:5,1,1,1",
  "BRF:4",
  "BRH:3",
  "end_of_record",
  "SF:test/T.sol",
  "DA:1,0",
  "BRDA:1,0,0,-",
  "end_of_record",
  "",
].join("\n");

const script = fileURLToPath(new URL("../check-coverage.mjs", import.meta.url));

function runGate(lcov, ...args) {
  const dir = mkdtempSync(join(tmpdir(), "cov-"));
  const file = join(dir, "lcov.info");
  writeFileSync(file, lcov);
  return spawnSync(process.execPath, [script, file, ...args], { encoding: "utf8" });
}

test("parses DA / BRDA / FNDA records per file", () => {
  const [a, t] = parseLcov(SAMPLE);
  assert.equal(a.file, "src/A.sol");
  assert.deepEqual(a.lines, { found: 3, hit: 2 });
  assert.deepEqual(a.branches, { found: 4, hit: 3 });
  assert.deepEqual(a.functions, { found: 2, hit: 1 });
  assert.equal(t.file, "test/T.sol");
});

test("summarize only counts production files", () => {
  const { selected, total } = summarize(parseLcov(SAMPLE), "src/");
  assert.equal(selected.length, 1);
  assert.equal(pct(total.branches), 75);
  assert.equal(pct(total.lines), 66.66);
});

test("windows paths are normalised", () => {
  const [record] = parseLcov("SF:src\\B.sol\r\nDA:1,1\r\nend_of_record\r\n");
  assert.equal(record.file, "src/B.sol");
});

test("gate passes and fails on the branch threshold", () => {
  assert.equal(runGate(SAMPLE, "--min-branches", "75").status, 0);
  const failing = runGate(SAMPLE, "--min-branches", "90");
  assert.equal(failing.status, 1);
  assert.match(failing.stderr, /below the 90% gate/);
});

test("gate fails on the line threshold and on empty selections", () => {
  assert.equal(runGate(SAMPLE, "--min-lines", "70").status, 1);
  assert.equal(runGate(SAMPLE, "--include", "nothing/").status, 1);
});

test("rejects malformed arguments", () => {
  assert.equal(runGate(SAMPLE, "--min-branches", "150").status, 2);
  assert.equal(runGate(SAMPLE, "--bogus").status, 2);
});
