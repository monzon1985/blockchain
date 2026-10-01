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
 */
import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { copyFile, mkdir, readFile, readdir, rm, writeFile } from "node:fs/promises";
import path from "node:path";

interface Mutant {
  id: string;
  file: string;
  bug: string;
  find: string;
  replace: string;
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
];

/** Runs a command in the project root; returns its exit status and the tail of its output. */
function run(command: string): { ok: boolean; tail: string } {
  const result = spawnSync(command, { cwd: ROOT, shell: true, encoding: "utf8", maxBuffer: 256 * 1024 * 1024 });
  const output = `${result.stdout}${result.stderr}`;
  return { ok: result.status === 0, tail: output.split(/\r?\n/).slice(-15).join("\n") };
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

console.log("Baseline: the unmutated suite must pass.");
for (const command of ["npx hardhat build", "npx hardhat test"]) {
  const result = run(command);
  if (!result.ok) {
    console.error(`baseline \`${command}\` failed:\n${result.tail}`);
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
    if (!run("npx hardhat build").ok) {
      outcome = "invalid";
      by = "does not compile";
    } else if (!run("npx hardhat test solidity").ok) {
      outcome = "killed";
      by = "Solidity tests";
    } else if (!run("npx hardhat test nodejs").ok) {
      outcome = "killed";
      by = "node:test suite";
    }
    results.push({ mutant: m, outcome, by });
    console.log(`${m.id} ${outcome.toUpperCase().padEnd(8)} ${by.padEnd(17)} ${m.file}: ${m.bug}`);
  } finally {
    await writeFile(target, original);
    await rm(BACKUP_DIR, { recursive: true, force: true });
  }
}

// Leave fresh artifacts of the pristine sources behind.
run("npx hardhat build");

const killed = results.filter((r) => r.outcome === "killed").length;
console.log(`\n${killed}/${results.length} mutants killed`);
if (killed !== results.length) {
  for (const r of results.filter((x) => x.outcome !== "killed")) {
    console.error(`${r.mutant.id} ${r.outcome}: ${r.mutant.bug}`);
  }
  process.exitCode = 1;
}
