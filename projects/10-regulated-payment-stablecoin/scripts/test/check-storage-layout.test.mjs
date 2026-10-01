// SPDX-License-Identifier: MIT
import { test } from "node:test";
import assert from "node:assert/strict";

import { check, compareAppendOnly, flatten, liveLayout, normalizeLabel } from "../check-storage-layout.mjs";

// Shape of `forge inspect <probe> storageLayout --json` for a namespace struct with a nested struct member.
const PROBE = {
  storage: [{ label: "s", offset: 0, slot: "0", type: "t_struct(S)12_storage" }],
  types: {
    "t_struct(S)12_storage": {
      encoding: "inplace",
      label: "struct Mod.S",
      numberOfBytes: "128",
      members: [
        { label: "owner", offset: 0, slot: "0", type: "t_address" },
        { label: "paused", offset: 20, slot: "0", type: "t_bool" },
        { label: "balances", offset: 0, slot: "1", type: "t_mapping(t_address,t_uint256)" },
        { label: "window", offset: 0, slot: "2", type: "t_struct(W)34_storage" },
      ],
    },
    "t_struct(W)34_storage": {
      encoding: "inplace",
      label: "struct Lib.W",
      numberOfBytes: "64",
      members: [
        { label: "limit", offset: 0, slot: "0", type: "t_uint208" },
        { label: "items", offset: 0, slot: "1", type: "t_mapping(t_bytes32,t_struct(T)56_storage)" },
      ],
    },
    t_address: { encoding: "inplace", label: "address", numberOfBytes: "20" },
    t_bool: { encoding: "inplace", label: "bool", numberOfBytes: "1" },
    t_uint208: { encoding: "inplace", label: "uint208", numberOfBytes: "26" },
    "t_mapping(t_address,t_uint256)": {
      encoding: "mapping",
      label: "mapping(address => uint256)",
      numberOfBytes: "32",
    },
    "t_mapping(t_bytes32,t_struct(T)56_storage)": {
      encoding: "mapping",
      label: "mapping(bytes32 => struct Lib.T)",
      numberOfBytes: "32",
    },
  },
};

const baseline = () => flatten(PROBE).map((e) => ({ ...e, path: e.path.replace(/^s\./, "") }));

test("flatten expands nested structs with absolute slots and stable labels", () => {
  assert.deepEqual(
    baseline().map((e) => [e.path, e.slot, e.offset, e.type]),
    [
      ["owner", "0", 0, "address"],
      ["paused", "0", 20, "bool"],
      ["balances", "1", 0, "mapping(address => uint256)"],
      ["window.limit", "2", 0, "uint208"],
      ["window.items", "3", 0, "mapping(bytes32 => struct Lib.T)"],
    ],
  );
  assert.equal(normalizeLabel("t_struct(Foo)1234_storage"), "t_struct(Foo)_storage");
});

test("identical and appended layouts are compatible", () => {
  assert.deepEqual(compareAppendOnly("ns", baseline(), baseline()), []);
  const appended = [...baseline(), { path: "extra", slot: "4", offset: 0, type: "uint256", bytes: "32" }];
  assert.deepEqual(compareAppendOnly("ns", baseline(), appended), []);
});

test("insertion, retyping and removal are rejected", () => {
  const inserted = baseline().map((e) => (BigInt(e.slot) >= 1n ? { ...e, slot: String(BigInt(e.slot) + 1n) } : e));
  inserted.push({ path: "wedged", slot: "1", offset: 0, type: "uint256", bytes: "32" });
  const insertProblems = compareAppendOnly("ns", baseline(), inserted);
  assert.ok(insertProblems.some((p) => /balances changed slot from 1 to 2/.test(p)));
  assert.ok(insertProblems.some((p) => /new member wedged inserted at slot 1/.test(p)));

  const retyped = baseline().map((e) => (e.path === "paused" ? { ...e, type: "uint8" } : e));
  assert.deepEqual(compareAppendOnly("ns", baseline(), retyped), ["ns: member paused changed type from bool to uint8"]);

  const removed = baseline().filter((e) => e.path !== "window.items");
  assert.deepEqual(compareAppendOnly("ns", baseline(), removed), [
    "ns: member window.items (slot 3) was removed or renamed",
  ]);
});

test("check flags sequential storage, missing namespaces and a stale snapshot", () => {
  const live = { implementations: { V1: [], V2: [] }, namespaces: { a: baseline() } };
  assert.deepEqual(check(live, { namespaces: { a: baseline() } }, live), []);
  const withVar = { ...live, implementations: { V1: [], V2: [{ path: "oops" }] } };
  assert.match(check(withVar, { namespaces: {} }, withVar)[0], /V2 declares sequential storage \(oops\)/);
  assert.match(check(live, { namespaces: { gone: [] } }, live)[0], /gone: namespace from v1 is no longer present/);
  assert.match(check(live, { namespaces: {} }, null)[0], /missing/);
  assert.match(check(live, { namespaces: {} }, { ...live, namespaces: {} })[0], /stale/);
});

test("liveLayout strips the probe variable and keeps implementations separate", () => {
  const layout = liveLayout((name) => (name.startsWith("TestPaymentDollar") ? { storage: [], types: null } : PROBE));
  assert.deepEqual(layout.implementations.TestPaymentDollarV1, []);
  assert.equal(layout.namespaces["tpd.storage.Minting"][0].path, "owner");
});

test("fromArtifacts reads the storageLayout field of a unique artifact", async () => {
  const { mkdtempSync, mkdirSync, writeFileSync, rmSync } = await import("node:fs");
  const { tmpdir } = await import("node:os");
  const { join } = await import("node:path");
  const { fromArtifacts } = await import("../check-storage-layout.mjs");
  const dir = mkdtempSync(join(tmpdir(), "layout-"));
  try {
    mkdirSync(join(dir, "Probes.sol"));
    writeFileSync(join(dir, "Probes.sol", "P.json"), JSON.stringify({ storageLayout: PROBE }));
    writeFileSync(join(dir, "Probes.sol", "Q.json"), JSON.stringify({ abi: [] }));
    assert.deepEqual(fromArtifacts("P", dir), PROBE);
    assert.throws(() => fromArtifacts("Q", dir), /no storageLayout/);
    assert.throws(() => fromArtifacts("Missing", dir), /found 0/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
