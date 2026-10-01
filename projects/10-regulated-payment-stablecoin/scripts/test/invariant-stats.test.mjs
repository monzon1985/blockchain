// SPDX-License-Identifier: MIT
import { test } from "node:test";
import assert from "node:assert/strict";

import { COLUMNS, summarise } from "../invariant-stats.mjs";

const A = "0x00000000000000aa";
const B = "0x00000000000000bb";
const C = "0x00000000000000cc";

test("totals every column over every run (LF and CRLF, blank lines ignored)", () => {
  const { runs, duplicates, totals } = summarise(`${A},36,5,0,0,32,1\r\n${B},14,14,2,2,13,1\n\n${C},20,9,1,0,0,0\n`);
  assert.equal(runs, 3);
  assert.equal(duplicates, 0);
  assert.deepEqual(totals, [70, 28, 3, 2, 45, 2]);
});

test("the extra afterInvariant call after the last run is not counted twice", () => {
  const { runs, duplicates, totals } = summarise(`${A},1,1,1,1,1,1\n${B},22,2,0,2,21,1\n${B},22,2,0,2,21,1\n`);
  assert.equal(runs, 2);
  assert.equal(duplicates, 1);
  assert.deepEqual(totals, [23, 3, 1, 3, 22, 2]);
});

test("identical statistics from different runs are both counted", () => {
  const { runs, totals } = summarise(`${A},5,0,0,0,0,0\n${B},5,0,0,0,0,0\n`);
  assert.equal(runs, 2);
  assert.equal(totals[0], 10);
});

test("an empty file summarises to zero runs", () => {
  assert.deepEqual(summarise(""), { runs: 0, duplicates: 0, totals: new Array(COLUMNS.length).fill(0) });
});

test("malformed lines are rejected instead of silently skewing the totals", () => {
  assert.throws(() => summarise(`${A},1,2,3,4,5\n`), /malformed line/);
  assert.throws(() => summarise(`${A},1,2,3,4,5,x\n`), /malformed line/);
  assert.throws(() => summarise(`${A},1,2,3,4,-5,1\n`), /malformed line/);
  assert.throws(() => summarise("1,2,3,4,5,6\n"), /malformed line/);
});
