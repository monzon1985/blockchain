// SPDX-License-Identifier: MIT
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  MUTATIONS,
  WORKSPACE_ENTRIES,
  applyMutation,
  childEnv,
  createWorkspace,
  failingTests,
  isKilled,
  writeMutant,
} from "../mutation-smoke.mjs";

test("every mutation applies to the current sources exactly once and changes them", () => {
  for (const m of MUTATIONS) {
    const source = readFileSync(m.file, "utf8");
    const mutated = applyMutation(source, m);
    assert.notEqual(mutated, source, `mutation #${m.id}`);
  }
});

test("applyMutation refuses ambiguous or missing anchors", () => {
  const m = { id: 99, file: "x.sol", edits: [["a", "b"]] };
  assert.throws(() => applyMutation("a a", m), /found 2/);
  assert.throws(() => applyMutation("c", m), /found 0/);
  assert.equal(applyMutation("xay", m), "xby");
});

test("failingTests reads unit, fuzz and invariant result lines", () => {
  const output = [
    "[PASS] test_ok() (gas: 1)",
    "[FAIL: boom] test_unit() (gas: 2)",
    "[FAIL: x; counterexample: calldata=0x args=[1, 2]] testFuzz_thing(uint256,uint256) (runs: 3)",
    "[FAIL: a non-lawful movement touching a restricted account] invariant_restrictedBalances",
  ].join("\n");
  assert.deepEqual([...failingTests(output)], ["test_unit", "testFuzz_thing", "invariant_restrictedBalances"]);
});

test("a mutant is killed only when every expected test fails", () => {
  const failing = new Set(["invariant_a"]);
  assert.equal(isKilled(1, failing, ["invariant_a"]), true);
  assert.equal(isKilled(1, failing, ["invariant_a", "invariant_b"]), false);
  assert.equal(isKilled(0, failing, ["invariant_a"]), false);
  assert.equal(isKilled(1, failing, []), false);
});

test("child runs default to the CI profile but respect an explicit one", () => {
  assert.equal(childEnv({ PATH: "x" }).FOUNDRY_PROFILE, "ci");
  assert.equal(childEnv({ FOUNDRY_PROFILE: "" }).FOUNDRY_PROFILE, "ci");
  assert.equal(childEnv({ FOUNDRY_PROFILE: "default" }).FOUNDRY_PROFILE, "default");
  assert.equal(childEnv({ PATH: "x" }).PATH, "x");
});

test("mutants are written into a temporary copy, never into the checkout", () => {
  const root = mkdtempSync(join(tmpdir(), "tpd-fake-project-"));
  try {
    for (const entry of WORKSPACE_ENTRIES) {
      if (entry.includes(".")) writeFileSync(join(root, entry), `${entry}\n`);
      else mkdirSync(join(root, entry));
    }
    writeFileSync(join(root, "src", "Token.sol"), "keep();\ncheck();\n");
    const m = { id: 1, file: "src/Token.sol", edits: [["check();\n", ""]] };
    const workspace = createWorkspace(root);
    try {
      writeMutant(workspace, m, readFileSync(join(root, m.file), "utf8"));
      assert.equal(readFileSync(join(workspace, m.file), "utf8"), "keep();\n");
      assert.equal(readFileSync(join(root, m.file), "utf8"), "keep();\ncheck();\n");
      assert.equal(readFileSync(join(workspace, "foundry.toml"), "utf8"), "foundry.toml\n");
    } finally {
      rmSync(workspace, { recursive: true, force: true });
    }
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
