// SPDX-License-Identifier: MIT
//
// Benchmark Groth16 vs PLONK for the production circuit: R1CS size, proving
// time and proof size. Verification gas is measured on-chain by the Foundry
// GasBench suite (named snapshots in contracts/snapshots/GasBench.json).
//
//   npm run bench
import { r1cs as r1csApi } from "snarkjs";
import {
  buildScenario,
  defaultCredentialFields,
  issueCredential,
  witnessFor,
} from "../src/lib/scenario.ts";
import { proveGroth16, provePlonk, groth16Calldata, plonkCalldata } from "../src/lib/prove.ts";
import { artifactPaths } from "../src/lib/artifacts.ts";

interface R1csInfo {
  nConstraints: number;
  nVars: number;
  nPubInputs: number;
  nOutputs: number;
}

async function main(): Promise<void> {
  const scenario = await buildScenario();
  const cred = issueCredential(scenario, defaultCredentialFields(scenario.eddsa));
  const input = await witnessFor(scenario, cred, scenario.appScopeA);

  const rows: Array<Record<string, string | number>> = [];
  {
    const t = Date.now();
    const { proof, publicSignals } = await proveGroth16("credential", input);
    const ms = Date.now() - t;
    const cd = await groth16Calldata(proof, publicSignals);
    const proofBytes = (cd.a.length + cd.b.flat().length + cd.c.length) * 32;
    rows.push({ system: "Groth16", provingMs: ms, proofBytes, publicSignals: publicSignals.length });
  }
  {
    const t = Date.now();
    const { proof, publicSignals } = await provePlonk("credential", input);
    const ms = Date.now() - t;
    const cd = await plonkCalldata(proof, publicSignals);
    rows.push({ system: "PLONK", provingMs: ms, proofBytes: cd.proof.length * 32, publicSignals: publicSignals.length });
  }

  const info = (await r1csApi.info(artifactPaths("credential").r1cs)) as R1csInfo;
  console.log(
    `\nProduction circuit: ${info.nConstraints} R1CS constraints, ${info.nVars} wires, ` +
      `${info.nOutputs + info.nPubInputs} public signals`,
  );
  console.log("system   | proving(ms) | proof(bytes) | public signals");
  console.log("---------|-------------|--------------|---------------");
  for (const r of rows) {
    console.log(
      `${String(r.system).padEnd(8)} | ${String(r.provingMs).padStart(11)} | ${String(r.proofBytes).padStart(12)} | ${String(r.publicSignals).padStart(14)}`,
    );
  }
  console.log("\nVerification gas: contracts/snapshots/GasBench.json (forge test --match-contract GasBench).");
  process.exit(0);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
