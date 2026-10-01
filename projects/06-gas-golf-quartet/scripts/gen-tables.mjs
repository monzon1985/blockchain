#!/usr/bin/env node
// SPDX-License-Identifier: MIT
//
// Regenerates the generated blocks of README.md and docs/TRICKS.md:
//   * gas, deployment and bytecode-size tables and the headline numbers, from
//       - snapshots/GasBench.json   written by `forge snapshot --match-contract GasBench` / `forge test`
//       - `forge inspect <artifact> deployedBytecode` for the runtime size of every implementation
//   * the test-suite counts, from `forge test --list --json`, the `check_` functions in test/halmos and
//     `node scripts/mutants.mjs --list`.
// Every sentence in a generated block that states a comparison is computed from the data, so a change
// that makes a claim false changes the text (and `--check` fails) instead of leaving a stale claim.
// (The mutants results block is written by scripts/mutants.mjs itself, which has to run them.)
//
// Usage:
//   node scripts/gen-tables.mjs           rewrite the generated blocks in place
//   node scripts/gen-tables.mjs --check   exit 1 if any generated block would change (drift)
//
// Generated blocks are delimited by <!-- gen:NAME:begin --> and <!-- gen:NAME:end --> markers; nothing
// outside the markers is touched.

import { execFileSync } from "node:child_process";
import { readdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const SNAPSHOT = join(ROOT, "snapshots", "GasBench.json");
const CHECK = process.argv.includes("--check");

function fail(message) {
  console.error(`gen-tables: ${message}`);
  process.exit(1);
}

// ---------------------------------------------------------------------------------------- inputs

let snapshot;
try {
  snapshot = JSON.parse(readFileSync(SNAPSHOT, "utf8"));
} catch (e) {
  fail(`cannot read ${SNAPSHOT} (${e.message}); run \`forge snapshot --match-contract GasBench\` first`);
}

function value(key) {
  if (!(key in snapshot)) fail(`snapshot key "${key}" is missing; is snapshots/GasBench.json up to date?`);
  const n = Number(snapshot[key]);
  if (!Number.isSafeInteger(n) || n < 0) fail(`snapshot key "${key}" is not a gas value: ${snapshot[key]}`);
  return n;
}

function run(cmd, args) {
  try {
    return execFileSync(cmd, args, { cwd: ROOT, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"], maxBuffer: 64 << 20 });
  } catch (e) {
    fail(`${cmd} ${args.join(" ")} failed: ${e.stderr || e.message}`);
  }
}

const IMPLS = [
  { id: "Solidity", label: "Solidity", artifact: "src/solidity/QuartetSolidity.sol:QuartetSolidity", appended: 0 },
  { id: "Assembly", label: "Inline assembly", artifact: "src/assembly/QuartetAssembly.sol:QuartetAssembly", appended: 0 },
  { id: "Yul", label: "Pure Yul", artifact: "src/yul/QuartetYul.yul:QuartetYul", appended: 0 },
  // Vyper stores its immutables after the runtime code at deployment: 4 immutables x 32 bytes.
  { id: "Vyper", label: "Vyper 0.4.3", artifact: "src/vyper/QuartetVyper.vy:QuartetVyper", appended: 128 },
  { id: "OpenZeppelin", label: "OZ 5.7 (reference)", artifact: "test/reference/OZReference.sol:OZReference", appended: 0 },
];
const GOLFED = ["Assembly", "Yul", "Vyper"];

function inspectRuntimeSize(artifact) {
  const out = run("forge", ["inspect", artifact, "deployedBytecode"]);
  const hex = out.trim().split(/\s+/).pop();
  if (!/^0x[0-9a-fA-F]*$/.test(hex)) fail(`unexpected forge inspect output for ${artifact}: ${out.slice(0, 120)}`);
  return (hex.length - 2) / 2;
}

// ---------------------------------------------------------------------------------------- formatting

const fmt = (n) => n.toLocaleString("en-US");

function delta(base, n) {
  const d = n - base;
  const sign = d < 0 ? "−" : d > 0 ? "+" : "±";
  const pct = Math.abs((d / base) * 100).toFixed(1);
  return `${sign}${fmt(Math.abs(d))} (${sign}${pct}%)`;
}

function table(header, rows) {
  const lines = [`| ${header.join(" | ")} |`, `|${header.map((_, i) => (i === 0 ? "---" : "---:")).join("|")}|`];
  for (const row of rows) lines.push(`| ${row.join(" | ")} |`);
  return lines.join("\n");
}

function bestOf(values, ids) {
  let best = null;
  for (const id of ids) if (best === null || values[id] < values[best]) best = id;
  return best;
}

function joinNames(names) {
  return names.length <= 1 ? names.join("") : `${names.slice(0, -1).join(", ")} and ${names.at(-1)}`;
}

// ---------------------------------------------------------------------------------------- ERC-20

const ERC20_TX = [
  ["transfer_new_holder", "`transfer` (new holder)", "`transfer`"],
  ["transfer_existing_holder", "`transfer` (existing holder)", "`transfer`"],
  ["approve", "`approve` (new allowance)", "`approve`"],
  ["transferFrom_finite", "`transferFrom` (finite allowance)", "`transferFrom`"],
  ["transferFrom_infinite", "`transferFrom` (infinite allowance)", "`transferFrom`"],
  ["permit", "`permit` (first permit)", "`permit`"],
];
const ERC20_VIEWS = [
  ["balanceOf", "`balanceOf`"],
  ["allowance", "`allowance`"],
  ["DOMAIN_SEPARATOR", "`DOMAIN_SEPARATOR`"],
];

function erc20Rows(metrics) {
  return metrics.map(([metric, label]) => {
    const v = Object.fromEntries(IMPLS.map((i) => [i.id, value(`erc20.${metric}.${i.id}`)]));
    const best = bestOf(v, GOLFED);
    const cells = IMPLS.map((i) => (i.id === best ? `**${fmt(v[i.id])}**` : fmt(v[i.id])));
    return [label, ...cells, `${IMPLS.find((i) => i.id === best).label}: ${delta(v.Solidity, v[best])}`];
  });
}

const header = ["Operation", ...IMPLS.map((i) => i.label), "Best golfed vs Solidity"];
const erc20Block = [
  "Transaction gas (21,000 base and calldata included; calldata is identical across implementations).",
  "",
  table(header, erc20Rows(ERC20_TX)),
  "",
  "View functions, gas of the call frame as seen by a calling contract (cold storage).",
  "",
  table(header, erc20Rows(ERC20_VIEWS)),
].join("\n");

// ---------------------------------------------------------------------------------------- deployment

const sizes = {};
for (const impl of IMPLS) {
  const inspected = inspectRuntimeSize(impl.artifact);
  const deployed = value(`deploy.runtime_bytes.${impl.id}`);
  if (inspected + impl.appended !== deployed) {
    fail(`${impl.id}: forge inspect reports ${inspected} runtime bytes, deployed code is ${deployed} (expected +${impl.appended})`);
  }
  sizes[impl.id] = { inspected, deployed };
}
const deployBlock = table(
  ["", ...IMPLS.map((i) => i.label)],
  [
    ["Deployment transaction gas", ...IMPLS.map((i) => fmt(value(`deploy.gas.${i.id}`)))],
    ["Runtime bytecode, `forge inspect` (bytes)", ...IMPLS.map((i) => fmt(sizes[i.id].inspected))],
    ["Deployed code (bytes)", ...IMPLS.map((i) => fmt(sizes[i.id].deployed))],
    [
      "Deployed code vs Solidity",
      ...IMPLS.map((i) => (i.id === "Solidity" ? "baseline" : delta(sizes.Solidity.deployed, sizes[i.id].deployed))),
    ],
  ],
);

// ---------------------------------------------------------------------------------------- math

const KERNELS = [
  ["Reference", "Reference (Solidity)"],
  ["Golf", "**Golf (CLZ)**"],
  ["Legacy", "Legacy (pre-Osaka)"],
  ["OpenZeppelin", "OZ 5.7 `Math`"],
  ["Solady", "Solady 0.1.26"],
];
// What runs on a chain without CLZ: our fallback and the two libraries.
const PRE_OSAKA = [
  ["Legacy", "Legacy"],
  ["OpenZeppelin", "OZ"],
  ["Solady", "Solady"],
];
const MATH = [
  ["mulDiv_512bit", "`mulDiv`, 512-bit product"],
  ["mulDiv_fits_256", "`mulDiv`, product fits 256 bits"],
  ["mulDivUp_512bit", "`mulDivUp`, 512-bit product"],
  ["sqrt_2pow256", "`sqrt(2^256 - 12346)`"],
  ["sqrt_2e18", "`sqrt(2e18)`"],
  ["log2", "`log2`"],
  ["log2Up", "`log2Up`"],
  ["clz", "`clz`"],
];

/// The cheapest pre-Osaka kernel for `metric`: its gas and every kernel that ties at that value.
function bestPreOsaka(metric) {
  const gas = Math.min(...PRE_OSAKA.map(([id]) => value(`math.${metric}.${id}`)));
  return { gas, names: PRE_OSAKA.filter(([id]) => value(`math.${metric}.${id}`) === gas).map(([, n]) => n) };
}

const mathBlock = [
  "Execution gas of one library call (a GAS-to-GAS window minus the cost of an empty window). \"Golf vs",
  "Legacy\" isolates the opcode (same algorithms); \"Golf vs best pre-Osaka\" compares with the cheapest code",
  "that runs without CLZ: Legacy, OpenZeppelin or Solady, whichever wins the row.",
  "",
  table(
    ["Function", ...KERNELS.map(([, label]) => label), "Golf vs Legacy", "Golf vs best pre-Osaka"],
    MATH.map(([metric, label]) => {
      const v = Object.fromEntries(KERNELS.map(([id]) => [id, value(`math.${metric}.${id}`)]));
      const best = bestPreOsaka(metric);
      return [
        label,
        ...KERNELS.map(([id]) => fmt(v[id])),
        delta(v.Legacy, v.Golf),
        `${delta(best.gas, v.Golf)} vs ${joinNames(best.names)}`,
      ];
    }),
  ),
].join("\n");

// ---------------------------------------------------------------------------------------- tricks

const TRICKS = [
  ["seeded_slot", "T1", "gas"],
  ["identity_slot", "T2", "gas"],
  ["selector_errors_call", "T3", "gas"],
  ["selector_errors_bytes", "T3", "bytes"],
  ["scratch_return_tx", "T4", "gas"],
  ["scratch_return_bytes", "T4", "bytes"],
  ["infinite_not", "T5", "gas"],
  ["signer_mul", "T6", "gas"],
  ["cache_xor", "T7", "gas"],
  ["validate_or", "T8", "gas"],
  ["log2_or_one", "T9", "gas"],
  ["from_check_once", "T10", "gas"],
  ["dispatch_transfer", "T11", "gas"],
  ["dispatch_domain_separator", "T11", "gas"],
  ["dispatch_bytes", "T11", "bytes"],
  ["proof_seam", "T13", "gas"],
  ["no_sender_check", "T15", "gas"],
];
const tricksBlock = table(
  ["Trick", "Micro-benchmark", "Before (A)", "After (B)", "Saving (A − B)"],
  TRICKS.map(([id, trick, unit]) => {
    const a = value(`trick.${id}.A`);
    const b = value(`trick.${id}.B`);
    const saving = a - b;
    return [trick, `\`${id}\``, `${fmt(a)} ${unit}`, `${fmt(b)} ${unit}`, `${saving >= 0 ? "" : "−"}${fmt(Math.abs(saving))} ${unit}`];
  }),
);

const saving = (from, to) => `${fmt(from - to)} gas (${(((from - to) / from) * 100).toFixed(0)}%)`;
const clzBlock = table(
  ["Kernel function", "Golf (CLZ opcode)", "Legacy (same algorithm)", "Saving vs Legacy", "Best pre-Osaka", "Saving vs best"],
  [
    ["log2", "log2"],
    ["log2Up", "log2Up"],
    ["clz", "clz"],
    ["sqrt (large)", "sqrt_2pow256"],
  ].map(([label, metric]) => {
    const g = value(`math.${metric}.Golf`);
    const l = value(`math.${metric}.Legacy`);
    const best = bestPreOsaka(metric);
    return [label, `${fmt(g)} gas`, `${fmt(l)} gas`, saving(l, g), `${fmt(best.gas)} gas (${joinNames(best.names)})`, saving(best.gas, g)];
  }),
);

// ---------------------------------------------------------------------------------------- headline

const pct = (from, to) => `${(((from - to) / from) * 100).toFixed(0)}%`;
const yulSavings = ERC20_TX.map(([metric, , op]) => ({
  op,
  saved: value(`erc20.${metric}.Solidity`) - value(`erc20.${metric}.Yul`),
}));
const cheaper = yulSavings.filter((s) => s.saved > 0);
const smallest = cheaper.reduce((a, b) => (b.saved < a.saved ? b : a), cheaper[0] ?? { op: "", saved: 0 });
const largest = cheaper.reduce((a, b) => (b.saved > a.saved ? b : a), cheaper[0] ?? { op: "", saved: 0 });
const callsClause =
  cheaper.length === yulSavings.length
    ? `and every one of the ${yulSavings.length} measured state-changing calls cheaper, from ` +
      `${fmt(smallest.saved)} gas off ${smallest.op} to ${fmt(largest.saved)} off ${largest.op}.`
    : `and ${cheaper.length} of the ${yulSavings.length} measured state-changing calls cheaper` +
      (cheaper.length ? ` (up to ${fmt(largest.saved)} gas off ${largest.op}).` : ".");

const log2Best = bestPreOsaka("log2");
const sqrtBest = bestPreOsaka("sqrt_2pow256");
const headlineBlock = [
  `- **Pure Yul vs idiomatic Solidity:** deployment ${fmt(value("deploy.gas.Solidity"))} → ` +
    `${fmt(value("deploy.gas.Yul"))} gas (−${pct(value("deploy.gas.Solidity"), value("deploy.gas.Yul"))}), ` +
    `deployed code ${fmt(sizes.Solidity.deployed)} → ${fmt(sizes.Yul.deployed)} bytes ` +
    `(−${pct(sizes.Solidity.deployed, sizes.Yul.deployed)}), ${callsClause}`,
  `- **Fusaka's CLZ opcode (EIP-7939) in a fixed-point kernel:** \`log2\` costs ${fmt(value("math.log2.Golf"))} gas ` +
    `against ${fmt(log2Best.gas)} for the cheapest pre-Osaka code we measured (${joinNames(log2Best.names)}; ` +
    `OpenZeppelin 5.7: ${fmt(value("math.log2.OpenZeppelin"))}); a CLZ-seeded \`sqrt\` costs ` +
    `${fmt(value("math.sqrt_2pow256.Golf"))} gas against ${fmt(sqrtBest.gas)} (${joinNames(sqrtBest.names)}, the ` +
    `cheapest pre-Osaka) and ${fmt(value("math.sqrt_2pow256.OpenZeppelin"))} (OpenZeppelin).`,
].join("\n");

// ---------------------------------------------------------------------------------------- test counts

const listed = (() => {
  const out = run("forge", ["test", "--list", "--json"]);
  const line = out
    .split(/\r?\n/)
    .filter((l) => l.startsWith("{"))
    .pop();
  if (!line) fail("`forge test --list --json` printed no JSON");
  const byContract = {};
  for (const [file, contracts] of Object.entries(JSON.parse(line))) {
    for (const [name, tests] of Object.entries(contracts)) byContract[name] = { file, tests };
  }
  return byContract;
})();

// Abstract harnesses forge lists but never runs on their own.
const ABSTRACT = ["ERC20Spec"];
const SPEC_IMPLS = ["OpenZeppelin", "Solidity", "Assembly", "Yul", "Vyper"];
const SUITES = [
  {
    label: "Specification x5",
    contracts: SPEC_IMPLS.map((i) => `ERC20Spec${i}Test`),
    what: (tests) =>
      `Every path of the shared surface on OZ, Solidity, assembly, Yul, Vyper (${tests.filter((t) => t.startsWith("testFuzz_")).length} fuzz tests each)`,
  },
  { label: "Storage layout", contracts: ["StorageLayoutTest"], what: () => "Slot formulas locate real state; an allowance write touches no balance or nonce" },
  { label: "Yul bytecode", contracts: ["YulBytecodeTest"], what: () => "Committed bytecode == forge's native solc build; deployed == emitted outside immutables" },
  {
    label: "Lockstep invariants",
    contracts: ["LockstepInvariantTest"],
    what: () => "128 x 64 calls locally, 256 x 64 in CI, state checked after every call",
  },
  {
    label: "Lockstep script",
    contracts: ["LockstepScriptedTest"],
    what: () => "The differential harness reaches every revert class and dirties every strictly typed argument word",
  },
  {
    label: "Math kernel",
    contracts: ["MathKernelTest"],
    what: () => "Fuzz vs reference, OZ, Solady, 512-bit oracle; exhaustive `sqrt` below 2\\*\\*16; every bit length",
  },
  { label: "CLZ opcode", contracts: ["ClzOpcodeTest"], what: () => "Real opcode == halmos model == 4 emulations on every bit length; opcode scan of bytecode" },
  { label: "Gas bench", contracts: ["GasBench"], what: () => "Deterministic numbers behind every table" },
];

for (const name of Object.keys(listed)) {
  if (!ABSTRACT.includes(name) && !SUITES.some((s) => s.contracts.includes(name))) {
    fail(`test contract ${name} (${listed[name].file}) is missing from the README suite table; add it to SUITES`);
  }
}

/// forge runs all invariant_ functions of a contract in one campaign and reports it as one test.
const forgeCount = (tests) => tests.filter((t) => !t.startsWith("invariant_")).length + (tests.some((t) => t.startsWith("invariant_")) ? 1 : 0);

let total = 0;
const countRows = SUITES.map((suite) => {
  const entries = suite.contracts.map((c) => listed[c] ?? fail(`forge lists no tests for ${c}`));
  const counts = entries.map((e) => forgeCount(e.tests));
  const sum = counts.reduce((a, b) => a + b, 0);
  total += sum;
  const invariants = entries[0].tests.filter((t) => t.startsWith("invariant_")).length;
  let cell;
  if (suite.contracts.length > 1) {
    if (new Set(counts).size !== 1) fail(`${suite.label}: the contracts have different test counts (${counts.join(", ")})`);
    cell = `${suite.contracts.length} x ${counts[0]} = ${sum}`;
  } else {
    cell = invariants ? `${sum} (${invariants} invariants)` : `${sum}`;
  }
  return [suite.label, `\`${entries[0].file}\``, cell, suite.what(entries[0].tests)];
});

const halmosChecks = readdirSync(join(ROOT, "test", "halmos"))
  .filter((f) => f.endsWith(".t.sol"))
  .flatMap((f) => [...readFileSync(join(ROOT, "test", "halmos", f), "utf8").matchAll(/function (check_\w+)\(/g)].map((m) => m[1]));
const mutantCount = JSON.parse(run(process.execPath, [join(ROOT, "scripts", "mutants.mjs"), "--list"])).length;

const countsBlock = [
  "| Suite | File | Tests | What it checks |",
  "|---|---|---:|---|",
  ...countRows.map((r) => `| ${r.join(" | ")} |`),
  `| **Foundry total** | | **${fmt(total)}** | \`forge test\` |`,
  `| Halmos | \`test/halmos/*.t.sol\` | ${halmosChecks.length} proofs | Properties 7-10 above |`,
  `| Mutants | \`scripts/mutants.mjs\` | ${mutantCount} mutants | Each must be caught (results below) |`,
].join("\n");

// ---------------------------------------------------------------------------------------- write / check

const BLOCKS = {
  "README.md": { headline: headlineBlock, counts: countsBlock, erc20: erc20Block, deploy: deployBlock, math: mathBlock },
  "docs/TRICKS.md": { tricks: tricksBlock, clz: clzBlock },
};

let drift = false;
for (const [file, blocks] of Object.entries(BLOCKS)) {
  const path = join(ROOT, file);
  const original = readFileSync(path, "utf8").replace(/\r\n/g, "\n");
  let updated = original;
  for (const [name, content] of Object.entries(blocks)) {
    const begin = `<!-- gen:${name}:begin -->`;
    const end = `<!-- gen:${name}:end -->`;
    const i = updated.indexOf(begin);
    const j = updated.indexOf(end);
    if (i < 0 || j < i) fail(`${file}: markers for block "${name}" are missing`);
    updated = `${updated.slice(0, i + begin.length)}\n${content}\n${updated.slice(j)}`;
  }
  if (updated !== original) {
    if (CHECK) {
      console.error(`gen-tables: ${file} is stale; run \`node scripts/gen-tables.mjs\``);
      drift = true;
    } else {
      writeFileSync(path, updated);
      console.log(`gen-tables: updated ${file}`);
    }
  } else {
    console.log(`gen-tables: ${file} is up to date`);
  }
}
if (drift) process.exit(1);
