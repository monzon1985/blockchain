// SPDX-License-Identifier: MIT
/**
 * Mutation spot-check: injects realistic bugs into the production contracts, one at a time, and requires the test
 * suite to fail on every one of them. A surviving mutant means a bug class the tests do not detect.
 *
 *   npm run mutation              # every mutant
 *   npm run mutation -- M05 M12   # selected mutants
 *
 * Each mutant replaces one exact source fragment (which must occur exactly once). The original file is backed up under
 * `cache/mutation-backup/` before it is touched and restored afterwards, also on Ctrl+C; a backup left behind by a
 * killed run is restored on the next start. A mutant that does not compile is reported as invalid and fails the run.
 *
 * A mutant can also name a `guard`: one test file that must catch it on its own, because the README cites that file as
 * the protection against this bug class. This keeps such a claim honest even when other suites also kill the mutant
 * (for example, M08 must fail the invariant suite, not only the unit tests, or INV-5 would be vacuous).
 *
 * Every command runs exactly as in the baseline: the Solidity suites with the `mutation` test profile (the default
 * profile plus a finite per-call gas limit), then the node:test suites.
 */
import { spawnSync } from "node:child_process";
import { closeSync, existsSync, mkdirSync, openSync, readFileSync } from "node:fs";
import { copyFile, mkdir, readFile, readdir, rm, writeFile } from "node:fs/promises";
import path from "node:path";

interface Mutant {
  id: string;
  file: string;
  bug: string;
  find: string;
  replace: string;
  /** Test file (`.sol` or `.ts`) that must fail on this mutant when run alone. */
  guard?: string;
}

const ROOT = path.join(import.meta.dirname, "..");
const BACKUP_DIR = path.join(ROOT, "cache", "mutation-backup");

const MUTANTS: Mutant[] = [
  {
    id: "M01",
    file: "contracts/libraries/StreamMath.sol",
    bug: "linear curve ignores the cliff",
    find: "if (t < start || t < cliff) return 0;",
    replace: "if (t < start) return 0;",
  },
  {
    id: "M02",
    file: "contracts/libraries/StreamMath.sol",
    bug: "linear curve rounds up, in the recipient's favour",
    find: "vested = uint128((uint256(deposit) * (t - start)) / (end - start));",
    replace: "vested = uint128((uint256(deposit) * (t - start) + (end - start) - 1) / (end - start));",
  },
  {
    id: "M03",
    file: "contracts/libraries/StreamMath.sol",
    bug: "a tranche unlocks one second late (off-by-one)",
    find: "if (tranches[i].timestamp > t) break;",
    replace: "if (tranches[i].timestamp >= t) break;",
  },
  {
    id: "M04",
    file: "contracts/libraries/StreamMath.sol",
    bug: "every segment interpolates from the stream start instead of the previous milestone",
    find: "                previous = segment.timestamp;\n",
    replace: "",
  },
  {
    id: "M05",
    file: "contracts/VestingStreams.sol",
    bug: "cancel does not freeze the streamed amount",
    find: "        stream.canceled = true;\n",
    replace: "",
  },
  {
    id: "M06",
    file: "contracts/VestingStreams.sol",
    bug: "withdraw skips the owner/operator authorization",
    find: "function withdraw(uint256 streamId, address to, uint128 amount) external override nonReentrant {\n        Stream storage stream = _authorizeWithdrawal(streamId, to);",
    replace:
      "function withdraw(uint256 streamId, address to, uint128 amount) external override nonReentrant {\n        Stream storage stream = _requireStream(streamId);",
  },
  {
    id: "M07",
    file: "contracts/VestingStreams.sol",
    bug: "withdraw allows one base unit more than withdrawable",
    find: "if (amount > withdrawable) revert",
    replace: "if (amount > withdrawable + 1) revert",
  },
  {
    id: "M08",
    file: "contracts/VestingStreams.sol",
    bug: "deposit check only rejects an empty transfer, so short deliveries are accepted",
    find: "if (received != amount) revert",
    replace: "if (received == 0) revert",
    // INV-5 is documented as rejecting fee-on-transfer and share-rounding tokens: the stateful suite alone must see it.
    guard: "test/solidity/invariant/VestingInvariants.t.sol",
  },
  {
    id: "M09",
    file: "contracts/VestingStreams.sol",
    bug: "createBatch pulls only the last stream's deposit (accumulator bug)",
    find: "total += _validate(params[i]);",
    replace: "total = _validate(params[i]);",
  },
  {
    id: "M10",
    file: "contracts/VestingStreams.sol",
    bug: "withdrawMax has no re-entrancy guard",
    find: "function withdrawMax(uint256 streamId, address to) external override nonReentrant returns",
    replace: "function withdrawMax(uint256 streamId, address to) external override returns",
  },
  {
    id: "M11",
    file: "contracts/VestingStreams.sol",
    bug: "cancel does not reserve gas for the hook (the sender can starve it)",
    find: "        if (gasleft() < gasRequired) revert InsufficientGasForHook(gasleft(), gasRequired);\n",
    replace: "",
  },
  {
    id: "M12",
    file: "contracts/VestingStreams.sol",
    bug: "the hook gets all remaining gas instead of a fixed stipend",
    find: "onStreamCanceled{gas: RECIPIENT_HOOK_GAS}(",
    replace: "onStreamCanceled(",
  },
  {
    id: "M13",
    file: "contracts/VestingStreams.sol",
    bug: "a fully vested stream can still be canceled",
    find: "        if (streamed == depositAmount) revert StreamSettled(streamId);\n",
    replace: "",
  },
  {
    id: "M14",
    file: "contracts/VestingStreams.sol",
    bug: "anyone can renounce a stream's cancelability",
    find: "function renounceCancelability(uint256 streamId) external override nonReentrant {\n        Stream storage stream = _requireStream(streamId);\n        if (msg.sender != stream.sender) revert NotStreamSender(streamId, msg.sender);\n",
    replace:
      "function renounceCancelability(uint256 streamId) external override nonReentrant {\n        Stream storage stream = _requireStream(streamId);\n",
  },
  {
    id: "M15",
    file: "contracts/VestingStreams.sol",
    bug: "a stream NFT can be sent to the vesting contract and frozen there",
    find: "        if (to == address(this)) revert InvalidRecipient(to);\n",
    replace: "",
  },
  {
    id: "M16",
    file: "contracts/VestingStreams.sol",
    bug: "statusOf reports a drained canceled stream as Canceled instead of Depleted",
    find: "        if (stream.withdrawnAmount + stream.refundedAmount == depositAmount) return Status.Depleted;\n        if (stream.canceled) return Status.Canceled;\n",
    replace:
      "        if (stream.canceled) return Status.Canceled;\n        if (stream.withdrawnAmount + stream.refundedAmount == depositAmount) return Status.Depleted;\n",
  },
  {
    id: "M17",
    file: "contracts/libraries/MilestoneCodec.sol",
    bug: "milestone timestamps are packed at the wrong bit offset",
    find: "(uint256(milestones[i].timestamp) << 88)",
    replace: "(uint256(milestones[i].timestamp) << 80)",
  },
  {
    id: "M18",
    file: "contracts/StreamRenderer.sol",
    bug: "the symbol is written into the SVG without XML escaping",
    find: "bytes(LibString.escapeHTML(symbol)),",
    replace: "bytes(symbol),",
  },
  {
    id: "M19",
    file: "contracts/StreamRenderer.sol",
    bug: "the symbol is written into the JSON without JSON escaping",
    find: "string memory symbol = SafeText.json(card.rawSymbol);",
    replace: "string memory symbol = SafeText.sanitize(card.rawSymbol);",
  },
  {
    id: "M20",
    file: "contracts/libraries/SafeText.sol",
    bug: "the sanitizer lets control characters through",
    find: "(c >= 0x20 && c <= 0x7e)",
    replace: "(c >= 0x01 && c <= 0x7e)",
  },
  {
    id: "M21",
    file: "contracts/libraries/DecimalFormat.sol",
    bug: "displayed amounts round up instead of truncating",
    find: "fraction = remainder / 10 ** (decimals - FRACTION_DIGITS);",
    replace: "fraction = (remainder + 10 ** (decimals - FRACTION_DIGITS) - 1) / 10 ** (decimals - FRACTION_DIGITS);",
  },
  {
    id: "M22",
    file: "contracts/StreamRenderer.sol",
    bug: "amounts are written into the SVG without XML escaping (dust renders as `<0.0001`)",
    find: "bytes(LibString.escapeHTML(amount)),",
    replace: "bytes(amount),",
  },
  // Dropping only the 64/63 factor (keeping HOOK_CALL_OVERHEAD) is not listed: with the current constants it is an
  // equivalent mutant. The 5,000 gas overhead covers the 1,587 gas the factor adds plus the few hundred gas the call
  // setup costs, so the hook still receives its full stipend, which is what the boundary test in Cancel.t.sol checks.
  {
    id: "M23",
    file: "contracts/VestingStreams.sol",
    bug: "the hook gas reservation ignores the 63/64 rule and the call overhead",
    find: "uint256 gasRequired = (RECIPIENT_HOOK_GAS * 64) / 63 + HOOK_CALL_OVERHEAD;",
    replace: "uint256 gasRequired = RECIPIENT_HOOK_GAS;",
  },
  {
    id: "M24",
    file: "contracts/VestingStreams.sol",
    bug: "no gas is reserved for the hook call itself (HOOK_CALL_OVERHEAD = 0)",
    find: "uint256 internal constant HOOK_CALL_OVERHEAD = 5000;",
    replace: "uint256 internal constant HOOK_CALL_OVERHEAD = 0;",
  },
];

/** Hardhat's CLI entry point, run directly with this Node binary so a timeout kills the real process (no shell). */
const HARDHAT_CLI = path.join(ROOT, "node_modules", "hardhat", "dist", "src", "cli.js");

/**
 * Upper bound for one Hardhat invocation. The unmutated suite takes well under a minute; a mutant that makes it hang
 * (for example M12, where the gas-guzzling hook receives all remaining gas and loops until it runs out) must still
 * end the campaign. A run that hits the bound counts as failing, i.e. the mutant is detected.
 */
const COMMAND_TIMEOUT_MS = 10 * 60 * 1000;

/** Output of the current Hardhat invocation. A file, not a pipe: a lingering child cannot keep spawnSync waiting. */
const RUN_LOG = path.join(ROOT, "cache", "mutation-run.log");

/** Runs `hardhat <args>` in the project root; returns whether it passed, whether it timed out, and its output tail. */
function run(args: string[]): { ok: boolean; timedOut: boolean; tail: string } {
  mkdirSync(path.dirname(RUN_LOG), { recursive: true });
  const fd = openSync(RUN_LOG, "w");
  let result: ReturnType<typeof spawnSync>;
  try {
    result = spawnSync(process.execPath, [HARDHAT_CLI, ...args], {
      cwd: ROOT,
      stdio: ["ignore", fd, fd],
      timeout: COMMAND_TIMEOUT_MS,
      killSignal: "SIGKILL",
    });
  } finally {
    closeSync(fd);
  }
  const timedOut = result.error !== undefined && (result.error as NodeJS.ErrnoException).code === "ETIMEDOUT";
  const output = readFileSync(RUN_LOG, "utf8");
  return { ok: result.status === 0, timedOut, tail: output.split(/\r?\n/).slice(-15).join("\n") };
}

async function restoreBackups(): Promise<string[]> {
  if (!existsSync(BACKUP_DIR)) return [];
  const restored: string[] = [];
  for (const entry of await readdir(BACKUP_DIR, { recursive: true, withFileTypes: true })) {
    if (!entry.isFile()) continue;
    const backup = path.join(entry.parentPath, entry.name);
    const relative = path.relative(BACKUP_DIR, backup);
    await copyFile(backup, path.join(ROOT, relative));
    restored.push(relative);
  }
  await rm(BACKUP_DIR, { recursive: true, force: true });
  return restored;
}

const leftovers = await restoreBackups();
if (leftovers.length > 0) {
  console.error(`Restored ${leftovers.join(", ")} from an interrupted run. Re-run to start the campaign.`);
  process.exit(1);
}

const selected = process.argv.slice(2);
const mutants = selected.length === 0 ? MUTANTS : MUTANTS.filter((m) => selected.includes(m.id));
if (mutants.length === 0) throw new Error(`no mutant matches ${selected.join(" ")}`);

// Validate every mutant against the pristine sources before touching anything.
for (const m of mutants) {
  const source = await readFile(path.join(ROOT, m.file), "utf8");
  const occurrences = source.split(m.find).length - 1;
  if (occurrences !== 1) throw new Error(`${m.id}: fragment found ${occurrences} times in ${m.file}`);
}

/** The Solidity suites (or one test file of them) with the mutation profile. */
const solidity = (...files: string[]) => run(["test", "solidity", ...files, "--test-profile", "mutation"]);
/** The node:test suites (or one test file of them). */
const nodejs = (...files: string[]) => run(["test", "nodejs", ...files]);

console.log("Baseline: the unmutated sources must build and pass every suite, with the same commands as the mutants.");
for (const [label, command] of [
  ["build", () => run(["build"])],
  ["test solidity --test-profile mutation", () => solidity()],
  ["test nodejs", () => nodejs()],
] as const) {
  const result = command();
  if (!result.ok) {
    console.error(`baseline \`hardhat ${label}\` ${result.timedOut ? "timed out" : "failed"}:\n${result.tail}`);
    process.exit(1);
  }
}

process.on("SIGINT", () => {
  void restoreBackups().then(() => process.exit(130));
});

const results: { mutant: Mutant; outcome: "killed" | "survived" | "invalid"; by: string }[] = [];
for (const m of mutants) {
  const target = path.join(ROOT, m.file);
  const backup = path.join(BACKUP_DIR, m.file);
  const original = await readFile(target, "utf8");
  await mkdir(path.dirname(backup), { recursive: true });
  await copyFile(target, backup);
  try {
    await writeFile(
      target,
      original.replace(m.find, () => m.replace),
    );
    let outcome: "killed" | "survived" | "invalid" = "survived";
    let by = "-";
    if (!run(["build"]).ok) {
      outcome = "invalid";
      by = "does not compile";
    } else if (m.guard !== undefined) {
      // The named suite alone must fail; otherwise the claim that it guards this bug class is false.
      const guard = m.guard.endsWith(".sol") ? solidity(m.guard) : nodejs(m.guard);
      if (!guard.ok) {
        outcome = "killed";
        by = `${path.basename(m.guard)}${guard.timedOut ? " (timeout)" : ""}`;
      } else {
        by = `${path.basename(m.guard)} passed`;
      }
    } else {
      const sol = solidity();
      if (!sol.ok) {
        outcome = "killed";
        by = sol.timedOut ? "Solidity (timeout)" : "Solidity tests";
      } else {
        const js = nodejs();
        if (!js.ok) {
          outcome = "killed";
          by = js.timedOut ? "node:test (timeout)" : "node:test suite";
        }
      }
    }
    results.push({ mutant: m, outcome, by });
    console.log(`${m.id} ${outcome.toUpperCase().padEnd(8)} ${by.padEnd(26)} ${m.file}: ${m.bug}`);
  } finally {
    await writeFile(target, original);
    await rm(BACKUP_DIR, { recursive: true, force: true });
  }
}

// Leave fresh artifacts of the pristine sources behind.
run(["build"]);

const killed = results.filter((r) => r.outcome === "killed").length;
console.log(`\n${killed}/${results.length} mutants killed`);
if (killed !== results.length) {
  for (const r of results.filter((x) => x.outcome !== "killed")) {
    console.error(`${r.mutant.id} ${r.outcome}: ${r.mutant.bug}`);
  }
  process.exitCode = 1;
}
