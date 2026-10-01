// SPDX-License-Identifier: MIT
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { StandardMerkleTree } from "@openzeppelin/merkle-tree";
import { allocate, buildDistribution, LEAF_ENCODING, verifyDistribution } from "../build-dividend-tree.mjs";

const fixtureDir = new URL("../../test/fixtures/", import.meta.url);
const readJson = (name) => JSON.parse(readFileSync(new URL(name, fixtureDir), "utf8"));

const A = "0x1111111111111111111111111111111111111111";
const B = "0x2222222222222222222222222222222222222222";
const C = "0x3333333333333333333333333333333333333333";

// Committed fixtures: 4 leaves (a perfect tree) plus 1, 3, 5 and 7 leaves, where the array-backed layout of
// OpenZeppelin's StandardMerkleTree is not a perfect binary tree. Each is cross-checked in Solidity.
const FIXTURES = [
  ["dividend-holders.json", "dividend-tree.json", 4],
  ["dividend-holders-1.json", "dividend-tree-1.json", 1],
  ["dividend-holders-3.json", "dividend-tree-3.json", 3],
  ["dividend-holders-5.json", "dividend-tree-5.json", 5],
  ["dividend-holders-7.json", "dividend-tree-7.json", 7],
];

test("every committed fixture is reproducible from its committed holders snapshot", () => {
  for (const [holders, tree, leaves] of FIXTURES) {
    const rebuilt = buildDistribution(readJson(holders));
    assert.deepEqual(rebuilt, readJson(tree), tree);
    assert.equal(rebuilt.count, leaves, tree);
  }
});

test("every proof in every fixture verifies against its root with the reference library", () => {
  for (const [, tree] of FIXTURES) {
    const artefact = readJson(tree);
    assert.equal(verifyDistribution(artefact), true);
    for (const { account, amount, proof } of artefact.claims) {
      assert.equal(StandardMerkleTree.verify(artefact.root, LEAF_ENCODING, [account, amount], proof), true);
      // A single-unit change in the entitlement must break the proof.
      const inflated = (BigInt(amount) + 1n).toString();
      assert.equal(StandardMerkleTree.verify(artefact.root, LEAF_ENCODING, [account, inflated], proof), false);
    }
  }
});

test("pro-rata allocation floors, never over-allocates, and drops zero entitlements", () => {
  const allocations = allocate(
    [
      { account: A, balance: "1" },
      { account: B, balance: "1" },
      { account: C, balance: "1" },
    ],
    100n,
  );
  assert.deepEqual(
    allocations.map((a) => a.amount),
    [33n, 33n, 33n],
  );
  const dust = allocate(
    [
      { account: A, balance: "1" },
      { account: B, balance: "1000000" },
    ],
    10n,
  );
  assert.equal(dust.length, 1, "an entitlement that floors to zero gets no leaf");
  assert.equal(dust[0].account, B);
});

test("artefact reports allocated amount and dust exactly", () => {
  const artefact = buildDistribution({
    recordDate: 1_767_571_200,
    totalAmount: "1000",
    holders: [
      { account: A, balance: "3" },
      { account: B, balance: "3" },
      { account: C, balance: "1" },
    ],
  });
  const sum = artefact.claims.reduce((s, c) => s + BigInt(c.amount), 0n);
  assert.equal(artefact.allocatedAmount, sum.toString());
  assert.equal(BigInt(artefact.allocatedAmount) + BigInt(artefact.undistributedDust), 1000n);
  assert.equal(artefact.count, 3);
  assert.ok(BigInt(artefact.undistributedDust) < 3n, "dust is below one unit per holder");
});

test("claims are sorted by account for deterministic output", () => {
  const artefact = buildDistribution({
    recordDate: 1,
    totalAmount: "9",
    holders: [
      { account: C, balance: "1" },
      { account: A, balance: "1" },
      { account: B, balance: "1" },
    ],
  });
  assert.deepEqual(
    artefact.claims.map((c) => c.account),
    [A, B, C],
  );
});

test("input validation", () => {
  const holders = [{ account: A, balance: "1" }];
  assert.throws(() => buildDistribution({ recordDate: 0, totalAmount: "1", holders }), /recordDate/);
  assert.throws(() => buildDistribution({ recordDate: 1, totalAmount: "0", holders }), /positive/);
  assert.throws(() => buildDistribution({ recordDate: 1, totalAmount: "-5", holders }), /non-negative integer/);
  assert.throws(() => buildDistribution({ recordDate: 1, totalAmount: "1", holders: [] }), /non-empty/);
  assert.throws(
    () => buildDistribution({ recordDate: 1, totalAmount: "1", holders: [{ account: "0x12", balance: "1" }] }),
    /not an address/,
  );
  assert.throws(
    () =>
      buildDistribution({
        recordDate: 1,
        totalAmount: "1",
        holders: [
          { account: A, balance: "1" },
          { account: A.toUpperCase().replace("0X", "0x"), balance: "1" },
        ],
      }),
    /duplicate/,
  );
  assert.throws(
    () => buildDistribution({ recordDate: 1, totalAmount: "1", holders: [{ account: A, balance: "0" }] }),
    /zero/,
  );
  assert.throws(
    () =>
      buildDistribution({
        recordDate: 1,
        totalAmount: "1",
        holders: [
          { account: A, balance: "1" },
          { account: B, balance: "5" },
        ],
      }),
    /no holder is entitled/,
  );
});
