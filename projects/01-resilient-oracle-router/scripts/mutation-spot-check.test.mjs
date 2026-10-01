// SPDX-License-Identifier: MIT
//
// Tests of the mutation spot-check's helpers (`node --test scripts/mutation-spot-check.test.mjs`). They do not run
// any mutant: they check the output parser and that every mutant applies to exactly one place in the current code.

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import { failingTests, MUTANTS } from "./mutation-spot-check.mjs";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");

test("parses unit, fuzz and table failures by their signature", () => {
  const output = [
    "[PASS] test_Healthy() (gas: 1)",
    "[FAIL: assertion failed] test_Stale_Strict() (gas: 164609)",
    "[FAIL: next call did not revert as expected; counterexample: calldata=0x args=[1]] testFuzz_Ring(uint256) (runs: 3)",
    "[FAIL: status] tableValidationTest((string,uint8,uint8,bytes4)) (runs: 10)",
  ].join("\n");
  assert.deepEqual(failingTests(output), ["test_Stale_Strict", "testFuzz_Ring", "tableValidationTest"]);
});

test("parses invariant failures, printed by name alone, and deduplicates", () => {
  const output = [
    "[FAIL: panic: division or modulo by zero (0x12)] invariant_debtNeverBelowCollateral",
    "\t[Sequence] (original: 30, shrunk: 1)",
    "\t\tsender=0x01 addr=[test/invariant/OracleSystem.sol:OracleSystem]0x02 calldata=silencePrimary(uint256,uint256) args=[200, 10698]",
    "[FAIL: panic: division or modulo by zero (0x12)] invariant_fallbackIsExactTwapOfValidatedAnswers  ",
    "Failing tests:",
    "[FAIL: panic: division or modulo by zero (0x12)] invariant_debtNeverBelowCollateral",
  ].join("\r\n");
  assert.deepEqual(failingTests(output), [
    "invariant_debtNeverBelowCollateral",
    "invariant_fallbackIsExactTwapOfValidatedAnswers",
  ]);
});

test("a failure without a recognizable name is still counted", () => {
  assert.deepEqual(failingTests("[FAIL: setUp() failed: revert]"), ["unknown"]);
});

test("every mutant applies to exactly one place, and ids are unique", () => {
  const ids = new Set();
  for (const m of MUTANTS) {
    assert.ok(!ids.has(m.id), `duplicate id ${m.id}`);
    ids.add(m.id);
    const text = readFileSync(join(root, m.file), "utf8");
    assert.equal(text.split(m.from).length - 1, 1, `${m.id}: anchor must match exactly once`);
    assert.notEqual(m.from, m.to, `${m.id}: the mutant changes nothing`);
  }
});
