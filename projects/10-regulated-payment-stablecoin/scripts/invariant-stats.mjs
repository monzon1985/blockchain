#!/usr/bin/env node
// SPDX-License-Identifier: MIT
//
// Summarises the CSV written by StablecoinInvariants.afterInvariant when the campaign runs with
// TPD_INVARIANT_STATS=true. Each line is: run fingerprint (hex), moves, denied, lawful, shortfalls,
// movesAfterUpgrade, upgraded. Foundry 1.8.3 calls the hook once per run plus once more after the campaign on the
// last run's state; that extra line repeats the previous line's fingerprint and is dropped, so a 128-run campaign
// summarises to 128 runs.
//
//   rm -f demo-out/invariant-stats.csv
//   FOUNDRY_PROFILE=ci TPD_INVARIANT_STATS=true forge test --match-contract StablecoinInvariants
//   node scripts/invariant-stats.mjs [demo-out/invariant-stats.csv]

import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

export const COLUMNS = [
  "successful value movements",
  "attempts touching a restricted account (all refused)",
  "lawful orders executed (seize / burnFrozen)",
  "shortfall attestations recorded",
  "successful movements after the upgrade",
  "runs that upgraded mid-run",
];

/**
 * Parses the CSV into per-column totals over distinct runs.
 * @param {string} text CSV content.
 * @returns {{ runs: number, duplicates: number, totals: number[] }}
 */
export function summarise(text) {
  const rows = text
    .split(/\r?\n/)
    .filter((l) => l.trim() !== "")
    .map((line) => {
      const [fingerprint, ...rest] = line.split(",");
      const cells = rest.map(Number);
      if (
        !/^0x[0-9a-f]{16}$/i.test(fingerprint) ||
        cells.length !== COLUMNS.length ||
        cells.some((c) => !Number.isInteger(c) || c < 0)
      ) {
        throw new Error(`malformed line: ${line}`);
      }
      return { fingerprint: fingerprint.toLowerCase(), cells };
    });
  // A line whose fingerprint equals the previous line's is the extra afterInvariant call on the same run.
  const distinct = rows.filter((r, i) => i === 0 || r.fingerprint !== rows[i - 1].fingerprint);
  const totals = COLUMNS.map((_, i) => distinct.reduce((acc, r) => acc + r.cells[i], 0));
  return { runs: distinct.length, duplicates: rows.length - distinct.length, totals };
}

function main() {
  const file = process.argv[2] ?? "demo-out/invariant-stats.csv";
  const { runs, duplicates, totals } = summarise(readFileSync(file, "utf8"));
  console.log(`runs: ${runs} (${duplicates} repeated afterInvariant line(s) dropped)`);
  COLUMNS.forEach((name, i) => {
    const avg = runs === 0 ? 0 : totals[i] / runs;
    console.log(`${name.padEnd(54)} total ${String(totals[i]).padStart(7)}  per run ${avg.toFixed(1)}`);
  });
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main();
}
