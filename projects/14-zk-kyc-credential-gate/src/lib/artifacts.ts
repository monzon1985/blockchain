// SPDX-License-Identifier: MIT
import * as path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));

/** Project root (…/14-zk-kyc-credential-gate). */
export const PROJECT_ROOT = path.resolve(here, "..", "..");

/** Locations of build artifacts produced by circuits:build and setup:dev. */
export function artifactPaths(name: string): {
  wasm: string;
  r1cs: string;
  groth16Zkey: string;
  groth16Vkey: string;
  plonkZkey: string;
  plonkVkey: string;
} {
  const buildDir = path.join(PROJECT_ROOT, "build", name);
  const keys = path.join(PROJECT_ROOT, "build", "keys");
  return {
    wasm: path.join(buildDir, `${name}_js`, `${name}.wasm`),
    r1cs: path.join(buildDir, `${name}.r1cs`),
    groth16Zkey: path.join(keys, `${name}.groth16.zkey`),
    groth16Vkey: path.join(keys, `${name}.groth16.vkey.json`),
    plonkZkey: path.join(keys, `${name}.plonk.zkey`),
    plonkVkey: path.join(keys, `${name}.plonk.vkey.json`),
  };
}

/** Directory that holds committed Foundry proof fixtures. */
export const FIXTURES_DIR = path.join(PROJECT_ROOT, "contracts", "test", "fixtures");
