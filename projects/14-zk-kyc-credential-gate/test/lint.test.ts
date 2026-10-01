// SPDX-License-Identifier: MIT
//
// Unit tests for the circomspect gate's triage loader and fail-closed runner.
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { loadTriage, normaliseUri, runCircomspect, suppressionFor } from "../scripts/circomspect-lib.mjs";
import { PROJECT_ROOT } from "../src/lib/artifacts.ts";

const TRIAGE = path.join(PROJECT_ROOT, "circuits", "circomspect-triage.json");

function tmpJson(data: unknown): string {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "triage-"));
  const file = path.join(dir, "t.json");
  fs.writeFileSync(file, JSON.stringify(data));
  return file;
}

describe("circomspect gate", () => {
  it("loads exactly the one documented suppression from the committed triage file", () => {
    const t = loadTriage(TRIAGE);
    assert.equal(t.length, 1);
    assert.equal(t[0]?.ruleId, "CS0017");
    assert.equal(t[0]?.match, "signal recipientSquare");
  });

  it("does not parse suppressions out of CIRCOMSPECT.md (docs are never an active triage source)", () => {
    const md = fs.readFileSync(path.join(PROJECT_ROOT, "circuits", "CIRCOMSPECT.md"), "utf8");
    assert.doesNotMatch(md, /^SUPPRESS\s+CS\d+/m, "no legacy SUPPRESS lines may remain in the Markdown");
    assert.throws(() => loadTriage(path.join(PROJECT_ROOT, "circuits", "CIRCOMSPECT.md")));
  });

  it("rejects malformed entries instead of silently widening a suppression", () => {
    const good = { ruleId: "CS0017", file: "circuits/lib/x.circom", match: "signal y", justification: "x".repeat(40) };
    assert.equal(loadTriage(tmpJson({ suppressions: [good] })).length, 1);
    for (const bad of [
      { ...good, ruleId: "CS17" },
      { ...good, file: "" },
      { ...good, file: "circuits\\lib\\x.circom" },
      { ...good, match: " " },
      { ...good, justification: "because" },
    ]) {
      assert.throws(() => loadTriage(tmpJson({ suppressions: [bad] })));
    }
    assert.throws(() => loadTriage(tmpJson({ nope: [] })));
  });

  it("matches rule + file suffix + flagged line text only", () => {
    const t = [{ ruleId: "CS0017", file: "lib/a.circom", match: "signal s", justification: "x".repeat(40) }];
    const f = { ruleId: "CS0017", level: "warning", file: "/p/circuits/lib/a.circom", line: 3, message: "" };
    assert.ok(suppressionFor(t, f, () => "    signal s;"));
    assert.equal(suppressionFor(t, f, () => "    signal other;"), undefined, "other line of same rule");
    assert.equal(suppressionFor(t, { ...f, ruleId: "CS0013" }, () => "    signal s;"), undefined);
    assert.equal(suppressionFor(t, { ...f, file: "/p/circuits/lib/b.circom" }, () => "    signal s;"), undefined);
  });

  it("normalises Windows and POSIX SARIF URIs", () => {
    assert.equal(normaliseUri("file://\\\\?\\C:\\x\\circuits\\lib\\a.circom"), "C:/x/circuits/lib/a.circom");
    assert.equal(normaliseUri("file:///home/u/circuits/lib/a.circom"), "/home/u/circuits/lib/a.circom");
  });

  it("fails closed when the binary is missing or the entrypoint does not exist", () => {
    const sarifPath = path.join(os.tmpdir(), `cs-${process.pid}.sarif`);
    const entry = path.join(PROJECT_ROOT, "circuits", "main", "credential.circom");
    assert.throws(
      () => runCircomspect(entry, { includeDir: ".", sarifPath, binary: "circomspect-definitely-missing" }),
      /not installed or not on PATH/,
    );
    assert.throws(
      () => runCircomspect(path.join(PROJECT_ROOT, "nope.circom"), { includeDir: ".", sarifPath }),
      /entrypoint not found/,
    );
  });
});
