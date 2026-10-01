#!/usr/bin/env node
// SPDX-License-Identifier: MIT
//
// Storage-layout gate: the driver around the `layout-diff` Rust CLI.
//
//   node scripts/check-layouts.mjs           check everything (CI mode; fails on any unsafe diff or drift)
//   node scripts/check-layouts.mjs --write   regenerate layout-diff/tests/fixtures from the current build
//
// Steps
//   1. `forge build`; a second, cache-less build into out-layout/ whose single build-info file gives one consistent
//      AST of every source (an incremental build mixes AST id spaces); `cargo build --release --locked` of
//      layout-diff.
//   2. For every contract named in layouts.config.json:
//      - `forge inspect <C> storageLayout --json` for the sequential layout;
//      - the code that runs against <C>'s storage: its inheritance linearization (plus, for the diamond, the facets
//        it delegatecalls) and every library or free function that code reaches, followed through the AST;
//      - every struct annotated `@custom:storage-location erc7201:<id>` that this code declares or reaches,
//        libraries included, and the probe contract of each (test/layout) for its absolute layout;
//      - every accessor of such a struct (`$.slot := ...` in inline assembly) with the slot it assigns, resolved
//        from the AST through constants, the `erc7201` builtin and pure getters. layout-diff checks each one
//        against the ERC-7201 formula, so a typo'd or copy-pasted location in production code is caught even when
//        the probe is right. An accessor that cannot be resolved statically fails closed, and so does a struct
//        placed at a constant slot without an annotation.
//      Snapshots are normalized (AST ids removed), written to out-layout/gate (which every check below reads, so
//      the gate always judges the code just built) and must be byte-identical to the committed fixtures in
//      layout-diff/tests/fixtures/snapshots (the Rust golden tests read those).
//   3. `layout-diff diff` for every consecutive version pair of each chain (must pass, with the reviewed
//      allowances), for every mustFail pair (must exit non-zero with the expected finding kinds) and every
//      mustPass pair; `layout-diff lint` for single layouts (the diamond).
//   4. `layout-diff selectors` for the routing table the diamond is really cut with (`DiamondSelectors`, read from
//      the AST: the same library the deployment script and the tests use) and for the clash fixtures (must fail);
//      every facet that table routes to must be one of the diamond's delegates in step 2, so no routed code escapes
//      the storage analysis; the shared API interface must be fully served by UUPS V3's ABI and by that table.

import { spawn, spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const WRITE = process.argv.includes("--write");
const FIXTURES = join(root, "layout-diff", "tests", "fixtures");
const config = JSON.parse(readFileSync(join(root, "layouts.config.json"), "utf8"));
const failures = [];

function fail(message) {
  failures.push(message);
  console.log(`  FAIL ${message}`);
}

function runSync(cmd, args, options = {}) {
  const res = spawnSync(cmd, args, { cwd: root, encoding: "utf8", maxBuffer: 256 * 1024 * 1024, ...options });
  if (res.error) throw new Error(`${cmd} ${args.join(" ")}: ${res.error.message}`);
  return res;
}

function runAsync(cmd, args) {
  return new Promise((resolve, reject) => {
    const child = spawn(cmd, args, { cwd: root });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (d) => (stdout += d));
    child.stderr.on("data", (d) => (stderr += d));
    child.on("error", reject);
    child.on("close", (status) => resolve({ status, stdout, stderr }));
  });
}

async function pool(items, size, worker) {
  const results = new Array(items.length);
  let next = 0;
  const lanes = Array.from({ length: Math.min(size, items.length) }, async () => {
    while (next < items.length) {
      const i = next++;
      results[i] = await worker(items[i]);
    }
  });
  await Promise.all(lanes);
  return results;
}

async function forgeInspect(contract, field) {
  const res = await runAsync("forge", ["inspect", contract, field, "--json"]);
  if (res.status !== 0) throw new Error(`forge inspect ${contract} ${field} failed:\n${res.stderr}`);
  return JSON.parse(res.stdout);
}

// ------------------------------------------------------------------ 1. builds

console.log("• forge build");
{
  const res = runSync("forge", ["build"]);
  if (res.status !== 0) {
    console.error(res.stdout, res.stderr);
    process.exit(2);
  }
}

console.log("• forge build (profile layout: one cache-less compilation for the AST analysis)");
const LAYOUT_OUT = join(root, "out-layout");
const FRESH = join(LAYOUT_OUT, "gate"); // snapshots and selector sets built by this run, read by every check
rmSync(LAYOUT_OUT, { recursive: true, force: true });
{
  const res = runSync("forge", ["build"], { env: { ...process.env, FOUNDRY_PROFILE: "layout" } });
  if (res.status !== 0) {
    console.error(res.stdout, res.stderr);
    process.exit(2);
  }
}

console.log("• cargo build --release --locked (layout-diff)");
{
  const res = runSync("cargo", ["build", "--release", "--locked", "--manifest-path", "layout-diff/Cargo.toml"], {
    stdio: "inherit",
  });
  if (res.status !== 0) process.exit(2);
}
const BIN = join(root, "layout-diff", "target", "release", process.platform === "win32" ? "layout-diff.exe" : "layout-diff");

// ------------------------------------------------------------------ 2a. the AST of one compilation

const buildInfoDir = join(LAYOUT_OUT, "build-info");
const buildInfos = readdirSync(buildInfoDir).filter((f) => f.endsWith(".json"));
if (buildInfos.length !== 1) {
  throw new Error(`expected exactly one compilation in ${buildInfoDir}, found ${buildInfos.length}`);
}
const buildInfo = JSON.parse(readFileSync(join(buildInfoDir, buildInfos[0]), "utf8"));

/** node id -> node, over every source of the compilation. */
const nodeById = new Map();
/** solc source index -> source text (for unresolved expressions in messages). */
const sourceText = new Map();
for (const [path, out] of Object.entries(buildInfo.output.sources)) {
  sourceText.set(out.id, Buffer.from(buildInfo.input.sources[path]?.content ?? "", "utf8"));
  (function index(node) {
    if (Array.isArray(node)) return node.forEach(index);
    if (!node || typeof node !== "object") return;
    if (typeof node.id === "number" && typeof node.nodeType === "string" && !node.nodeType.startsWith("Yul")) {
      nodeById.set(node.id, node);
    }
    for (const value of Object.values(node)) if (value && typeof value === "object") index(value);
  })(out.ast);
}

function walk(node, visit) {
  if (Array.isArray(node)) return node.forEach((n) => walk(n, visit));
  if (!node || typeof node !== "object") return;
  visit(node);
  for (const value of Object.values(node)) if (value && typeof value === "object") walk(value, visit);
}

function contractNamed(name) {
  const found = [...nodeById.values()].filter((n) => n.nodeType === "ContractDefinition" && n.name === name);
  if (found.length !== 1) throw new Error(`expected one contract named ${name}, found ${found.length}`);
  return found[0];
}

function snippet(src) {
  const [start, length, file] = src.split(":").map(Number);
  return sourceText.get(file)?.subarray(start, start + length).toString("utf8").replace(/\s+/g, " ") ?? src;
}

const LOCATION = /@custom:storage-location\s+erc7201:([^\s]+)/;
const annotationOf = (struct) => LOCATION.exec(struct.documentation?.text ?? "")?.[1];

function scopeName(node) {
  const scope = nodeById.get(node.scope);
  return scope?.nodeType === "ContractDefinition" ? scope.name : "<free>";
}

// ------------------------------------------------------------------ 2b. static evaluation of slot expressions

/** The most-derived override of `fn` within the linearization `bases` (ContractDefinitions, most derived first). */
function mostDerived(fn, bases) {
  if (!fn.virtual) return fn;
  const overrides = (candidate) => {
    const seen = new Set();
    const stack = [...(candidate.baseFunctions ?? [])];
    while (stack.length > 0) {
      const id = stack.pop();
      if (id === fn.id) return true;
      if (seen.has(id)) continue;
      seen.add(id);
      stack.push(...(nodeById.get(id)?.baseFunctions ?? []));
    }
    return false;
  };
  for (const base of bases) {
    const hit = (base.nodes ?? []).find((m) => m.nodeType === "FunctionDefinition" && overrides(m));
    if (hit) return hit;
  }
  return fn;
}

/**
 * Evaluates a Solidity expression to {erc7201: id} | {slot: hex} | {string: s}, or null when it is not a
 * compile-time constant this driver understands (literals, constants, `erc7201(...)`, type conversions, and
 * calls to pure functions that return such an expression).
 */
function evaluate(expr, bases, depth = 0) {
  if (!expr || depth > 16) return null;
  switch (expr.nodeType) {
    case "Literal":
      if (expr.kind === "number" && !expr.subdenomination) {
        return { slot: `0x${BigInt(expr.value.replaceAll("_", "")).toString(16)}` };
      }
      if (expr.kind === "string") return { string: expr.value };
      return null;
    case "Identifier": {
      const decl = nodeById.get(expr.referencedDeclaration);
      if (decl?.nodeType === "VariableDeclaration" && decl.constant) return evaluate(decl.value, bases, depth + 1);
      return null;
    }
    case "MemberAccess": {
      const decl = nodeById.get(expr.referencedDeclaration);
      if (decl?.nodeType === "VariableDeclaration" && decl.constant) return evaluate(decl.value, bases, depth + 1);
      return null;
    }
    case "TupleExpression":
      return expr.components?.length === 1 ? evaluate(expr.components[0], bases, depth + 1) : null;
    case "FunctionCall": {
      if (expr.kind === "typeConversion" && expr.arguments.length === 1) {
        const inner = evaluate(expr.arguments[0], bases, depth + 1);
        return inner && !("string" in inner) ? inner : null;
      }
      const callee = expr.expression;
      if (callee.nodeType === "Identifier" && callee.name === "erc7201" && callee.referencedDeclaration < 0) {
        const id = evaluate(expr.arguments[0], bases, depth + 1);
        return id && "string" in id ? { erc7201: id.string } : null;
      }
      const target = nodeById.get(callee.referencedDeclaration);
      if (expr.arguments.length === 0 && target?.nodeType === "FunctionDefinition") {
        const fn = mostDerived(target, bases);
        const statements = fn.body?.statements ?? [];
        if (statements.length === 1 && statements[0].nodeType === "Return") {
          return evaluate(statements[0].expression, bases, depth + 1);
        }
      }
      return null;
    }
    default:
      return null;
  }
}

/** The local variable declaration statement that declares `id` inside `fn`, if it has an initial value. */
function initialValueOf(fn, id) {
  let value = null;
  walk(fn.body, (n) => {
    if (n.nodeType === "VariableDeclarationStatement" && n.declarations?.length === 1 && n.declarations[0]?.id === id) {
      value = n.initialValue ?? null;
    }
  });
  return value;
}

/** Evaluates the right-hand side of `$.slot := <value>` (a Yul expression) inside function `fn`. */
function evaluateYul(value, assembly, fn, bases) {
  if (value.nodeType === "YulLiteral" && value.kind === "number") return { slot: `0x${BigInt(value.value).toString(16)}` };
  if (value.nodeType === "YulIdentifier") {
    const ref = assembly.externalReferences.find((r) => r.src === value.src);
    const decl = ref && nodeById.get(ref.declaration);
    if (decl?.nodeType === "VariableDeclaration") {
      if (decl.constant) return evaluate(decl.value, bases);
      const init = !decl.stateVariable && initialValueOf(fn, decl.id);
      if (init) return evaluate(init, bases);
    }
  }
  return null;
}

/** Source text of what a Yul value stands for (a local's initializer rather than the local's name). */
function describeYul(value, assembly, fn) {
  if (value.nodeType === "YulIdentifier") {
    const ref = assembly.externalReferences.find((r) => r.src === value.src);
    const decl = ref && nodeById.get(ref.declaration);
    const init = decl?.nodeType === "VariableDeclaration" && !decl.stateVariable && initialValueOf(fn, decl.id);
    if (init) return snippet(init.src);
  }
  return snippet(value.src);
}

// ------------------------------------------------------------------ 2c. reachable code, namespaces and accessors

/**
 * Everything that runs against the storage of `roots` (contract names): the members of each root's linearization,
 * plus every function or modifier that code references whose scope is a library, a free function, or one of those
 * contracts. Returns the annotated namespace structs it declares or reaches, with the accessors of each.
 */
function analyse(rootNames) {
  const contracts = new Map(); // id -> ContractDefinition, every base of every root
  const basesOf = new Map(); // function id -> linearization used to resolve virtual calls inside it
  const queue = [];
  const visited = new Set();
  const enqueue = (node, bases) => {
    if (!node || visited.has(node.id)) return;
    visited.add(node.id);
    basesOf.set(node.id, bases);
    queue.push(node);
  };
  for (const name of rootNames) {
    const root = contractNamed(name);
    const bases = root.linearizedBaseContracts.map((id) => nodeById.get(id));
    for (const base of bases) {
      contracts.set(base.id, base);
      for (const member of base.nodes ?? []) enqueue(member, bases);
    }
  }

  const structs = new Map(); // id -> annotated StructDefinition
  const unannotated = [];
  const accessors = new Map(); // struct id -> Map(function name -> location)
  while (queue.length > 0) {
    const node = queue.shift();
    const bases = basesOf.get(node.id);
    if (node.nodeType === "StructDefinition" && annotationOf(node)) structs.set(node.id, node);
    walk(node, (n) => {
      const refId = n.referencedDeclaration ?? n.pathNode?.referencedDeclaration;
      const target = typeof refId === "number" ? nodeById.get(refId) : undefined;
      if (target?.nodeType === "StructDefinition") enqueue(target, bases);
      if (target?.nodeType === "FunctionDefinition" || target?.nodeType === "ModifierDefinition") {
        const scope = nodeById.get(target.scope);
        const followable =
          scope?.nodeType === "SourceUnit" || scope?.contractKind === "library" || contracts.has(target.scope);
        if (followable) enqueue(target, scope?.contractKind === "library" ? [] : bases);
      }
      if (n.nodeType === "InlineAssembly" && node.nodeType === "FunctionDefinition") {
        walk(n.AST, (y) => {
          if (y.nodeType !== "YulAssignment") return;
          for (const name of y.variableNames) {
            const ref = n.externalReferences.find((r) => r.src === name.src && r.suffix === "slot");
            const pointer = ref && nodeById.get(ref.declaration);
            const structId = pointer?.typeName?.referencedDeclaration;
            const struct = structId !== undefined && nodeById.get(structId);
            if (struct?.nodeType !== "StructDefinition") continue;
            const value = evaluateYul(y.value, n, node, bases);
            const fn = `${scopeName(node)}.${node.name}`;
            if (annotationOf(struct)) {
              enqueue(struct, bases);
              if (!accessors.has(struct.id)) accessors.set(struct.id, new Map());
              accessors.get(struct.id).set(fn, value ?? { unresolved: describeYul(y.value, n, node) });
            } else if (value) {
              unannotated.push(`${fn} places struct ${struct.canonicalName} at a constant slot`);
            }
          }
        });
      }
    });
  }

  const namespaces = [...structs.values()].map((s) => ({
    id: annotationOf(s),
    struct: s.canonicalName,
    accessors: [...(accessors.get(s.id) ?? new Map()).entries()]
      .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))
      .map(([fn, location]) => ({ function: fn, location: stripStrings(location) })),
  }));
  return { namespaces, unannotated };
}

function stripStrings(location) {
  return "string" in location ? { unresolved: JSON.stringify(location.string) } : location;
}

// ------------------------------------------------------------------ normalization

const AST_ID_IN_TYPE = /(t_(?:struct|enum|contract|userDefinedValueType)\([^)]*\))\d+/g;

function normalizeLayout(layout, what) {
  const text = JSON.stringify(layout).replace(AST_ID_IN_TYPE, "$1");
  const out = JSON.parse(text);
  const before = Object.keys(layout.types ?? {}).length;
  const after = Object.keys(out.types ?? {}).length;
  if (before !== after) throw new Error(`${what}: two types collapse to one key once AST ids are removed`);
  const strip = (entries) => (entries ?? []).map(({ astId, ...rest }) => rest);
  const types = {};
  for (const key of Object.keys(out.types ?? {}).sort()) {
    const t = out.types[key];
    types[key] = t.members ? { ...t, members: strip(t.members) } : t;
  }
  return { storage: strip(out.storage), types };
}

function stable(value) {
  return `${JSON.stringify(value, null, 2)}\n`;
}

/**
 * Writes `value` to this run's output (which every check below reads, so a check always judges the code just
 * built) and compares it with the committed fixture of the same name: drift fails the gate, --write updates it.
 */
function syncFixture(relPath, value) {
  const text = stable(value);
  const fresh = join(FRESH, relPath);
  mkdirSync(dirname(fresh), { recursive: true });
  writeFileSync(fresh, text);
  const path = join(FIXTURES, relPath);
  if (WRITE) {
    mkdirSync(dirname(path), { recursive: true });
    writeFileSync(path, text);
  } else {
    const committed = existsSync(path) ? readFileSync(path, "utf8").replace(/\r\n/g, "\n") : null;
    if (committed !== text) fail(`fixture drift: ${relPath} (run \`node scripts/check-layouts.mjs --write\`)`);
  }
  return fresh;
}

// Code-point order, independent of the OS locale (fixtures are compared byte for byte across platforms).
const byCodePoint = (a, b) => (a < b ? -1 : a > b ? 1 : 0);

// ------------------------------------------------------------------ build every snapshot

const contracts = new Set();
for (const chain of config.chains) chain.versions.forEach((c) => contracts.add(c));
for (const p of [...config.mustFail, ...config.mustPass]) [p.old, p.new].forEach((c) => contracts.add(c));
const singles = new Map(config.singles.map((s) => [s.contract, s]));
for (const s of config.singles) contracts.add(s.contract);

console.log(`• forge inspect: ${config.probes.length} probes, ${contracts.size} contracts`);
const probeByStruct = new Map();
const probeLayouts = new Map();
await pool(config.probes, 4, async (probe) => {
  const layout = await forgeInspect(probe, "storageLayout");
  probeLayouts.set(probe, layout);
});
for (const probe of config.probes) {
  const layout = probeLayouts.get(probe);
  if (layout.storage.length !== 1) throw new Error(`${probe} must declare exactly one state variable`);
  const label = layout.types[layout.storage[0].type].label.replace(/^struct /, "");
  if (probeByStruct.has(label)) throw new Error(`${probe} and ${probeByStruct.get(label)} both probe ${label}`);
  probeByStruct.set(label, probe);
}

const snapshots = new Map();
let accessorCount = 0;
await pool([...contracts], 4, async (contract) => {
  const entry = singles.get(contract) ?? {};
  const roots = [contract, ...(entry.delegates ?? [])];
  const [layout, { namespaces, unannotated }] = await Promise.all([
    forgeInspect(contract, "storageLayout"),
    Promise.resolve(analyse(roots)),
  ]);
  for (const message of unannotated) {
    fail(`${contract}: ${message} without a @custom:storage-location annotation; the gate cannot check it`);
  }
  const ns = [];
  for (const { id, struct, accessors } of namespaces.sort((a, b) => byCodePoint(a.id, b.id) || byCodePoint(a.struct, b.struct))) {
    const probe = probeByStruct.get(struct);
    if (!probe) {
      fail(`${contract}: namespace ${id} (struct ${struct}) has no probe in test/layout`);
      continue;
    }
    accessorCount += accessors.length;
    const entry = { id, struct, probe };
    if (accessors.length > 0) entry.accessors = accessors;
    ns.push({ ...entry, layout: normalizeLayout(probeLayouts.get(probe), probe) });
  }
  snapshots.set(contract, { contract, ...normalizeLayout(layout, contract), namespaces: ns });
});
for (const contract of [...contracts].sort()) syncFixture(`snapshots/${contract}.json`, snapshots.get(contract));
console.log(`  ${accessorCount} namespace accessors resolved from the AST`);

// ------------------------------------------------------------------ 3. layout diffs

function layoutDiff(args) {
  const res = runSync(BIN, [...args, "--format", "json"]);
  if (res.status === 2) throw new Error(`layout-diff ${args.join(" ")}:\n${res.stderr}`);
  return { status: res.status, report: JSON.parse(res.stdout) };
}

const snap = (c) => join(FRESH, "snapshots", `${c}.json`);
const unallowedKinds = (report) =>
  [...new Set(report.findings.filter((f) => f.severity === "error" && !f.allowed).map((f) => f.kind))];

console.log("• upgrade chains (every consecutive pair must be safe)");
for (const chain of config.chains) {
  for (let i = 1; i < chain.versions.length; i++) {
    const [o, n] = [chain.versions[i - 1], chain.versions[i]];
    const allow = chain.allow.filter((a) => a.old === o && a.new === n).flatMap((a) => ["--allow", a.finding]);
    const { status, report } = layoutDiff(["diff", snap(o), snap(n), ...allow]);
    const line = `${o} -> ${n}: ${report.errors} errors, ${report.allowed} allowed, ${report.warnings} warnings, ${report.infos} infos`;
    if (status === 0) console.log(`  ok   ${line}`);
    else fail(`${line}; ${unallowedKinds(report).join(", ")}${report.unused_allowances.length ? `; unused allowances ${report.unused_allowances}` : ""}`);
  }
}

console.log("• single layouts (ERC-7201 slots, accessors and region overlaps)");
for (const s of config.singles) {
  const { status, report } = layoutDiff(["lint", snap(s.contract)]);
  if (status === 0) console.log(`  ok   ${s.name} (${s.contract}): ${snapshots.get(s.contract).namespaces.length} namespaces`);
  else fail(`${s.name}: ${unallowedKinds(report).join(", ")}`);
}

console.log("• unsafe pairs (the CLI must exit non-zero with the expected findings)");
for (const p of config.mustFail) {
  const { status, report } = layoutDiff(["diff", snap(p.old), snap(p.new)]);
  const kinds = unallowedKinds(report);
  const missing = p.expect.filter((k) => !kinds.includes(k));
  if (status === 1 && missing.length === 0) console.log(`  ok   ${p.name}: rejected with ${kinds.join(", ")}`);
  else fail(`${p.name}: exit ${status}, findings [${kinds}], missing [${missing}]`);
}

console.log("• safe controls");
for (const p of config.mustPass) {
  const { status, report } = layoutDiff(["diff", snap(p.old), snap(p.new)]);
  if (status === 0) console.log(`  ok   ${p.name}: ${report.infos} infos, ${report.warnings} warnings`);
  else fail(`${p.name}: expected safe, got ${unallowedKinds(report).join(", ")}`);
}

// ------------------------------------------------------------------ 4. selectors and API parity

/** The selectors each facet is cut with, read from the routing-table library's AST: facet name -> Set(selector). */
function routingTable(libraryName) {
  const table = new Map();
  walk(contractNamed(libraryName), (n) => {
    if (n.nodeType !== "MemberAccess" || n.memberName !== "selector") return;
    const fn = nodeById.get(n.expression?.referencedDeclaration);
    if (fn?.nodeType !== "FunctionDefinition" || !fn.functionSelector) return;
    const facet = scopeName(fn);
    if (!table.has(facet)) table.set(facet, new Set());
    table.get(facet).add(fn.functionSelector);
  });
  return table;
}

const routing = config.selectors.routing;
const table = routingTable(routing.table);
const methodIds = new Map();
const selectorContracts = new Set([
  routing.diamond,
  ...table.keys(),
  ...config.selectors.mustFail.flatMap((s) => s.sources),
  config.selectors.api.interface,
  ...config.selectors.api.uups,
]);
await pool([...selectorContracts], 4, async (c) => methodIds.set(c, await forgeInspect(c, "methodIdentifiers")));

function sortedObject(object) {
  return Object.fromEntries(Object.entries(object).sort(([a], [b]) => byCodePoint(a, b)));
}

function writeSelectorSet(name, sources) {
  return syncFixture(`selectors/${name}.json`, { sources });
}

console.log(`• diamond routing table (${routing.table}: what the deployment script and the tests cut)`);
const routedSources = [{ name: routing.diamond, selectors: sortedObject(methodIds.get(routing.diamond)) }];
for (const [facet, selectors] of [...table.entries()].sort(([a], [b]) => byCodePoint(a, b))) {
  const abi = methodIds.get(facet);
  const cut = Object.fromEntries(Object.entries(abi).filter(([, sel]) => selectors.has(sel)));
  const missing = [...selectors].filter((sel) => !Object.values(abi).includes(sel));
  if (missing.length > 0) fail(`${routing.table} routes ${missing.join(", ")} to ${facet}, which does not implement them`);
  const unrouted = Object.keys(abi).filter((sig) => !selectors.has(abi[sig]));
  if (unrouted.length > 0) console.log(`  note ${facet} functions not routed: ${unrouted.join(", ")}`);
  // The storage analysis of the diamond (section 2) follows the delegates listed in layouts.config.json; a facet that
  // is routed but not listed there would run against the diamond's storage without its namespaces being checked.
  if (!(singles.get(routing.diamond)?.delegates ?? []).includes(facet)) {
    fail(`${routing.table} routes to ${facet}, which is not a delegate of ${routing.diamond} in layouts.config.json, so its storage is unchecked`);
  }
  routedSources.push({ name: facet, selectors: sortedObject(cut) });
}
{
  const { status, report } = layoutDiff(["selectors", writeSelectorSet(routing.name, routedSources)]);
  const count = routedSources.reduce((n, s) => n + Object.keys(s.selectors).length, 0);
  if (status === 0) console.log(`  ok   ${routing.name}: ${count} routed selectors across ${routedSources.length} sources, no clash`);
  else fail(`${routing.name}: ${unallowedKinds(report).join(", ")}`);
}
for (const s of config.selectors.mustFail) {
  const sources = s.sources.map((c) => ({ name: c, selectors: sortedObject(methodIds.get(c)) }));
  const { status, report } = layoutDiff(["selectors", writeSelectorSet(s.name, sources)]);
  const kinds = unallowedKinds(report);
  const missing = s.expect.filter((k) => !kinds.includes(k));
  if (status === 1 && missing.length === 0) console.log(`  ok   ${s.name}: rejected with ${kinds.join(", ")}`);
  else fail(`${s.name}: exit ${status}, findings [${kinds}], missing [${missing}]`);
}

console.log(`• API parity (every ${config.selectors.api.interface} function is served by both architectures)`);
{
  const wanted = Object.keys(methodIds.get(config.selectors.api.interface));
  const servedBy = {
    "uups-v3": new Set(config.selectors.api.uups.flatMap((c) => Object.keys(methodIds.get(c)))),
    "diamond (routing table)": new Set(routedSources.flatMap((s) => Object.keys(s.selectors))),
  };
  for (const [name, served] of Object.entries(servedBy)) {
    const missing = wanted.filter((sig) => !served.has(sig));
    if (missing.length === 0) console.log(`  ok   ${name}: all ${wanted.length} functions`);
    else fail(`${name} does not serve ${missing.join(", ")}`);
  }
}

if (WRITE) console.log(`\nfixtures written to ${FIXTURES}`);
if (failures.length > 0) {
  console.log(`\n${failures.length} check(s) failed`);
  process.exit(1);
}
console.log("\nlayout gate: all checks passed");
