// SPDX-License-Identifier: MIT
import { describe, expect, it } from "vitest";

import { amountAt, earliestAffordable } from "../src/decay.ts";
import { prng } from "./prng.ts";

describe("Dutch decay (mirror of DutchDecay.sol)", () => {
  it("matches the Solidity unit-test vectors", () => {
    expect(amountAt(1000n, 900n, 100n, 200n, 0n)).toBe(1000n);
    expect(amountAt(1000n, 900n, 100n, 200n, 100n)).toBe(1000n);
    expect(amountAt(1000n, 900n, 100n, 200n, 150n)).toBe(950n);
    expect(amountAt(1000n, 900n, 100n, 200n, 200n)).toBe(900n);
    expect(amountAt(1000n, 900n, 100n, 200n, 10_000n)).toBe(900n);
    expect(amountAt(10n, 9n, 0n, 3n, 1n)).toBe(10n); // rounds in favour of the user
    expect(amountAt(1000n, 1n, 500n, 500n, 10_000n)).toBe(1000n); // no decay window: flat
  });

  it("rejects an increasing curve", () => {
    expect(() => amountAt(1n, 2n, 0n, 10n, 5n)).toThrow(RangeError);
  });

  it("is bounded and non-increasing over random curves", () => {
    const rand = prng(7683n);
    for (let i = 0; i < 2000; i++) {
      const start = rand(10n ** 30n) + 1n;
      const end = rand(start + 1n);
      const ds = rand(10n ** 6n);
      const de = ds + rand(10n ** 5n);
      const t1 = rand(2n * 10n ** 6n);
      const t2 = t1 + rand(10n ** 5n);
      const a1 = amountAt(start, end, ds, de, t1);
      const a2 = amountAt(start, end, ds, de, t2);
      expect(a1).toBeGreaterThanOrEqual(a2);
      expect(a1 <= start && a1 >= end).toBe(true);
    }
  });

  it("finds the earliest affordable second exactly", () => {
    const rand = prng(1n);
    for (let i = 0; i < 2000; i++) {
      const start = rand(10n ** 24n) + 2n;
      const end = rand(start - 1n) + 1n;
      const ds = 1_000n + rand(1_000n);
      const de = ds + 1n + rand(10_000n);
      const from = rand(de + 100n);
      const max = end + rand(start - end + 1n);
      const t = earliestAffordable(start, end, ds, de, from, max);
      if (t === null) {
        expect(amountAt(start, end, ds, de, de)).toBeGreaterThan(max);
        continue;
      }
      expect(t).toBeGreaterThanOrEqual(from);
      expect(amountAt(start, end, ds, de, t)).toBeLessThanOrEqual(max);
      if (t > from) expect(amountAt(start, end, ds, de, t - 1n)).toBeGreaterThan(max);
    }
  });

  it("returns null when the budget is below the floor", () => {
    expect(earliestAffordable(1000n, 900n, 0n, 100n, 0n, 899n)).toBeNull();
  });
});
