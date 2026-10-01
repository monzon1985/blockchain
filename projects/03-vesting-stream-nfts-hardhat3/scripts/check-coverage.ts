// SPDX-License-Identifier: MIT
/**
 * Coverage gate: reads the `coverage/lcov.info` written by `npx hardhat test --coverage` and fails if line
 * coverage of the production contracts (everything under `contracts/` except the test-only `contracts/mocks/`,
 * which `hardhat.config.ts` already excludes from instrumentation) is below the threshold.
 *
 *   node scripts/check-coverage.ts [minPercent=90]
 */
import { readFile } from "node:fs/promises";
import path from "node:path";

const minimum = Number(process.argv[2] ?? 90);
const lcovPath = path.join(import.meta.dirname, "..", "coverage", "lcov.info");
const lcov = await readFile(lcovPath, "utf8");

interface FileCoverage {
  file: string;
  found: number;
  hit: number;
}

const files: FileCoverage[] = [];
let current: FileCoverage | undefined;
for (const line of lcov.split(/\r?\n/)) {
  if (line.startsWith("SF:")) current = { file: line.slice(3).replaceAll("\\", "/"), found: 0, hit: 0 };
  else if (line.startsWith("LF:") && current !== undefined) current.found = Number(line.slice(3));
  else if (line.startsWith("LH:") && current !== undefined) current.hit = Number(line.slice(3));
  else if (line === "end_of_record" && current !== undefined) {
    files.push(current);
    current = undefined;
  }
}

const production = files.filter((f) => f.file.includes("contracts/") && !f.file.includes("contracts/mocks/"));
if (production.length === 0) throw new Error(`no production files found in ${lcovPath}`);

let found = 0;
let hit = 0;
for (const f of production) {
  found += f.found;
  hit += f.hit;
  const pct = f.found === 0 ? 100 : (100 * f.hit) / f.found;
  console.log(`${pct.toFixed(2).padStart(6)} %  ${String(f.hit).padStart(4)}/${String(f.found).padEnd(4)} ${f.file}`);
}
const total = found === 0 ? 100 : (100 * hit) / found;
console.log(`\nProduction line coverage: ${total.toFixed(2)} % (${hit}/${found} lines, minimum ${minimum} %)`);
if (total < minimum) {
  console.error("Coverage gate failed");
  process.exitCode = 1;
}
