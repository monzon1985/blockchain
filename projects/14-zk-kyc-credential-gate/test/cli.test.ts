// SPDX-License-Identifier: MIT
//
// Smoke tests for the CLIs' safety rails (no proving).
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { PROJECT_ROOT } from "../src/lib/artifacts.ts";

function cli(script: string, args: string[]) {
  const res = spawnSync(process.execPath, [path.join(PROJECT_ROOT, "src", "cli", script), ...args], {
    encoding: "utf8",
  });
  return { status: res.status, out: res.stdout, err: res.stderr };
}

describe("CLIs", function () {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "zkkyc-cli-"));
  const keyFile = path.join(dir, "issuer.json");
  const holderFile = path.join(dir, "holder.json");
  let commitment = "";

  before(() => {
    const k = cli("issuer.ts", ["keygen", "--out", keyFile]);
    assert.equal(k.status, 0, k.err);
    assert.ok(!k.out.includes(JSON.parse(fs.readFileSync(keyFile, "utf8")).seed), "seed not printed");
    const h = cli("holder.ts", ["commit", "--out", holderFile]);
    assert.equal(h.status, 0, h.err);
    commitment = JSON.parse(h.out).subjectCommitment;
    assert.ok(!h.out.includes(JSON.parse(fs.readFileSync(holderFile, "utf8")).subjectSecret), "secret not printed");
  });

  const sign = (extra: Record<string, string>) => {
    const f: Record<string, string> = {
      "--key-file": keyFile,
      "--commitment": commitment,
      "--birthdate": "19900215",
      "--country": "724",
      "--accredited": "1",
      "--expiry": "20301231",
      "--cid": "42",
      ...extra,
    };
    return cli("issuer.ts", ["sign", ...Object.entries(f).flat()]);
  };

  it("issuer signs a well-formed credential over the holder's commitment", () => {
    const r = sign({});
    assert.equal(r.status, 0, r.err);
    assert.equal(JSON.parse(r.out).fields.subjectCommitment, commitment);
  });

  it("issuer refuses non-dates, non-boolean flags and the revoked sentinel id", () => {
    const bads: Array<Record<string, string>> = [
      { "--birthdate": "0" },
      { "--birthdate": "19901301" },
      { "--accredited": "7" },
      { "--cid": "1" },
    ];
    for (const bad of bads) {
      const r = sign(bad);
      assert.equal(r.status, 1, JSON.stringify(bad));
      assert.match(r.err, /refusing to sign/);
    }
  });

  it("issuer never takes the seed on the command line and never asks for the subject secret", () => {
    const r = cli("issuer.ts", ["sign", "--seed", `0x${"11".repeat(32)}`, "--commitment", commitment]);
    assert.equal(r.status, 1);
    assert.match(r.err, /never on the command line/);
    const s = sign({ "--subject-secret": "123" });
    assert.equal(s.status, 1);
    assert.match(s.err, /unknown flag --subject-secret/);
  });

  it("prover rejects an unknown proof system instead of silently using groth16", () => {
    const r = cli("prover.ts", ["--dev", "--system", "stark"]);
    assert.equal(r.status, 1);
    assert.match(r.err, /unknown --system "stark"/);
  });
});
