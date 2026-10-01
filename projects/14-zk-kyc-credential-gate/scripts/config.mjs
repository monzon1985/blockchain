// SPDX-License-Identifier: MIT
import * as path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));

/** Absolute path to the project root. */
export const ROOT = path.resolve(here, "..");

export const DIRS = {
  circuits: path.join(ROOT, "circuits"),
  build: path.join(ROOT, "build"),
  keys: path.join(ROOT, "build", "keys"),
  ptau: path.join(ROOT, "build", "ptau"),
  circomlib: path.join(ROOT, "node_modules", "circomlib", "circuits"),
  // snarkjs-generated verifiers live outside src/ so `forge fmt --check` (which
  // scans src/test/script) never lints third-party generated code.
  verifiers: path.join(ROOT, "contracts", "generated"),
  fixtures: path.join(ROOT, "contracts", "test", "fixtures"),
};

/**
 * The circuits this project builds. `verifierName` is the on-chain contract
 * name snarkjs emits; `verifierFile` is where we place it under contracts/.
 */
export const CIRCUITS = [
  {
    name: "credential",
    source: path.join(DIRS.circuits, "main", "credential.circom"),
    kind: "production",
    plonk: true,
    verifierName: "CredentialVerifier",
  },
  {
    name: "nullifier_unconstrained",
    source: path.join(DIRS.circuits, "zoo", "nullifier_unconstrained.circom"),
    kind: "zoo",
    plonk: false,
    verifierName: "ZooNullifierUnconstrainedVerifier",
  },
  {
    name: "age_no_rangecheck",
    source: path.join(DIRS.circuits, "zoo", "age_no_rangecheck.circom"),
    kind: "zoo",
    plonk: false,
    verifierName: "ZooAgeNoRangeCheckVerifier",
  },
  {
    name: "merkle_selector_nonboolean",
    source: path.join(DIRS.circuits, "zoo", "merkle_selector_nonboolean.circom"),
    kind: "zoo",
    plonk: false,
    verifierName: "ZooMerkleSelectorVerifier",
  },
  {
    name: "nullifier_no_scope",
    source: path.join(DIRS.circuits, "zoo", "nullifier_no_scope.circom"),
    kind: "zoo",
    plonk: false,
    verifierName: "ZooNullifierNoScopeVerifier",
  },
  {
    name: "baseline_committed_list",
    source: path.join(DIRS.circuits, "bench", "baseline_committed_list.circom"),
    kind: "bench",
    plonk: false,
    verifierName: "BaselineCommittedListVerifier",
  },
];

/**
 * Powers-of-Tau size (2^POWER). 2^16 = 65536 covers the ~27.9k R1CS
 * constraints of each circuit and the production circuit's PLONK gate count.
 */
export const PTAU_POWER = 16;

/**
 * Fixed, PUBLIC beacon values for a DETERMINISTIC dev/CI ceremony.
 *
 * Phase 1 and every Groth16 phase 2 consist of a single beacon contribution,
 * whose key snarkjs derives only from `beaconHash` (iterated 2^beaconIterExp
 * times) and the running transcript. There is deliberately NO `contribute()`
 * step: snarkjs mixes OS randomness into contribute()'s entropy, which is
 * what made earlier ceremonies irreproducible. The toxic waste is therefore
 * knowable by anyone: these keys must never secure real value.
 *
 * The beacon hash is sha256("zk-kyc-credential-gate/dev-ceremony/v2").
 */
export const CEREMONY = {
  ptauBeaconName: "zk-kyc dev phase-1 beacon v2",
  ptauBeaconHash: "f32a6fad17e22c20cb8b57a81b01a6fbf7eb32cafe3781cca6a6b7279f4c84fa",
  zkeyBeaconName: "zk-kyc dev phase-2 beacon v2",
  zkeyBeaconHash: "f32a6fad17e22c20cb8b57a81b01a6fbf7eb32cafe3781cca6a6b7279f4c84fa",
  beaconIterExp: 10,
};

/**
 * Committed provenance record of the ceremony (hashes of the ptau, every
 * r1cs, zkey, vkey and verifier). Lives next to the verifiers it describes so
 * it is committed; `npm run setup:dev -- --check` compares against it.
 */
export const PROVENANCE_FILE = path.join(DIRS.verifiers, "PROVENANCE.json");

/** Paths derived for a given circuit name. */
export function circuitPaths(name) {
  const dir = path.join(DIRS.build, name);
  return {
    dir,
    wasm: path.join(dir, `${name}_js`, `${name}.wasm`),
    r1cs: path.join(dir, `${name}.r1cs`),
    sym: path.join(dir, `${name}.sym`),
    groth16Zkey: path.join(DIRS.keys, `${name}.groth16.zkey`),
    groth16Vkey: path.join(DIRS.keys, `${name}.groth16.vkey.json`),
    plonkZkey: path.join(DIRS.keys, `${name}.plonk.zkey`),
    plonkVkey: path.join(DIRS.keys, `${name}.plonk.vkey.json`),
  };
}
