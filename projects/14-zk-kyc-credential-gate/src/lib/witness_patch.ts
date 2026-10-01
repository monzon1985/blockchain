// SPDX-License-Identifier: MIT
//
// Witness forgery primitives: compute an honest `.wtns`, then rewrite single
// witness values with @iden3/binfileutils (the same binary-container library
// snarkjs uses to read and write `.wtns` files).
//
// `.wtns` layout (type "wtns", version 2, 2 sections):
//   section 1 (header): n8 u32 | prime q (n8 bytes LE) | nWitness u32
//   section 2 (values): nWitness field elements, n8 bytes little-endian each
import * as fs from "node:fs";
import * as binFileUtils from "@iden3/binfileutils";
import { wtns, groth16, r1cs as r1csApi } from "snarkjs";
import { artifactPaths } from "./artifacts.ts";
import { FIELD_MODULUS, stringifyInputs } from "./field.ts";

interface WtnsContents {
  n8: number;
  prime: bigint;
  nWitness: number;
  values: Uint8Array;
}

async function readWtns(file: string): Promise<WtnsContents> {
  const { fd, sections } = await binFileUtils.readBinFile(file, "wtns", 2);
  try {
    await binFileUtils.startReadUniqueSection(fd, sections, 1);
    const n8 = await fd.readULE32();
    const prime = await binFileUtils.readBigInt(fd, n8);
    const nWitness = await fd.readULE32();
    await binFileUtils.endReadSection(fd);
    const values = await binFileUtils.readSection(fd, sections, 2);
    if (values.byteLength !== nWitness * n8) {
      throw new Error(`malformed .wtns: section 2 has ${values.byteLength} bytes, expected ${nWitness * n8}`);
    }
    return { n8, prime, nWitness, values };
  } finally {
    await fd.close();
  }
}

async function writeWtns(file: string, w: WtnsContents): Promise<void> {
  const fd = await binFileUtils.createBinFile(file, "wtns", 2, 2);
  try {
    await binFileUtils.startWriteSection(fd, 1);
    await fd.writeULE32(w.n8);
    await binFileUtils.writeBigInt(fd, w.prime, w.n8);
    await fd.writeULE32(w.nWitness);
    await binFileUtils.endWriteSection(fd);
    await binFileUtils.startWriteSection(fd, 2);
    await fd.write(w.values);
    await binFileUtils.endWriteSection(fd);
  } finally {
    await fd.close();
  }
}

function leBytes(value: bigint, n8: number): Uint8Array {
  const out = new Uint8Array(n8);
  let v = value;
  for (let i = 0; i < n8; i++) {
    out[i] = Number(v & 0xffn);
    v >>= 8n;
  }
  return out;
}

function fromLe(bytes: Uint8Array, at: number, n8: number): bigint {
  let v = 0n;
  for (let i = n8 - 1; i >= 0; i--) v = (v << 8n) | BigInt(bytes[at + i] as number);
  return v;
}

/** Compute the honest witness for a circuit and write it to `outWtns`. */
export async function calculateWitness(
  name: string,
  input: Record<string, bigint | bigint[]>,
  outWtns: string,
): Promise<void> {
  const p = artifactPaths(name);
  await wtns.calculate(stringifyInputs(input), p.wasm, outWtns);
}

/**
 * Overwrite the witness value at `index` with `newValue`.
 *
 * This is the core forgery primitive: for an under-constrained signal, the
 * proof still verifies after we replace the witness-only value here.
 */
export async function patchWitnessValue(wtnsPath: string, index: number, newValue: bigint): Promise<void> {
  if (newValue < 0n || newValue >= FIELD_MODULUS) {
    throw new Error(`patched value must be a canonical field element (< r), got ${newValue}`);
  }
  const w = await readWtns(wtnsPath);
  if (w.prime !== FIELD_MODULUS) throw new Error("witness is not over the BN254 scalar field");
  if (!Number.isInteger(index) || index < 0 || index >= w.nWitness) {
    throw new Error(`witness index ${index} out of range (nWitness=${w.nWitness})`);
  }
  const values = new Uint8Array(w.values);
  values.set(leBytes(newValue, w.n8), index * w.n8);
  await writeWtns(wtnsPath, { ...w, values });
}

/** Read the witness value at `index`. */
export async function readWitnessValue(wtnsPath: string, index: number): Promise<bigint> {
  const w = await readWtns(wtnsPath);
  if (index < 0 || index >= w.nWitness) throw new Error(`witness index ${index} out of range`);
  return fromLe(w.values, index * w.n8, w.n8);
}

/** Number of values in a `.wtns` file. */
export async function witnessLength(wtnsPath: string): Promise<number> {
  return (await readWtns(wtnsPath)).nWitness;
}

/** Number of wires (variables) of an r1cs, read with snarkjs. */
export async function r1csWireCount(r1csPath: string): Promise<number> {
  const info = (await r1csApi.info(r1csPath)) as { nVars: number };
  return info.nVars;
}

/** Prove a circuit from a pre-computed (possibly patched) witness file. */
export async function proveGroth16FromWitness(
  name: string,
  wtnsPath: string,
): Promise<{ proof: unknown; publicSignals: string[] }> {
  const p = artifactPaths(name);
  return groth16.prove(p.groth16Zkey, wtnsPath);
}

/** Result of a `snarkjs wtns check`, with the log lines it produced. */
export interface WtnsCheckResult {
  ok: boolean;
  log: string[];
}

/**
 * `snarkjs wtns check` with a capturing logger. Refuses to run when the
 * witness and r1cs layouts differ (snarkjs itself does not check this and
 * would evaluate constraints over mismatched wires, which proves nothing).
 */
export async function checkWitness(r1csPath: string, wtnsPath: string): Promise<WtnsCheckResult> {
  const nVars = await r1csWireCount(r1csPath);
  const nWitness = await witnessLength(wtnsPath);
  if (nVars !== nWitness) {
    throw new Error(`layout mismatch: r1cs has ${nVars} wires but the witness has ${nWitness} values`);
  }
  const log: string[] = [];
  const logger = {
    info: (m: string) => log.push(m),
    warn: (m: string) => log.push(m),
    error: (m: string) => log.push(m),
    debug: () => {},
  };
  const ok = await wtns.check(r1csPath, wtnsPath, logger);
  return { ok, log };
}

/** Delete a scratch witness file (ignore if absent). */
export function removeWitness(file: string): void {
  fs.rmSync(file, { force: true });
}
