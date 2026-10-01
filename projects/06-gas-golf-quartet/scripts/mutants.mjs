#!/usr/bin/env node
// SPDX-License-Identifier: MIT
//
// Mutation smoke test: evidence that the evidence works. Each mutant injects one realistic golfing bug
// into the production code, runs the check that is supposed to catch it, and requires that check to
// FAIL FOR THE RIGHT REASON:
//   * halmos: a valid `Counterexample:` and a [FAIL] result (a timeout, a solver error or a
//     "potentially invalid" counterexample is not a catch);
//   * forge:  a failing test, `[FAIL: <reason>]`, that is not a setUp failure, not a Panic raised by the
//     test harness itself, and not a compilation error.
// Anything else is SURVIVED (the check passed) or ERROR (it failed for another reason); both make this
// script exit 1. Every source file is restored afterwards, including on Ctrl-C.
//
// Usage:
//   node scripts/mutants.mjs              run every mutant, then rewrite the README's mutants block
//   node scripts/mutants.mjs --check      run every mutant, then exit 1 if the README's block is stale (CI)
//   node scripts/mutants.mjs M1 M7        run a subset (the README is not touched)
//   node scripts/mutants.mjs --dry-run    only check that every mutant still applies to the sources
//   node scripts/mutants.mjs --list       print the mutants as JSON (read by scripts/gen-tables.mjs)
//
// Halmos runs as `halmos` (CI, Linux). On Windows it runs through scripts/halmos_nogc.py with the
// halmos uv tool's interpreter (see that file for why).

import { execFileSync, spawnSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const README = join(ROOT, "README.md");

// Both tools match these patterns against the full signature, e.g. `check_mulDiv(uint256,uint256,uint256)`,
// so `name\(` selects exactly one function. A pattern that selects nothing makes forge exit 0 (SURVIVED).
const halmos = (fn, contract) => ({
  tool: "halmos",
  contract,
  fn,
  args: ["--match-contract", `^${contract}$`, "--match-test", `^${fn}\\(`],
});
const forge = (contract, test) => ({
  tool: "forge",
  contract,
  fn: test,
  args: ["test", "--fuzz-seed", "1", "--match-contract", `^${contract}$`, ...(test ? ["--match-test", `^${test}\\(`] : [])],
});

const MUTANTS = [
  {
    id: "M1",
    what: "`mulDiv` overflow guard off by one (accepts `d ==` high word)",
    file: "src/math/FixedPointGolf.sol",
    from: "if iszero(gt(d, p1)) {",
    to: "if lt(d, p1) {",
    check: halmos("check_mulDiv", "MathEquivalence"),
  },
  {
    id: "M2",
    what: "`log2` without the `x \\| 1` zero guard",
    file: "src/math/FixedPointGolf.sol",
    from: "r = 255 - Clz.clz(x | 1);",
    to: "r = 255 - Clz.clz(x);",
    check: halmos("check_log2", "MathEquivalence"),
  },
  {
    id: "M3",
    what: "`mulDiv` with five Newton steps instead of six",
    file: "src/math/FixedPointGolf.sol",
    from: "                inv := mul(inv, sub(2, mul(d, inv)))\n                // [p1 z] / t",
    to: "                // [p1 z] / t",
    check: forge("MathKernelTest", "testFuzz_MulDiv"),
  },
  {
    id: "M4",
    what: "`sqrt` with five Newton steps instead of six",
    file: "src/math/FixedPointGolf.sol",
    from: "            z := shr(1, add(z, div(x, z)))\n            z := sub(z, lt(div(x, z), z))",
    to: "            z := sub(z, lt(div(x, z), z))",
    check: forge("MathKernelTest", "test_Sqrt_EveryBitLengthAndSquareBoundary"),
  },
  {
    id: "M5",
    what: "assembly `transfer` without the zero-receiver check",
    file: "src/assembly/QuartetAssembly.sol",
    from: "            if iszero(to) {\n                mstore(0x00, _INVALID_RECEIVER)\n                revert(0x1c, 0x04)\n            }\n            mstore(0x0c, _BALANCE_SLOT_SEED)\n            mstore(0x00, caller())",
    to: "            mstore(0x0c, _BALANCE_SLOT_SEED)\n            mstore(0x00, caller())",
    check: halmos("check_transfer", "ERC20Equivalence"),
  },
  {
    id: "M6",
    what: "assembly `permit` accepts the malleable high-`s` twin",
    file: "src/assembly/QuartetAssembly.sol",
    from: "if gt(s, _HALF_CURVE_ORDER) {",
    to: "if 0 {",
    check: forge("ERC20SpecAssemblyTest", "test_Permit_RevertWhen_SignatureIsMalleableHighS"),
  },
  {
    id: "M7",
    what: "Yul `approve` logs `Approval(spender, owner)`",
    file: "src/yul/QuartetYul.yul",
    from: "0x8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b925, caller(), spender)",
    to: "0x8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b925, spender, caller())",
    check: forge("LockstepInvariantTest"),
  },
  {
    id: "M8",
    what: "Yul `transferFrom` also decreases the infinite allowance",
    file: "src/yul/QuartetYul.yul",
    from: "                if not(allowed) {\n                    if gt(amount, allowed)",
    to: "                if 1 {\n                    if gt(amount, allowed)",
    check: halmos("check_transferFrom", "ERC20Equivalence"),
  },
  {
    id: "M9",
    what: "Vyper `transferFrom` checks the approver before the allowance",
    file: "src/vyper/QuartetVyper.vy",
    from: '        assert current >= amount, "erc20: insufficient allowance"\n        assert owner != empty(address), "erc20: invalid approver"',
    to: '        assert owner != empty(address), "erc20: invalid approver"\n        assert current >= amount, "erc20: insufficient allowance"',
    check: forge("LockstepInvariantTest"),
  },
  {
    id: "M10",
    what: "assembly nonce slots share the balance seed (storage collision)",
    file: "src/assembly/QuartetAssembly.sol",
    from: "uint256 private constant _NONCES_SLOT_SEED = 0x38377508;",
    to: "uint256 private constant _NONCES_SLOT_SEED = 0x87a211a2;",
    check: forge("LockstepInvariantTest"),
  },
  {
    id: "M11",
    what: "Yul `transferFrom` validates `from` only (a dirty `to` becomes a storage slot)",
    file: "src/yul/QuartetYul.yul",
    from: "if or(lt(calldatasize(), 0x64), shr(160, or(from, to))) { revert(0, 0) }",
    to: "if or(lt(calldatasize(), 0x64), shr(160, from)) { revert(0, 0) }",
    check: forge("ERC20SpecYulTest", "test_RevertWhen_AnyAddressWordHasDirtyUpperBits"),
  },
  {
    id: "M12",
    what: "Yul `allowance` validates `owner` only",
    file: "src/yul/QuartetYul.yul",
    from: "if or(lt(calldatasize(), 0x44), shr(160, or(owner, spender))) { revert(0, 0) }",
    to: "if or(lt(calldatasize(), 0x44), shr(160, owner)) { revert(0, 0) }",
    check: halmos("check_dirtyWordsAreRejected", "ERC20Equivalence"),
  },
  {
    id: "M13",
    what: "Yul `permit` validates `owner` only, not `spender`",
    file: "src/yul/QuartetYul.yul",
    from: "or(shr(160, or(owner, spender)), shr(8, v))",
    to: "or(shr(160, owner), shr(8, v))",
    check: forge("LockstepScriptedTest", "test_LockstepRejectsEachDirtyStrictWord"),
  },
  {
    id: "M14",
    what: "assembly `permit` drops `signer != 0` (zero owner + unrecoverable signature passes)",
    file: "src/assembly/QuartetAssembly.sol",
    from: "if iszero(mul(signer, eq(signer, owner))) {",
    to: "if iszero(eq(signer, owner)) {",
    check: forge("ERC20SpecAssemblyTest", "test_Permit_RevertWhen_OwnerIsZero"),
  },
];

const FLAGS = new Set(["--dry-run", "--list", "--check"]);
const args = process.argv.slice(2);
const DRY_RUN = args.includes("--dry-run");
const CHECK = args.includes("--check");
const selected = args.filter((a) => !FLAGS.has(a));

if (args.includes("--list")) {
  console.log(JSON.stringify(MUTANTS.map(({ id, what, file, check }) => ({ id, what, file, tool: check.tool, check: check.fn ?? check.contract }))));
  process.exit(0);
}

const mutants = selected.length ? MUTANTS.filter((m) => selected.includes(m.id)) : MUTANTS;
if (mutants.length === 0 || mutants.length !== (selected.length || MUTANTS.length)) {
  console.error(`mutants: unknown selection ${selected.join(" ")} (known: ${MUTANTS.map((m) => m.id).join(", ")})`);
  process.exit(1);
}
const ALL = mutants.length === MUTANTS.length;
if (CHECK && !ALL) {
  console.error("mutants: --check needs the full set (it compares the README block)");
  process.exit(1);
}

// Every pattern must match exactly once before anything is mutated, so a stale pattern fails fast.
for (const m of mutants) {
  const source = readFileSync(join(ROOT, m.file), "utf8").replace(/\r\n/g, "\n");
  const hits = source.split(m.from).length - 1;
  if (hits !== 1) {
    console.error(`mutants: ${m.id} expects exactly one match in ${m.file}, found ${hits}`);
    process.exit(1);
  }
}
if (DRY_RUN) {
  console.log(`mutants: all ${mutants.length} patterns match exactly once (dry run)`);
  process.exit(0);
}

function halmosCommand() {
  if (process.platform !== "win32") return ["halmos", []];
  const toolDir = execFileSync("uv", ["tool", "dir"], { encoding: "utf8" }).trim();
  return [join(toolDir, "halmos", "Scripts", "python.exe"), [join(ROOT, "scripts", "halmos_nogc.py")]];
}

function buildYul() {
  execFileSync(process.execPath, [join(ROOT, "scripts", "build-yul.mjs")], { cwd: ROOT, stdio: "ignore" });
}

// Restore every touched file on any exit path.
const originals = new Map();
function restoreAll() {
  for (const [file, content] of originals) writeFileSync(join(ROOT, file), content);
  if ([...originals.keys()].some((f) => f.endsWith(".yul"))) buildYul();
  originals.clear();
}
for (const signal of ["SIGINT", "SIGTERM"]) {
  process.on(signal, () => {
    restoreAll();
    process.exit(130);
  });
}

/// Decides caught / SURVIVED / ERROR from the exit status and the output, never from the status alone.
function verdict(tool, run, output) {
  if (run.error || run.status === null) return { outcome: "ERROR", evidence: `did not run: ${run.error?.message ?? run.signal}` };
  if (run.status === 0) return { outcome: "SURVIVED", evidence: "the check passed" };
  if (tool === "halmos") {
    if (/\[FAIL\]/.test(output) && /Counterexample: /.test(output)) return { outcome: "caught", evidence: "counterexample" };
    if (/\[TIMEOUT\]/.test(output)) return { outcome: "ERROR", evidence: "solver timeout, not a counterexample" };
    if (/potentially invalid/.test(output)) return { outcome: "ERROR", evidence: "only a potentially invalid counterexample" };
    return { outcome: "ERROR", evidence: `halmos exited ${run.status} without a counterexample` };
  }
  if (/Compiler run failed|Error \(\d+\):/.test(output)) return { outcome: "ERROR", evidence: "compilation error" };
  const failures = [...output.matchAll(/\[FAIL: ([^\]\n]*)\]/g)].map((x) => x[1]);
  if (failures.length === 0) return { outcome: "ERROR", evidence: `forge exited ${run.status} without a failing test` };
  if (failures.some((f) => /setup failed/i.test(f))) return { outcome: "ERROR", evidence: "setUp failed" };
  if (failures.every((f) => /^panic:/i.test(f))) return { outcome: "ERROR", evidence: "the test harness panicked" };
  return { outcome: "caught", evidence: "failing test" };
}

const results = [];
try {
  for (const m of mutants) {
    const path = join(ROOT, m.file);
    const original = readFileSync(path, "utf8");
    const normalized = original.replace(/\r\n/g, "\n");
    const hits = normalized.split(m.from).length - 1;
    if (hits !== 1) throw new Error(`${m.id}: expected exactly one match in ${m.file}, found ${hits}`);
    originals.set(m.file, original);
    writeFileSync(path, normalized.replace(m.from, m.to));
    if (m.file.endsWith(".yul")) buildYul();

    const started = Date.now();
    const [cmd, prefix] = m.check.tool === "halmos" ? halmosCommand() : ["forge", []];
    const env = { ...process.env, PYTHONUTF8: "1", NO_COLOR: "1" };
    if (m.check.tool === "halmos") env.FOUNDRY_PROFILE = "halmos";
    else delete env.FOUNDRY_PROFILE;
    const run = spawnSync(cmd, [...prefix, ...m.check.args], {
      cwd: ROOT,
      env,
      encoding: "utf8",
      shell: false,
      maxBuffer: 256 * 1024 * 1024,
    });
    // biome-ignore lint/suspicious/noControlCharactersInRegex: strips ANSI colour codes.
    const output = `${run.stdout ?? ""}\n${run.stderr ?? ""}`.replace(/\u001b\[[0-9;]*m/g, "");
    const seconds = Math.round((Date.now() - started) / 1000);
    const { outcome, evidence } = verdict(m.check.tool, run, output);
    results.push({ ...m, outcome, evidence, seconds });
    console.log(`${m.id} ${outcome} by ${m.check.tool} (${evidence}, ${seconds}s): ${m.what}`);
    if (outcome !== "caught") console.log(output.split("\n").slice(-40).join("\n"));
    restoreAll();
  }
} finally {
  restoreAll();
}

function checkedBy(check) {
  if (check.tool === "halmos") return `halmos \`${check.fn}\``;
  return `forge \`${check.contract}${check.fn ? `.${check.fn}` : ""}\``;
}

const block = [
  "| Mutant | Injected bug | Checked by | Result |",
  "|---|---|---|---|",
  ...results.map((r) => `| ${r.id} | ${r.what} | ${checkedBy(r.check)} | ${r.outcome === "caught" ? `caught (${r.evidence})` : `**${r.outcome}** (${r.evidence})`} |`),
].join("\n");
console.log(`\n${block}`);

const failed = results.filter((r) => r.outcome !== "caught");
let stale = false;
if (ALL) {
  const begin = "<!-- gen:mutants:begin -->";
  const end = "<!-- gen:mutants:end -->";
  const readme = readFileSync(README, "utf8").replace(/\r\n/g, "\n");
  const i = readme.indexOf(begin);
  const j = readme.indexOf(end);
  if (i < 0 || j < i) {
    console.error("mutants: README.md has no gen:mutants block");
    process.exit(1);
  }
  const updated = `${readme.slice(0, i + begin.length)}\n${block}\n${readme.slice(j)}`;
  if (updated !== readme) {
    if (CHECK) {
      console.error("mutants: README.md's mutants block is stale; run `node scripts/mutants.mjs`");
      stale = true;
    } else if (failed.length === 0) {
      writeFileSync(README, updated);
      console.log("mutants: updated README.md");
    }
  }
}
if (failed.length) {
  console.error(`\nmutants: ${failed.length} mutant(s) not caught: ${failed.map((r) => `${r.id} (${r.outcome})`).join(", ")}`);
  process.exit(1);
}
if (stale) process.exit(1);
console.log(`\nmutants: all ${results.length} mutants caught`);
