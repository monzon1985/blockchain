// SPDX-License-Identifier: MIT
// Tests of the coverage gate itself: `node --test scripts/check-coverage.test.mjs`.

import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

import { evaluate, normalize, parseArgs, parseLcov } from "./check-coverage.mjs";

const LCOV = `TN:
SF:src/A.sol
FN:1,A.f
FNDA:1,A.f
FNF:1
FNH:1
DA:1,1
DA:2,0
DA:2,3
DA:3,5
BRDA:2,0,0,1
BRDA:2,0,1,0
BRF:2
BRH:1
LF:4
LH:3
end_of_record
SF:test/ATest.sol
DA:1,0
LF:1
LH:0
end_of_record
SF:src\\B.sol
DA:10,0
DA:11,1
BRF:0
BRH:0
FNF:0
FNH:0
end_of_record
`;

test("parses records and deduplicates repeated DA lines", () => {
  const files = parseLcov(LCOV);
  assert.equal(files.length, 3);
  const a = files[0];
  assert.equal(a.file, "src/A.sol");
  assert.equal(a.lf, 3, "line 2 appears twice but counts once");
  assert.equal(a.lh, 3, "line 2 is covered by its second occurrence");
  assert.equal(a.brf, 2);
  assert.equal(a.brh, 1);
});

test("normalizes Windows separators", () => {
  assert.equal(normalize("src\\B.sol"), "src/B.sol");
  assert.equal(normalize("./src/C.sol"), "src/C.sol");
  assert.equal(parseLcov(LCOV)[2].file, "src/B.sol");
});

test("only production files count", () => {
  const result = evaluate(parseLcov(LCOV), { include: ["src/"], minLines: 0 });
  assert.equal(result.files.length, 2);
  assert.equal(result.total.lf, 5);
  assert.equal(result.total.lh, 4);
  assert.equal(result.lines, 80);
});

test("fails below the threshold and passes at it", () => {
  assert.deepEqual(evaluate(parseLcov(LCOV), { minLines: 80 }).failures, []);
  assert.match(evaluate(parseLcov(LCOV), { minLines: 80.01 }).failures[0], /lines 80.00% < 80.01%/);
  assert.match(evaluate(parseLcov(LCOV), { minBranches: 60 }).failures[0], /branches 50.00% < 60%/);
});

test("excludes and empty selections", () => {
  const result = evaluate(parseLcov(LCOV), { include: ["src/"], exclude: ["src/B.sol"] });
  assert.equal(result.lines, 100);
  assert.match(evaluate(parseLcov(LCOV), { include: ["lib/"] }).failures[0], /no files matched/);
});

test("argument parsing", () => {
  const { path, options } = parseArgs(["lcov.info", "--min-lines", "95", "--exclude", "src/mocks/"]);
  assert.equal(path, "lcov.info");
  assert.equal(options.minLines, 95);
  assert.deepEqual(options.include, ["src/"]);
  assert.deepEqual(options.exclude, ["src/mocks/"]);
  assert.throws(() => parseArgs([]), /usage/);
  assert.throws(() => parseArgs(["x", "--min-lines"]), /missing value/);
  assert.throws(() => parseArgs(["x", "--min-lines", "101"]), /invalid threshold/);
  assert.throws(() => parseArgs(["x", "--bogus", "1"]), /unknown option/);
});

test("CLI exit codes", () => {
  const dir = mkdtempSync(join(tmpdir(), "cov-"));
  try {
    const file = join(dir, "lcov.info");
    writeFileSync(file, LCOV);
    const script = fileURLToPath(new URL("./check-coverage.mjs", import.meta.url));
    const out = execFileSync(process.execPath, [script, file, "--min-lines", "80"], { encoding: "utf8" });
    assert.match(out, /TOTAL\s+4\/5\s+80.00%/);
    assert.throws(
      () => execFileSync(process.execPath, [script, file, "--min-lines", "95"], { stdio: "pipe" }),
      (error) => error.status === 1,
    );
    assert.throws(
      () => execFileSync(process.execPath, [script], { stdio: "pipe" }),
      (error) => error.status === 2,
    );
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
