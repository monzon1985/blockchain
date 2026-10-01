// SPDX-License-Identifier: MIT
import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { Rng } from "../support/random.js";

/** The property tests are only as wide as the generator behind them, so the generator has its own tests. */
describe("seeded PRNG behind the property tests", () => {
  it("int() reaches values above 2^32 when the range is wider (uint40 timestamps past 2106)", () => {
    const rng = new Rng(1);
    let largest = 0;
    for (let i = 0; i < 1_000; i++) {
      const value = rng.int(1, 2 ** 38);
      assert.ok(Number.isSafeInteger(value) && value >= 1 && value <= 2 ** 38, `out of range: ${value}`);
      largest = Math.max(largest, value);
    }
    assert.ok(largest > 2 ** 32, `largest of 1,000 draws in [1, 2^38] is ${largest}, not above 2^32`);
  });

  it("int() covers the whole uint40 range, up to its top 1/64", () => {
    const rng = new Rng(2);
    const max = 2 ** 40 - 1;
    let largest = 0;
    for (let i = 0; i < 1_000; i++) largest = Math.max(largest, rng.int(0, max));
    assert.ok(largest > max - max / 64, `largest draw ${largest}`);
  });

  it("int() stays inside small ranges and reaches both ends", () => {
    const rng = new Rng(3);
    const seen = new Set<number>();
    for (let i = 0; i < 2_000; i++) {
      const value = rng.int(-3, 3);
      assert.ok(value >= -3 && value <= 3, `out of range: ${value}`);
      seen.add(value);
    }
    assert.deepEqual(
      [...seen].sort((a, b) => a - b),
      [-3, -2, -1, 0, 1, 2, 3],
    );
    assert.equal(rng.int(7, 7), 7);
  });

  it("int() rejects inverted or unsafe bounds instead of silently narrowing them", () => {
    const rng = new Rng(4);
    assert.throws(() => rng.int(2, 1), RangeError);
    assert.throws(() => rng.int(0, 2 ** 53), RangeError);
    assert.throws(() => rng.int(0.5, 2), RangeError);
    assert.throws(() => rng.below(0n), RangeError);
  });

  it("below() and bigint() honour their bounds, including multi-word widths", () => {
    const rng = new Rng(5);
    const bound = 2n ** 128n - 1n;
    let largest = 0n;
    for (let i = 0; i < 500; i++) {
      const value = rng.below(bound);
      assert.ok(value >= 0n && value < bound);
      if (value > largest) largest = value;
      const wide = rng.bigint(77);
      assert.ok(wide >= 0n && wide < 2n ** 77n);
    }
    assert.ok(largest > bound / 2n, "below(2^128 - 1) never reached the upper half");
  });

  it("is deterministic for a given seed", () => {
    const a = new Rng(42);
    const b = new Rng(42);
    for (let i = 0; i < 100; i++) assert.equal(a.int(0, 2 ** 40), b.int(0, 2 ** 40));
  });
});
