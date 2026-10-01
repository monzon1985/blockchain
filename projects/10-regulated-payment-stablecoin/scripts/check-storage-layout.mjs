#!/usr/bin/env node
// SPDX-License-Identifier: MIT
//
// Storage-layout gate for the UUPS upgrade path, built on solc's storage layout output: exactly what
// `forge inspect <contract> storageLayout --json` prints.
//
//   forge build && node scripts/check-storage-layout.mjs   # check (default; reads the layouts from out/)
//   node scripts/check-storage-layout.mjs --inspect        # same check, one `forge inspect` call per contract
//   node scripts/check-storage-layout.mjs --update         # rewrite storage-layout/current.json after a review
//   node scripts/check-storage-layout.mjs --init-v1        # (one-off) record the v1 baseline
//
// The default mode reads the `storageLayout` field that foundry.toml's `extra_output = ["storageLayout"]` adds to
// every artifact, which avoids 13 separate `forge inspect` processes; `--inspect` is the slower cross-check (CI runs
// both; they must agree).
//
// What is checked:
//   1. TestPaymentDollarV1 and TestPaymentDollarV2 have no sequential storage at all: every variable lives in an
//      ERC-7201 namespace (their `storage` arrays are empty).
//   2. Each namespace is inspected through a probe contract (test/layout/LayoutProbes.sol) that puts the namespace
//      struct at slot 0. The flattened layout (member path, slot, offset, type, size) must be *append-only
//      compatible* with storage-layout/v1.json, the layout shipped with v1: every v1 member keeps its slot, offset
//      and type, and new members may only be added after the last v1 slot. Namespaces introduced later (v2's
//      TransferCaps) have no v1 entry and are only required to match the committed snapshot.
//   3. The live layout must equal the committed snapshot storage-layout/current.json, so any layout change shows up
//      in review as a diff of that file.
//
// Exit codes: 0 pass, 1 incompatible or stale layout, 2 usage / tooling error.

import { execFileSync } from "node:child_process";
import { readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

export const IMPLEMENTATIONS = ["TestPaymentDollarV1", "TestPaymentDollarV2"];

export const NAMESPACES = [
  { id: "tpd.storage.Compliance", probe: "ComplianceLayoutProbe" },
  { id: "tpd.storage.Reserves", probe: "ReservesLayoutProbe" },
  { id: "tpd.storage.Minting", probe: "MintingLayoutProbe" },
  { id: "tpd.storage.TransferCaps", probe: "TransferCapsLayoutProbe", since: 2 },
  { id: "openzeppelin.storage.ERC20", probe: "OzERC20LayoutProbe" },
  { id: "openzeppelin.storage.EIP712", probe: "OzEIP712LayoutProbe" },
  { id: "openzeppelin.storage.Nonces", probe: "OzNoncesLayoutProbe" },
  { id: "openzeppelin.storage.Pausable", probe: "OzPausableLayoutProbe" },
  { id: "openzeppelin.storage.AccessManaged", probe: "OzAccessManagedLayoutProbe" },
  { id: "openzeppelin.storage.ERC3009", probe: "OzERC3009LayoutProbe" },
  { id: "openzeppelin.storage.Initializable", probe: "OzInitializableLayoutProbe" },
];

/**
 * Flattens a solc storage layout into one entry per leaf member, recursing into inline structs. Type identifiers
 * carry AST ids that change between builds, so entries use the human-readable type label instead.
 * @param {{storage: object[], types: Record<string, object> | null}} layout forge inspect output
 * @returns {{path: string, slot: string, offset: number, type: string, bytes: string}[]}
 */
export function flatten(layout) {
  const types = layout.types ?? {};
  const out = [];
  const visit = (members, base, prefix) => {
    for (const m of members) {
      const t = types[m.type];
      if (!t) throw new Error(`type ${m.type} missing from layout`);
      const slot = BigInt(base) + BigInt(m.slot);
      const path = prefix ? `${prefix}.${m.label}` : m.label;
      if (t.encoding === "inplace" && Array.isArray(t.members)) {
        visit(t.members, slot, path);
      } else {
        out.push({ path, slot: slot.toString(), offset: m.offset, type: normalizeLabel(t.label), bytes: t.numberOfBytes });
      }
    }
  };
  visit(layout.storage ?? [], 0n, "");
  return out;
}

/** Removes AST ids and file-local qualifiers that do not affect the layout. */
export function normalizeLabel(label) {
  return label.replace(/\)\d+_storage/g, ")_storage").replace(/\s+/g, " ").trim();
}

/**
 * Checks that `current` extends `baseline` append-only.
 * @returns {string[]} human-readable problems (empty when compatible)
 */
export function compareAppendOnly(namespace, baseline, current) {
  const problems = [];
  const byPath = new Map(current.map((e) => [e.path, e]));
  let lastBaselineSlot = -1n;
  for (const b of baseline) {
    if (BigInt(b.slot) > lastBaselineSlot) lastBaselineSlot = BigInt(b.slot);
    const c = byPath.get(b.path);
    if (!c) {
      problems.push(`${namespace}: member ${b.path} (slot ${b.slot}) was removed or renamed`);
      continue;
    }
    for (const key of ["slot", "offset", "type", "bytes"]) {
      if (String(c[key]) !== String(b[key])) {
        problems.push(`${namespace}: member ${b.path} changed ${key} from ${b[key]} to ${c[key]}`);
      }
    }
  }
  const known = new Set(baseline.map((b) => b.path));
  for (const c of current) {
    if (!known.has(c.path) && BigInt(c.slot) <= lastBaselineSlot) {
      problems.push(`${namespace}: new member ${c.path} inserted at slot ${c.slot}, inside the v1 layout`);
    }
  }
  return problems;
}

/**
 * Full check of a live layout against the v1 baseline and the committed snapshot.
 * @param {{implementations: Record<string, object[]>, namespaces: Record<string, object[]>}} live
 * @param {typeof live} v1 layout shipped with v1
 * @param {typeof live | null} snapshot committed storage-layout/current.json
 */
export function check(live, v1, snapshot) {
  const problems = [];
  for (const [name, entries] of Object.entries(live.implementations)) {
    if (entries.length !== 0) {
      problems.push(`${name} declares sequential storage (${entries.map((e) => e.path).join(", ")}); use a namespace`);
    }
  }
  for (const [id, baseline] of Object.entries(v1.namespaces)) {
    const current = live.namespaces[id];
    if (!current) problems.push(`${id}: namespace from v1 is no longer present`);
    else problems.push(...compareAppendOnly(id, baseline, current));
  }
  if (snapshot === null) {
    problems.push("storage-layout/current.json is missing; run with --update");
  } else if (JSON.stringify(snapshot) !== JSON.stringify(live)) {
    problems.push("storage-layout/current.json is stale; review the change and run with --update");
  }
  return problems;
}

/** Storage layout of `contract` from `forge inspect`. */
export function inspect(contract) {
  const json = execFileSync("forge", ["inspect", contract, "storageLayout", "--json"], {
    encoding: "utf8",
    maxBuffer: 64 * 1024 * 1024,
  });
  return JSON.parse(json.slice(json.indexOf("{")));
}

/** Storage layout of `contract` from its build artifact (`out/<File>.sol/<contract>.json`). */
export function fromArtifacts(contract, outDir = "out") {
  const matches = [];
  const walk = (dir) => {
    for (const entry of readdirSync(dir)) {
      const full = join(dir, entry);
      if (statSync(full).isDirectory()) walk(full);
      else if (entry === `${contract}.json`) matches.push(full);
    }
  };
  walk(outDir);
  if (matches.length !== 1) {
    throw new Error(
      `expected one artifact for ${contract}, found ${matches.length}; run forge build first ` +
        "(a slither run cleans out/ and rebuilds without test/)",
    );
  }
  const artifact = JSON.parse(readFileSync(matches[0], "utf8"));
  if (!artifact.storageLayout) throw new Error(`${matches[0]} has no storageLayout; run forge build first`);
  return artifact.storageLayout;
}

export function liveLayout(inspector = fromArtifacts) {
  const implementations = {};
  for (const name of IMPLEMENTATIONS) implementations[name] = flatten(inspector(name));
  const namespaces = {};
  for (const { id, probe } of NAMESPACES) {
    // The probe holds the struct in a variable named `s` at slot 0; strip that prefix.
    namespaces[id] = flatten(inspector(probe)).map((e) => ({ ...e, path: e.path.replace(/^s\./, "") }));
  }
  return { implementations, namespaces };
}

function readJson(path) {
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch (error) {
    if (error.code === "ENOENT") return null;
    throw error;
  }
}

function main() {
  const update = process.argv.includes("--update");
  const live = liveLayout(process.argv.includes("--inspect") ? inspect : fromArtifacts);
  if (process.argv.includes("--init-v1")) {
    const namespaces = Object.fromEntries(
      NAMESPACES.filter((n) => (n.since ?? 1) === 1).map((n) => [n.id, live.namespaces[n.id]]),
    );
    writeFileSync("storage-layout/v1.json", `${JSON.stringify({ implementations: {}, namespaces }, null, 2)}\n`);
    console.log("storage-layout/v1.json written");
  }
  if (update) {
    writeFileSync("storage-layout/current.json", `${JSON.stringify(live, null, 2)}\n`);
    console.log("storage-layout/current.json updated");
  }
  const v1 = readJson("storage-layout/v1.json");
  if (v1 === null) throw new Error("storage-layout/v1.json (the v1 baseline) is missing");
  const problems = check(live, v1, readJson("storage-layout/current.json"));
  const counted = Object.values(live.namespaces).reduce((n, entries) => n + entries.length, 0);
  console.log(
    `checked ${IMPLEMENTATIONS.length} implementations and ${NAMESPACES.length} namespaces (${counted} members) ` +
      `against the v1 baseline (${Object.keys(v1.namespaces).length} namespaces)`,
  );
  if (problems.length > 0) {
    for (const p of problems) console.error(`  - ${p}`);
    process.exit(1);
  }
  console.log("storage layout is upgrade-compatible");
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    main();
  } catch (error) {
    console.error(error.message);
    process.exit(2);
  }
}
