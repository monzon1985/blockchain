// SPDX-License-Identifier: MIT
import { test } from "node:test";
import assert from "node:assert/strict";

import { hasExecutableCode, missingFiles, parseArgs, parseLcov, pct, summarize } from "../check-coverage.mjs";

const LCOV = [
  "TN:",
  "SF:src/A.sol",
  "DA:1,1",
  "DA:2,0",
  "BRDA:3,0,0,1",
  "BRDA:3,0,1,-",
  "FNDA:1,foo",
  "end_of_record",
  "SF:src\\modules\\B.sol",
  "DA:1,5",
  "BRDA:9,0,0,2",
  "BRDA:9,0,1,1",
  "FNDA:0,bar",
  "end_of_record",
  "SF:test/T.sol",
  "DA:1,0",
  "end_of_record",
  "",
].join("\n");

test("parses per-file counters and normalizes Windows paths", () => {
  const records = parseLcov(LCOV);
  assert.equal(records.length, 3);
  assert.deepEqual(records[0], {
    file: "src/A.sol",
    lines: { found: 2, hit: 1 },
    branches: { found: 2, hit: 1 },
    functions: { found: 1, hit: 1 },
  });
  assert.equal(records[1].file, "src/modules/B.sol");
});

test("summarizes only production files", () => {
  const { selected, total } = summarize(parseLcov(LCOV), "src");
  assert.equal(selected.length, 2);
  assert.deepEqual(total.lines, { found: 3, hit: 2 });
  assert.deepEqual(total.branches, { found: 4, hit: 3 });
  assert.equal(pct(total.branches), 75);
});

test("pct floors to two decimals and treats empty sets as covered", () => {
  assert.equal(pct({ found: 3, hit: 2 }), 66.66);
  assert.equal(pct({ found: 0, hit: 0 }), 100);
});

test("detects executable code, ignoring comments, interfaces and constants", () => {
  assert.equal(hasExecutableCode("contract C { function f() external { } }"), true);
  assert.equal(hasExecutableCode("interface I { function f() external; event E(); }"), false);
  assert.equal(hasExecutableCode("library L { uint256 internal constant X = 1; }"), false);
  assert.equal(hasExecutableCode("// function f() { }\n/* function g() { } */ library L {}"), false);
  assert.equal(hasExecutableCode("contract C { constructor() { } }"), true);
});

test("reports files with code that the lcov report silently dropped", () => {
  // The classic trap: `--no-match-coverage '(test|script)'` drops "ReserveAttestation.sol" (it contains "test").
  const sources = {
    "src/A.sol": "contract A { function f() external {} }",
    "src/modules/B.sol": "contract B { function g() external {} }",
    "src/modules/ReserveAttestation.sol": "contract R { function h() external {} }",
    "src/interfaces/I.sol": "interface I { function f() external; }",
  };
  const missing = missingFiles(
    "src",
    parseLcov(LCOV),
    (p) => sources[p],
    () => Object.keys(sources),
  );
  assert.deepEqual(missing, ["src/modules/ReserveAttestation.sol"]);
});

test("argument parsing", () => {
  assert.deepEqual(parseArgs(["lcov.info", "--min-branches", "90"]), {
    file: "lcov.info",
    minBranches: 90,
    minLines: null,
    src: "src",
  });
  assert.throws(() => parseArgs([]), /usage/);
  assert.throws(() => parseArgs(["x", "--min-branches", "101"]), /0\.\.100/);
  assert.throws(() => parseArgs(["x", "--bogus"]), /unknown argument/);
});
