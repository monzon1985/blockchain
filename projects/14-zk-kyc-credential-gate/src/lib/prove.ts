// SPDX-License-Identifier: MIT
import * as fs from "node:fs";
import { groth16, plonk } from "snarkjs";
import { artifactPaths } from "./artifacts.ts";
import { stringifyInputs } from "./field.ts";
import { type CredentialCircuitInput } from "./inputs.ts";

/** A Groth16 proof in the shape the on-chain verifier expects. */
export interface Groth16Calldata {
  a: [string, string];
  b: [[string, string], [string, string]];
  c: [string, string];
  pub: string[];
}

/** A PLONK proof in the shape the on-chain verifier expects. */
export interface PlonkCalldata {
  proof: string[]; // 24 words
  pub: string[];
}

type Inputish = CredentialCircuitInput | Record<string, bigint | bigint[]>;

function toSnarkInput(input: Inputish): Record<string, string | string[]> {
  return stringifyInputs(input as unknown as Record<string, bigint | bigint[]>);
}

/** Generate a Groth16 proof and its public signals for a circuit. */
export async function proveGroth16(
  name: string,
  input: Inputish,
): Promise<{ proof: unknown; publicSignals: string[] }> {
  const p = artifactPaths(name);
  return groth16.fullProve(toSnarkInput(input), p.wasm, p.groth16Zkey);
}

/** Generate a PLONK proof and its public signals for a circuit. */
export async function provePlonk(
  name: string,
  input: Inputish,
): Promise<{ proof: unknown; publicSignals: string[] }> {
  const p = artifactPaths(name);
  return plonk.fullProve(toSnarkInput(input), p.wasm, p.plonkZkey);
}

/** Verify a Groth16 proof with snarkjs against a circuit's verification key. */
export async function verifyGroth16(
  name: string,
  publicSignals: string[],
  proof: unknown,
): Promise<boolean> {
  const p = artifactPaths(name);
  const vkey = JSON.parse(fs.readFileSync(p.groth16Vkey, "utf8"));
  return groth16.verify(vkey, publicSignals, proof);
}

/** Verify a PLONK proof with snarkjs against a circuit's verification key. */
export async function verifyPlonk(
  name: string,
  publicSignals: string[],
  proof: unknown,
): Promise<boolean> {
  const p = artifactPaths(name);
  const vkey = JSON.parse(fs.readFileSync(p.plonkVkey, "utf8"));
  return plonk.verify(vkey, publicSignals, proof);
}

/** Format a Groth16 proof + public signals into on-chain calldata arrays. */
export async function groth16Calldata(
  proof: unknown,
  publicSignals: string[],
): Promise<Groth16Calldata> {
  const raw = await groth16.exportSolidityCallData(proof, publicSignals);
  const parsed = JSON.parse(`[${raw}]`) as [
    [string, string],
    [[string, string], [string, string]],
    [string, string],
    string[],
  ];
  return { a: parsed[0], b: parsed[1], c: parsed[2], pub: parsed[3] };
}

/** Format a PLONK proof + public signals into on-chain calldata arrays. */
export async function plonkCalldata(
  proof: unknown,
  publicSignals: string[],
): Promise<PlonkCalldata> {
  const raw = await plonk.exportSolidityCallData(proof, publicSignals);
  // snarkjs returns "[..24..][..pub..]"; join the two arrays for JSON parsing.
  const parsed = JSON.parse(`[${raw.replace("][", "],[")}]`) as [string[], string[]];
  return { proof: parsed[0], pub: parsed[1] };
}

/** `cast send` signature + positional arguments for a Groth16 registration. */
export function castGroth16(cd: Groth16Calldata): { signature: string; args: string[] } {
  const arr = (xs: string[]): string => `[${xs.join(",")}]`;
  return {
    signature: `registerWithGroth16(uint256[2],uint256[2][2],uint256[2],uint256[${cd.pub.length}])`,
    args: [arr(cd.a), `[${arr(cd.b[0])},${arr(cd.b[1])}]`, arr(cd.c), arr(cd.pub)],
  };
}

/** `cast send` signature + positional arguments for a PLONK registration. */
export function castPlonk(cd: PlonkCalldata): { signature: string; args: string[] } {
  return {
    signature: `registerWithPlonk(uint256[24],uint256[${cd.pub.length}])`,
    args: [`[${cd.proof.join(",")}]`, `[${cd.pub.join(",")}]`],
  };
}
