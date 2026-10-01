// SPDX-License-Identifier: MIT
import assert from "node:assert/strict";
import ctPkg from "circom_tester";
import * as path from "node:path";
import { PROJECT_ROOT } from "../src/lib/artifacts.ts";

interface WasmTester {
  calculateWitness(input: Record<string, unknown>, sanityCheck?: boolean): Promise<bigint[]>;
  checkConstraints(witness: bigint[]): Promise<void>;
  loadSymbols(): Promise<void>;
  getOutput(witness: bigint[], output: Record<string, unknown>): Promise<Record<string, bigint>>;
  symbols?: Record<string, { varIdx: number }>;
}

const wasmTester = (ctPkg as unknown as {
  wasm: (p: string, o: unknown) => Promise<WasmTester>;
}).wasm;

const CIRCOMLIB = path.join(PROJECT_ROOT, "node_modules", "circomlib", "circuits");
const cache = new Map<string, Promise<WasmTester>>();

/** Compile a test circuit under test/circuits/ (cached across a run). */
export function compileTest(relFile: string): Promise<WasmTester> {
  const abs = path.join(PROJECT_ROOT, "test", "circuits", relFile);
  let c = cache.get(abs);
  if (!c) {
    c = wasmTester(abs, { include: [CIRCOMLIB] });
    cache.set(abs, c);
  }
  return c;
}

const CIRCUIT_SOURCES: Record<string, string> = {
  credential: path.join("circuits", "main", "credential.circom"),
  nullifier_unconstrained: path.join("circuits", "zoo", "nullifier_unconstrained.circom"),
  age_no_rangecheck: path.join("circuits", "zoo", "age_no_rangecheck.circom"),
  merkle_selector_nonboolean: path.join("circuits", "zoo", "merkle_selector_nonboolean.circom"),
  nullifier_no_scope: path.join("circuits", "zoo", "nullifier_no_scope.circom"),
};

/** Load a prebuilt circuit (compiled by `npm run circuits:build`). */
export function loadProduction(name: string): Promise<WasmTester> {
  const rel = CIRCUIT_SOURCES[name];
  if (!rel) throw new Error(`unknown circuit ${name}`);
  const abs = path.join(PROJECT_ROOT, rel);
  let c = cache.get(abs);
  if (!c) {
    c = wasmTester(abs, {
      include: [CIRCOMLIB],
      output: path.join(PROJECT_ROOT, "build", name),
      recompile: false,
    });
    cache.set(abs, c);
  }
  return c;
}

/**
 * Assert that computing a witness for `input` fails because a CONSTRAINT
 * (an `===` / `<==` assertion inside a template) fails, and that the failing
 * template chain mentions `template`. A JS error, a wrong input name or a
 * missing wasm therefore never counts as "the circuit rejected it".
 */
export async function expectWitnessFailure(
  circuit: WasmTester,
  input: Record<string, unknown>,
  template: string,
): Promise<string> {
  let message: string | undefined;
  try {
    await circuit.calculateWitness(input, true);
  } catch (err) {
    message = err instanceof Error ? err.message : String(err);
  }
  assert.ok(message !== undefined, "expected witness computation to fail, but it succeeded");
  assert.match(message, /Assert Failed/, `not a constraint failure: ${message}`);
  assert.ok(
    message.includes(`Error in template ${template}`),
    `expected the failure inside template ${template}, got: ${message}`,
  );
  return message;
}

/** Assert that `checkConstraints` rejects a (tampered) full witness. */
export async function expectConstraintViolation(circuit: WasmTester, witness: bigint[]): Promise<void> {
  await assert.rejects(() => circuit.checkConstraints(witness), /Constraint doesn't match/);
}

/** Cast a typed circuit input to the loose record circom_tester expects. */
export function asInput(input: object): Record<string, unknown> {
  return input as unknown as Record<string, unknown>;
}
