#!/usr/bin/env node
// SPDX-License-Identifier: MIT
//
// Local end-to-end demo on anvil: holder -> issuer -> governor -> deploy -> prove -> register.
//
//   npm run demo        (after `npm run circuits:build && npm run setup:dev`)
//
//  1. the holder generates a secret locally and hands only its commitment to the issuer;
//  2. the issuer signs a credential over that commitment (seed kept in a key file);
//  3. the governor builds the public world (issuer tree, revocation SMT) and its roots;
//  4. a keystore-signed `forge script` deploys the verifiers and ZkGate with those roots;
//  5. the holder reads `appScope()` from the live gate and proves, bound to their own address;
//  6. a different sender replaying the same calldata is rejected (RecipientMismatch);
//  7. the holder registers with `cast send`; a replay is rejected (NullifierAlreadyUsed).
//
// anvil listens on a free port chosen at runtime and is killed by PID at the end. The signing key
// is a fresh throwaway keystore (random password in a temp file) funded with anvil_setBalance;
// all secrets live in a temp directory that is deleted afterwards.
import { spawn, spawnSync } from "node:child_process";
import { randomBytes } from "node:crypto";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const contracts = join(root, "contracts");
// anvil's well-known PUBLIC account #1, used only as an eth_call `from` (never signs anything).
const OTHER_SENDER = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8";

function freePort() {
  return new Promise((resolve, reject) => {
    const server = createServer();
    server.unref();
    server.on("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const { port } = server.address();
      server.close(() => resolve(port));
    });
  });
}

function run(cmd, args, { cwd = root, env, allowFail = false } = {}) {
  const res = spawnSync(cmd, args, { cwd, encoding: "utf8", env: { ...process.env, ...env } });
  if (res.status !== 0 && !allowFail) {
    console.error(res.stdout);
    console.error(res.stderr);
    throw new Error(`${cmd} ${args.slice(0, 3).join(" ")} ... exited with ${res.status}`);
  }
  return { status: res.status, out: (res.stdout ?? "").trim(), err: (res.stderr ?? "").trim() };
}
const node = (script, args) => JSON.parse(run(process.execPath, [join(root, script), ...args]).out);
const step = (msg) => console.log(`\n== ${msg}`);

const port = await freePort();
const rpc = `http://127.0.0.1:${port}`;
const anvil = spawn("anvil", ["--port", String(port), "--silent"], { stdio: "ignore" });
const tmp = mkdtempSync(join(tmpdir(), "zk-kyc-demo-"));

function cleanup() {
  if (anvil.exitCode === null) anvil.kill();
  rmSync(tmp, { recursive: true, force: true });
}
process.on("SIGINT", () => {
  cleanup();
  process.exit(130);
});

try {
  for (let i = 0; ; i++) {
    if (spawnSync("cast", ["chain-id", "--rpc-url", rpc], { encoding: "utf8" }).status === 0) break;
    if (i > 100) throw new Error("anvil did not start");
    await new Promise((r) => setTimeout(r, 100));
  }
  console.log(`anvil pid ${anvil.pid} on ${rpc}`);

  step("holder: generate a secret locally, hand only the commitment to the issuer");
  const holderFile = join(tmp, "holder.json");
  const { subjectCommitment } = node("src/cli/holder.ts", ["commit", "--out", holderFile]);
  console.log(`commitment ${subjectCommitment}`);

  step("issuer: keygen + sign a credential over the commitment");
  const issuerFile = join(tmp, "issuer.json");
  node("src/cli/issuer.ts", ["keygen", "--out", issuerFile]);
  const credFile = join(tmp, "credential.json");
  node("src/cli/issuer.ts", [
    "sign", "--key-file", issuerFile, "--commitment", subjectCommitment,
    "--birthdate", "19900215", "--country", "724", "--accredited", "1",
    "--expiry", "20391231", "--cid", "424242", "--out", credFile,
  ]);

  step("governor: build the public world and its roots (date = anvil's UTC date)");
  const ts = Number(run("cast", ["block", "latest", "--field", "timestamp", "--rpc-url", rpc]).out);
  const d = new Date(ts * 1000);
  const date = `${d.getUTCFullYear()}${String(d.getUTCMonth() + 1).padStart(2, "0")}${String(d.getUTCDate()).padStart(2, "0")}`;
  const worldFile = join(tmp, "world.json");
  const roots = node("src/cli/world.ts", ["init", "--issuer-key-file", issuerFile, "--date", date, "--out", worldFile]);
  console.log(`issuerRoot ${roots.issuerRoot}\nrevocationRoot ${roots.revocationRoot}\ncurrentDate ${roots.currentDate}`);

  step("deploy: keystore-signed forge script");
  const password = randomBytes(16).toString("hex");
  const passwordFile = join(tmp, "password");
  writeFileSync(passwordFile, password);
  const keystoreDir = join(tmp, "keystore");
  mkdirSync(keystoreDir);
  run("cast", ["wallet", "new", keystoreDir, "zkkyc-demo"], { env: { CAST_PASSWORD: password } });
  const keystore = join(keystoreDir, "zkkyc-demo");
  const me = run("cast", ["wallet", "address", "--keystore", keystore, "--password-file", passwordFile]).out;
  run("cast", ["rpc", "anvil_setBalance", me, "0x3635C9ADC5DEA00000", "--rpc-url", rpc]);
  const sign = ["--keystore", keystore, "--password-file", passwordFile];
  const deploy = run(
    "forge",
    ["script", "script/Deploy.s.sol:Deploy", "--rpc-url", rpc, "--broadcast", ...sign, "--sender", me],
    {
      cwd: contracts,
      env: {
        ZKG_ISSUER_ROOT: roots.issuerRoot,
        ZKG_REVOCATION_ROOT: roots.revocationRoot,
        ZKG_CURRENT_DATE: roots.currentDate,
        ZKG_SANCTIONED: roots.sanctioned.join(","),
      },
    },
  );
  const gate = /ZKGATE_ADDRESS\s+(0x[0-9a-fA-F]{40})/.exec(deploy.out)?.[1];
  if (!gate) throw new Error(`could not find the gate address in:\n${deploy.out}`);
  console.log(`ZkGate ${gate} (admin ${me})`);

  step("holder: read appScope() from the live gate and prove, bound to my address");
  const scope = run("cast", ["call", gate, "appScope()(uint256)", "--rpc-url", rpc]).out.split(" ")[0];
  const proofFile = join(tmp, "proof.json");
  const t0 = Date.now();
  run(process.execPath, [
    join(root, "src/cli/prover.ts"), "--credential", credFile, "--secret-file", holderFile,
    "--world", worldFile, "--scope", scope, "--recipient", me, "--system", "groth16", "--out", proofFile,
  ]);
  const proof = JSON.parse(readFileSync(proofFile, "utf8"));
  console.log(`proved + verified locally in ${Date.now() - t0} ms (scope ${scope})`);

  step("front-runner: the same calldata from another sender is rejected");
  const sel = (sig) => run("cast", ["sig", sig]).out;
  const steal = run(
    "cast",
    ["call", "--from", OTHER_SENDER, gate, proof.cast.signature, ...proof.cast.args, "--rpc-url", rpc],
    { allowFail: true },
  );
  const recipientMismatch = sel("RecipientMismatch(uint256,uint256)");
  if (steal.status === 0 || !`${steal.out}${steal.err}`.includes(recipientMismatch.slice(2))) {
    throw new Error(`expected RecipientMismatch, got:\n${steal.out}\n${steal.err}`);
  }
  console.log(`rejected with RecipientMismatch (${recipientMismatch})`);

  step("holder: register with cast send");
  run("cast", ["send", gate, proof.cast.signature, ...proof.cast.args, "--rpc-url", rpc, ...sign]);
  const registered = run("cast", ["call", gate, "isRegistered(address)(bool)", me, "--rpc-url", rpc]).out;
  if (registered !== "true") throw new Error(`isRegistered returned ${registered}`);
  console.log(`isRegistered(${me}) = ${registered}`);

  step("replay: the burned nullifier cannot be used again");
  const replay = run(
    "cast",
    ["call", "--from", me, gate, proof.cast.signature, ...proof.cast.args, "--rpc-url", rpc],
    { allowFail: true },
  );
  const used = sel("NullifierAlreadyUsed(uint256)");
  if (replay.status === 0 || !`${replay.out}${replay.err}`.includes(used.slice(2))) {
    throw new Error(`expected NullifierAlreadyUsed, got:\n${replay.out}\n${replay.err}`);
  }
  console.log(`rejected with NullifierAlreadyUsed (${used})`);

  console.log("\nlocal demo OK: commit -> sign -> deploy -> prove -> front-run rejected -> register -> replay rejected");
} finally {
  cleanup();
}
