#!/usr/bin/env node
// SPDX-License-Identifier: MIT
// Generated sections of report/REPORT.md and README.md.
//
//   node scripts/report.mjs           # rewrite the generated blocks
//   node scripts/report.mjs --check   # CI: fail if a block is stale
//
// Blocks:
//   nsloc          per-contract nSLOC table (REPORT §1)
//   nsloc-summary  one-line totals (README)
//   gas            v1 -> v2 gas of every fix, from gas/{vulnerable,fixed}/GasBench.json
//   diff-<BUG>     the fix diff of each finding, from report/diffs/<BUG>.diff
//
// nSLOC here = non-blank source lines that are not entirely comments (NatSpec and `//` lines are
// excluded; a code line with a trailing comment counts once). The counter below is the committed
// metric; it handles block comments and string literals.

import { Outputs, readJson, readText, replaceBlock } from "./lib.mjs";

/** Count non-blank, non-comment-only lines of Solidity source. */
export function nsloc(source) {
  let count = 0;
  let inBlock = false;
  for (const raw of source.split("\n")) {
    let code = "";
    let i = 0;
    let inString = null;
    while (i < raw.length) {
      const two = raw.slice(i, i + 2);
      if (inBlock) {
        if (two === "*/") {
          inBlock = false;
          i += 2;
        } else i++;
        continue;
      }
      if (inString) {
        code += raw[i];
        if (raw[i] === "\\") {
          code += raw[i + 1] ?? "";
          i += 2;
          continue;
        }
        if (raw[i] === inString) inString = null;
        i++;
        continue;
      }
      if (two === "//") break;
      if (two === "/*") {
        inBlock = true;
        i += 2;
        continue;
      }
      if (raw[i] === '"' || raw[i] === "'") inString = raw[i];
      code += raw[i++];
    }
    if (code.trim().length > 0) count++;
  }
  return count;
}

const CONTRACTS = [
  ["KestrelPool.sol", "Two-asset weighted AMM: proportional and exact-share joins, single and batch swaps, LP rewards, native-sponsored swap, TWAP accumulator"],
  ["KestrelVault.sol", "Native-ETH share vault (ERC-4626-shaped), dead-share inflation guard"],
  ["KestrelLending.sol", "Isolated lending market priced from the TWAP oracle and the vault share price"],
  ["KestrelGovernor.sol", "Snapshot proposals plus a supermajority emergency path"],
  ["KestrelRelayer.sol", "EIP-712 gasless-swap relayer (ECDSA and ERC-1271)"],
  ["KestrelProxy.sol", "Transparent proxy in front of the risk config"],
  ["lib/FixedPointMath.sol", "WAD/mulDiv helpers and the Q128 checked shift"],
];
const SHARED = [
  ["GovToken.sol", "ERC20Votes + ERC20FlashMint + ERC20Permit governance token"],
  ["KestrelConfig.sol", "Risk parameters (LTV, ETH price) behind the proxy"],
  ["PoolTwapOracle.sol", "Fixed-period TWAP with staleness bound"],
  ["IKestrelConfig.sol", "Config interface"],
  ["IPriceOracle.sol", "Oracle interface"],
];

const check = process.argv.includes("--check");
const outputs = new Outputs(check);

const rows = [];
let v1Total = 0;
let v2Total = 0;
for (const [file, what] of CONTRACTS) {
  const v1 = nsloc(readText(`src/vulnerable/${file}`));
  const v2 = nsloc(readText(`src/fixed/${file}`));
  v1Total += v1;
  v2Total += v2;
  rows.push(`| \`${file}\` | ${v1} | ${v2} | ${what} |`);
}
let sharedTotal = 0;
const sharedRows = [];
for (const [file, what] of SHARED) {
  const s = nsloc(readText(`src/shared/${file}`));
  sharedTotal += s;
  sharedRows.push(`| \`shared/${file}\` | ${s} | ${s} | ${what} |`);
}
const nslocTable = [
  "| Contract | nSLOC v1 (`src/vulnerable`) | nSLOC v2 (`src/fixed`) | Description |",
  "| --- | ---: | ---: | --- |",
  ...rows,
  `| **In-scope total** | **${v1Total}** | **${v2Total}** | |`,
  ...sharedRows,
  `| **Shared total** | **${sharedTotal}** | **${sharedTotal}** | identical in both trees |`,
  "",
  "nSLOC = non-blank lines that are not entirely comments, counted by `scripts/report.mjs` (`node scripts/report.mjs` regenerates this table).",
].join("\n");
const nslocSummary =
  `${v1Total} nSLOC in the vulnerable tree, ${v2Total} in the fixed tree, plus ${sharedTotal} nSLOC of shared code ` +
  `(counted by \`scripts/report.mjs\`).`;

const g1 = readJson("gas/vulnerable/GasBench.json");
const g2 = readJson("gas/fixed/GasBench.json");
const gasRows = Object.keys(g2)
  .sort()
  .map((op) => {
    const a = Number(g1[op]);
    const b = Number(g2[op]);
    const d = b - a;
    const pct = ((100 * d) / a).toFixed(1);
    return `| \`${op}\` | ${a.toLocaleString("en-US")} | ${b.toLocaleString("en-US")} | ${d >= 0 ? "+" : ""}${d.toLocaleString("en-US")} | ${d >= 0 ? "+" : ""}${pct}% |`;
  });
const gasTable = [
  "| Operation (fix it pays for) | v1 gas | v2 gas | Δ | Δ % |",
  "| --- | ---: | ---: | ---: | ---: |",
  ...gasRows,
  "",
  "Measured by `test/gas/GasBench.t.sol` with `vm.snapshotGasLastCall` under each profile; snapshots committed in " +
    "`gas/vulnerable/` and `gas/fixed/` and checked in CI with `FORGE_SNAPSHOT_CHECK=true`.",
].join("\n");

let report = readText("report/REPORT.md");
report = replaceBlock(report, "nsloc", nslocTable);
report = replaceBlock(report, "gas", gasTable);
for (const bug of readJson("scoreboard/detection.json").bugs) {
  const patch = readText(`report/diffs/${bug.id}.diff`)
    .split("\n")
    .filter((l) => !l.startsWith("#"))
    .join("\n")
    .trimEnd();
  report = replaceBlock(report, `diff-${bug.id}`, "```diff\n" + patch + "\n```");
}
outputs.emit("report/REPORT.md", report);

let readme = readText("README.md");
readme = replaceBlock(readme, "nsloc-summary", nslocSummary);
readme = replaceBlock(readme, "gas", gasTable);
outputs.emit("README.md", readme);
outputs.finish("report");
