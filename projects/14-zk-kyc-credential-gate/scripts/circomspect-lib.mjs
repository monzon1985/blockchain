// SPDX-License-Identifier: MIT
//
// Fail-closed wrapper around circomspect plus the machine-readable triage
// file (circuits/circomspect-triage.json). Imported by lint-circuits.mjs and
// unit-tested by test/lint.test.ts.
import { spawnSync } from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";

/**
 * Load and validate the triage file. Each suppression must name the rule
 * (CSxxxx), the file (path suffix, forward slashes), a `match` substring that
 * must appear on the flagged source line, and a real justification. Anything
 * malformed throws, so a typo can never silently widen a suppression.
 *
 * @param {string} file
 * @returns {{ruleId: string, file: string, match: string, justification: string}[]}
 */
export function loadTriage(file) {
  if (!fs.existsSync(file)) throw new Error(`triage file not found: ${file}`);
  const doc = JSON.parse(fs.readFileSync(file, "utf8"));
  if (!doc || !Array.isArray(doc.suppressions)) {
    throw new Error(`${path.basename(file)}: expected an object with a "suppressions" array`);
  }
  return doc.suppressions.map((s, i) => {
    const where = `${path.basename(file)} suppressions[${i}]`;
    if (typeof s.ruleId !== "string" || !/^CS\d{4}$/.test(s.ruleId)) throw new Error(`${where}: bad ruleId`);
    if (typeof s.file !== "string" || s.file.length === 0 || s.file.includes("\\")) {
      throw new Error(`${where}: "file" must be a forward-slash path suffix`);
    }
    if (typeof s.match !== "string" || s.match.trim().length === 0) {
      throw new Error(`${where}: "match" must name the flagged code on that line`);
    }
    if (typeof s.justification !== "string" || s.justification.trim().length < 40) {
      throw new Error(`${where}: a justification of at least 40 characters is required`);
    }
    return { ruleId: s.ruleId, file: s.file, match: s.match, justification: s.justification };
  });
}

/** Normalise a SARIF artifact URI (file://\\?\C:\... or file:///...) to a forward-slash path. */
export function normaliseUri(uri) {
  return uri
    .replace(/^file:\/\//, "")
    .replace(/^\\\\\?\\/, "")
    .replace(/\\/g, "/")
    .replace(/^\/([A-Za-z]:)/, "$1");
}

/**
 * Whether `finding` is covered by a suppression: same rule, file suffix, and
 * the suppression's `match` text appears on the flagged source line.
 */
export function suppressionFor(triage, finding, readLine = defaultReadLine) {
  return triage.find(
    (t) =>
      t.ruleId === finding.ruleId &&
      finding.file.endsWith(t.file) &&
      (readLine(finding.file, finding.line) ?? "").includes(t.match),
  );
}

function defaultReadLine(file, line) {
  try {
    return fs.readFileSync(file, "utf8").split(/\r?\n/)[line - 1];
  } catch {
    return undefined;
  }
}

/**
 * Run circomspect on one entrypoint and return its findings. FAILS CLOSED:
 * throws if the entrypoint is missing (circomspect itself reports "No issues
 * found" for a nonexistent file), if the binary is missing or killed, if it
 * exits with anything other than 0 (clean) / 1 (issues found), or if it did
 * not write its SARIF report.
 *
 * @returns {{ruleId: string, level: string, file: string, line: number, message: string}[]}
 */
export function runCircomspect(entry, { includeDir, sarifPath, binary = "circomspect" }) {
  if (!fs.existsSync(entry)) throw new Error(`circuit entrypoint not found: ${entry}`);
  fs.mkdirSync(path.dirname(sarifPath), { recursive: true });
  fs.rmSync(sarifPath, { force: true });
  const res = spawnSync(binary, [entry, "-L", includeDir, "-l", "WARNING", "-s", sarifPath], {
    encoding: "utf8",
  });
  if (res.error) {
    const code = /** @type {NodeJS.ErrnoException} */ (res.error).code;
    throw new Error(
      code === "ENOENT"
        ? `${binary} is not installed or not on PATH (cargo install circomspect --version 0.9.0 --locked)`
        : `failed to run ${binary}: ${res.error.message}`,
    );
  }
  if (res.signal) throw new Error(`${binary} was killed by ${res.signal}`);
  if (res.status !== 0 && res.status !== 1) {
    throw new Error(`${binary} exited with status ${res.status}:\n${res.stderr || res.stdout}`);
  }
  if (!fs.existsSync(sarifPath)) {
    throw new Error(`${binary} exited ${res.status} without writing ${sarifPath}:\n${res.stderr || res.stdout}`);
  }
  const sarif = JSON.parse(fs.readFileSync(sarifPath, "utf8"));
  const results = sarif.runs?.[0]?.results;
  if (!Array.isArray(results)) throw new Error(`malformed SARIF from ${binary}: ${sarifPath}`);
  if (res.status === 1 && results.length === 0) {
    throw new Error(`${binary} reported failure but its SARIF lists no results`);
  }
  return results.map((r) => ({
    ruleId: r.ruleId ?? "(none)",
    level: r.level ?? "warning",
    file: normaliseUri(r.locations?.[0]?.physicalLocation?.artifactLocation?.uri ?? ""),
    line: r.locations?.[0]?.physicalLocation?.region?.startLine ?? 0,
    message: r.message?.text ?? "",
  }));
}
