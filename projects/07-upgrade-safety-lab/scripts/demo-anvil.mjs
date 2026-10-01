#!/usr/bin/env node
// SPDX-License-Identifier: MIT
//
// Local end-to-end demo on anvil: the full upgrade lineage with keystore-signed forge scripts and an on-chain
// verification (ERC-1967 implementation slot, empty admin slot, version(), owner, storage sentinels, the OZ 5.x
// namespaces and, from V2 on, the AccessManager configuration) after each step: V1, bridge, V2, the scheduled V3
// upgrade, its cancellation by the guardian, V3, and the diamond.
//
//   node scripts/demo-anvil.mjs
//
// anvil listens on a free port chosen at runtime; the signing key is a fresh throwaway keystore in a temporary
// directory (funded with anvil_setBalance), deleted at the end together with the anvil process (killed by PID).

import { spawn, spawnSync } from "node:child_process";
import { randomBytes } from "node:crypto";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const UPGRADE_DELAY = 2 * 24 * 60 * 60;

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

function run(cmd, args, { env, quiet } = {}) {
  const res = spawnSync(cmd, args, { cwd: root, encoding: "utf8", env: { ...process.env, ...env } });
  if (res.status !== 0) {
    console.error(res.stdout);
    console.error(res.stderr);
    throw new Error(`${cmd} ${args.join(" ")} exited with ${res.status}`);
  }
  if (!quiet) process.stdout.write(".");
  return res.stdout.trim();
}

const port = await freePort();
const rpc = `http://127.0.0.1:${port}`;
const anvil = spawn("anvil", ["--port", String(port), "--silent"], { stdio: "ignore" });
const tmp = mkdtempSync(join(tmpdir(), "upgrade-lab-"));

function cleanup() {
  if (anvil.exitCode === null) anvil.kill();
  rmSync(tmp, { recursive: true, force: true });
}
process.on("SIGINT", () => {
  cleanup();
  process.exit(130);
});

try {
  // Wait for anvil.
  for (let i = 0; ; i++) {
    const probe = spawnSync("cast", ["chain-id", "--rpc-url", rpc], { encoding: "utf8" });
    if (probe.status === 0) break;
    if (i > 100) throw new Error("anvil did not start");
    await new Promise((r) => setTimeout(r, 100));
  }
  console.log(`anvil pid ${anvil.pid} on ${rpc}`);

  // Throwaway keystore: random key, random password, both inside the temp dir. The password reaches cast through
  // the environment and forge through a file, never through a command line.
  const password = randomBytes(16).toString("hex");
  const passwordFile = join(tmp, "password");
  writeFileSync(passwordFile, password);
  const keystoreDir = join(tmp, "keystore");
  mkdirSync(keystoreDir);
  run("cast", ["wallet", "new", keystoreDir, "lab-deployer"], { env: { CAST_PASSWORD: password }, quiet: true });
  const keystore = join(keystoreDir, "lab-deployer");
  const deployer = run("cast", ["wallet", "address", "--keystore", keystore, "--password-file", passwordFile], {
    quiet: true,
  });
  run("cast", ["rpc", "anvil_setBalance", deployer, "0x3635C9ADC5DEA00000", "--rpc-url", rpc], { quiet: true });
  console.log(`deployer ${deployer} (throwaway keystore)`);

  const sign = ["--keystore", keystore, "--password-file", passwordFile, "--sender", deployer];
  const script = (target, extra = []) =>
    run("forge", ["script", target, "--rpc-url", rpc, "--broadcast", ...sign, ...extra]);
  const verify = (stage) => {
    run("forge", ["script", "script/VerifyDeployment.s.sol", "--rpc-url", rpc, "--sig", "run(string)", stage]);
    console.log(` verified: ${stage}`);
  };

  script("script/DeployV1.s.sol:DeployV1");
  run("forge", ["script", "script/DeployV1.s.sol:RecordSentinels", "--rpc-url", rpc]);
  verify("v1");

  // Steps 2a and 2b are one multisig batch in production; broadcast separately here so the intermediate bridge
  // state (owner and version 2 in the OZ 5.x namespaces, legacy slots zeroed) is verified on-chain too.
  script("script/MigrateToV2.s.sol:MigrateToBridge");
  verify("bridge");
  script("script/MigrateToV2.s.sol:MigrateToV2");
  verify("v2");

  script("script/UpgradeToV3.s.sol:ScheduleV3Upgrade");
  verify("v3-scheduled");
  script("script/UpgradeToV3.s.sol:CancelV3Upgrade");
  console.log(" cancelled the scheduled upgrade (guardian path)");
  script("script/UpgradeToV3.s.sol:ScheduleV3Upgrade");
  verify("v3-scheduled");

  run("cast", ["rpc", "evm_increaseTime", String(UPGRADE_DELAY), "--rpc-url", rpc], { quiet: true });
  run("cast", ["rpc", "evm_mine", "--rpc-url", rpc], { quiet: true });
  script("script/UpgradeToV3.s.sol:ExecuteV3Upgrade");
  verify("v3");

  script("script/DeployDiamond.s.sol:DeployDiamond");
  verify("diamond");

  console.log("\nlocal demo: V1 -> bridge -> V2 -> (cancel) -> V3 and the diamond, all verified on-chain");
} finally {
  cleanup();
}
