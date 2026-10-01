// SPDX-License-Identifier: MIT
//
// Prover CLI (holder side): prove the KYC statement for a credential the
// issuer signed, bound to one gate/epoch scope and one submitting address,
// and print calldata ready for `cast send`.
//
//   node src/cli/prover.ts --credential credential.json --secret-file holder.json \
//        --world world.json --scope <ZkGate.appScope()> --recipient 0xYourAddress \
//        --system groth16|plonk [--out proof.json]
//
//   node src/cli/prover.ts --dev --system groth16     # deterministic dev scenario
//
// `--scope` must be read from the live gate (`cast call <gate> "appScope()(uint256)"`):
// it binds the gate address, chain id, action id and current epoch.
import { getAddress, type Address } from "viem";
import { getEddsa } from "../lib/crypto.ts";
import { buildCredentialInput, type CredentialCircuitInput } from "../lib/inputs.ts";
import { buildWorld, issuerIndexOf, readWorldFile } from "../lib/world.ts";
import { credentialFromFile, type CredentialFile, type HolderFile } from "../lib/files.ts";
import { addressToField, FIELD_MODULUS } from "../lib/field.ts";
import { assertStrongSecret } from "../lib/holder.ts";
import {
  buildScenario,
  defaultCredentialFields,
  issueCredential,
  witnessFor,
} from "../lib/scenario.ts";
import {
  proveGroth16,
  provePlonk,
  verifyGroth16,
  verifyPlonk,
  groth16Calldata,
  plonkCalldata,
  castGroth16,
  castPlonk,
} from "../lib/prove.ts";
import { bigintFlag, parseFlags, readJson, required, runCli, writeJson } from "./args.ts";

const SYSTEMS = ["groth16", "plonk"] as const;
type ProofSystem = (typeof SYSTEMS)[number];

async function inputFromFiles(flags: Map<string, string>): Promise<CredentialCircuitInput> {
  const eddsa = await getEddsa();
  const credential = credentialFromFile(readJson<CredentialFile>(required(flags, "credential")));
  const holder = readJson<HolderFile>(required(flags, "secret-file"));
  const secret = BigInt(holder.subjectSecret);
  assertStrongSecret(secret);
  const world = await buildWorld(eddsa, readWorldFile(required(flags, "world")));
  const scope = bigintFlag(flags, "scope");
  if (scope >= FIELD_MODULUS) throw new Error("--scope must be < r (read it from ZkGate.appScope())");
  let recipient: Address;
  try {
    recipient = getAddress(required(flags, "recipient"));
  } catch {
    throw new Error("--recipient must be a 20-byte hex address");
  }
  const index = issuerIndexOf(eddsa, world, credential.issuerAx, credential.issuerAy);
  return buildCredentialInput({
    eddsa,
    credential,
    subjectSecret: secret,
    issuerProof: world.issuerTree.proof(index),
    revocationProof: await world.revocationTree.nonMembership(credential.fields.credentialId),
    sanctioned: world.sanctioned,
    currentDate: world.currentDate,
    appScope: scope,
    recipient: addressToField(recipient),
  });
}

async function devInput(): Promise<CredentialCircuitInput> {
  const scenario = await buildScenario();
  const cred = issueCredential(scenario, defaultCredentialFields(scenario.eddsa));
  return witnessFor(scenario, cred, scenario.appScopeA);
}

async function main(): Promise<void> {
  const argv = process.argv.slice(2);
  const dev = argv.includes("--dev");
  const flags = parseFlags(
    argv.filter((a) => a !== "--dev"),
    dev ? ["system", "out"] : ["credential", "secret-file", "world", "scope", "recipient", "system", "out"],
  );
  const system = (flags.get("system") ?? "groth16") as ProofSystem;
  if (!SYSTEMS.includes(system)) {
    throw new Error(`unknown --system "${system}" (expected ${SYSTEMS.join(" or ")})`);
  }

  const input = dev ? await devInput() : await inputFromFiles(flags);
  const started = Date.now();
  let result: Record<string, unknown>;
  if (system === "plonk") {
    const { proof, publicSignals } = await provePlonk("credential", input);
    const verified = await verifyPlonk("credential", publicSignals, proof);
    const calldata = await plonkCalldata(proof, publicSignals);
    result = { system, verified, ms: Date.now() - started, publicSignals, calldata, cast: castPlonk(calldata) };
  } else {
    const { proof, publicSignals } = await proveGroth16("credential", input);
    const verified = await verifyGroth16("credential", publicSignals, proof);
    const calldata = await groth16Calldata(proof, publicSignals);
    result = { system, verified, ms: Date.now() - started, publicSignals, calldata, cast: castGroth16(calldata) };
  }
  if (result.verified !== true) throw new Error("local verification of the fresh proof failed");
  const out = flags.get("out");
  if (out) writeJson(out, result);
  console.log(JSON.stringify(result, null, 2));
}

runCli(main);
