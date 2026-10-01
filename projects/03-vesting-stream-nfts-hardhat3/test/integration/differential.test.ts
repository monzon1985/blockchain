// SPDX-License-Identifier: MIT
import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { network } from "hardhat";
import { formatUnits } from "viem";

import type { Milestone } from "../support/params.js";
import { Rng, runs } from "../support/random.js";

/**
 * Independent reference for `DecimalFormat.formatUnits`, built on viem's canonical `formatUnits` (exact decimal
 * string) and then truncated to four fractional digits with thousands separators.
 */
function referenceFormat(amount: bigint, decimals: number): string {
  if (amount === 0n) return "0";
  const [whole = "0", fraction = ""] = formatUnits(amount, decimals).split(".");
  const four = fraction.padEnd(4, "0").slice(0, 4).replace(/0+$/, "");
  if (whole === "0" && four === "") return "<0.0001";
  const grouped = whole.replace(/\B(?=(\d{3})+(?!\d))/g, ",");
  return four === "" ? grouped : `${grouped}.${four}`;
}

/** Exact rational reference for the linear curve: floor(deposit * elapsed / duration) between cliff and end. */
function referenceLinear(deposit: bigint, start: bigint, cliff: bigint, end: bigint, t: bigint): bigint {
  if (t < start || t < cliff) return 0n;
  if (t >= end) return deposit;
  return (deposit * (t - start)) / (end - start);
}

/** Reference for the piecewise-linear curve. */
function referenceSegmented(segments: readonly Milestone[], start: bigint, t: bigint): bigint {
  if (t <= start) return 0n;
  let vested = 0n;
  let previous = start;
  for (const s of segments) {
    const ts = BigInt(s.timestamp);
    if (t >= ts) {
      vested += s.amount;
      previous = ts;
      continue;
    }
    return vested + (s.amount * (t - previous)) / (ts - previous);
  }
  return vested;
}

describe("differential tests against independent TypeScript references", async () => {
  const { viem } = await network.create();
  const harness = await viem.deployContract("LibraryHarness");
  const rng = new Rng(0xd1ff);

  it(`formatUnits matches viem's formatUnits (truncated) on edge cases and ${runs(200)} random inputs`, async () => {
    const cases: Array<[bigint, number]> = [
      [0n, 18],
      [1n, 18],
      [10n ** 14n - 1n, 18],
      [10n ** 14n, 18],
      [999_999n, 6],
      [1_000_000n, 6],
      [123_456_789n, 0],
      [2n ** 256n - 1n, 0],
      [2n ** 256n - 1n, 18],
      [2n ** 256n - 1n, 77],
      [2n ** 256n - 1n, 78],
      [2n ** 256n - 1n, 81],
      [2n ** 256n - 1n, 82],
      [2n ** 256n - 1n, 255],
      [10n ** 77n, 77],
      [1n, 1],
      [19n, 1],
      [12_345n, 2],
      [5n, 3],
    ];
    for (let i = 0; i < runs(200); i++) {
      cases.push([rng.bigint(rng.int(1, 256)), rng.int(0, 90)]);
    }
    for (const [amount, decimals] of cases) {
      assert.equal(
        await harness.read.formatUnits([amount, decimals]),
        referenceFormat(amount, decimals),
        `${amount} @ ${decimals}`,
      );
    }
  });

  it(`linear curve matches the exact rational floor on ${runs(200)} random schedules`, async () => {
    for (let i = 0; i < runs(200); i++) {
      const deposit = rng.bigint(rng.int(1, 128));
      const start = rng.int(1, 2 ** 38);
      const end = start + rng.int(1, 2 ** 30);
      const cliff = rng.int(0, 1) === 0 || end - start < 2 ? 0 : rng.int(start + 1, end - 1);
      const t = rng.int(Math.max(0, start - 1000), end + 1000);
      const onChain = await harness.read.linear([deposit, start, cliff, end, t]);
      assert.equal(onChain, referenceLinear(deposit, BigInt(start), BigInt(cliff), BigInt(end), BigInt(t)));
    }
  });

  it(`segmented curve matches the reference on ${runs(100)} random 1-16 segment schedules`, async () => {
    for (let i = 0; i < runs(100); i++) {
      const start = rng.int(1, 2 ** 36);
      let ts = start;
      const segments: Milestone[] = Array.from({ length: rng.int(1, 16) }, () => {
        ts += rng.int(1, 10_000_000);
        return { amount: rng.int(0, 4) === 0 ? 0n : rng.bigint(rng.int(1, 120)), timestamp: ts };
      });
      const t = rng.int(start - 10, ts + 10);
      const onChain = await harness.read.segmented([segments, start, t]);
      assert.equal(onChain, referenceSegmented(segments, BigInt(start), BigInt(t)));
      const tranched = await harness.read.tranched([segments, t]);
      assert.equal(
        tranched,
        segments.filter((s) => s.timestamp <= t).reduce((sum, s) => sum + s.amount, 0n),
      );
    }
  });

  it("formatBps renders two decimals", async () => {
    for (const [bps, expected] of [
      [0n, "0.00%"],
      [1n, "0.01%"],
      [99n, "0.99%"],
      [100n, "1.00%"],
      [6342n, "63.42%"],
      [10_000n, "100.00%"],
    ] as const) {
      assert.equal(await harness.read.formatBps([bps]), expected);
    }
  });
});
