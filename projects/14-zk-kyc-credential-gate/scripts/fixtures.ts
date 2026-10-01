// SPDX-License-Identifier: MIT
//
// Generate (or --check) the committed proof fixtures the Foundry suite loads.
//
//   npm run fixtures             prove every scenario and write the fixtures
//   npm run fixtures -- --check  verify the COMMITTED fixtures, write nothing
//
// --check does not re-prove (Groth16/PLONK proofs are randomised, so fresh
// proofs would say nothing about the committed ones). Instead, for every
// committed fixture file it:
//   1. verifies the committed snarkjs proof with snarkjs against the freshly
//      exported verification key of the circuit it claims to be for,
//   2. recomputes the public signals the scenario MUST produce (nullifiers,
//      date, roots, sanctioned list, address/epoch-bound scope, recipient)
//      and requires the committed signals to equal them exactly,
//   3. re-derives the Solidity calldata from the committed proof and requires
//      the committed a/b/c/pub (what Foundry actually feeds the verifier) to
//      equal it, and
//   4. deep-compares gate.json with the regenerated deployment constants,
// and fails if any fixture is missing or any unexpected JSON file exists.
// Write mode runs exactly the same checks on what it just wrote.
import * as fs from "node:fs";
import * as path from "node:path";
import { poseidon, nullifier } from "../src/lib/crypto.ts";
import {
  buildScenario,
  defaultCredentialFields,
  issueCredential,
  witnessFor,
  DEV_ACTION_ID,
  DEV_CHAIN_ID,
  DEV_EPOCH,
  DEV_EPOCH_DURATION,
  DEV_GATE_ADDRESS,
  DEV_GATE_B_ADDRESS,
  DEV_RECIPIENT,
  DEV_SUBJECT_SECRET,
  DEV_TIMESTAMP,
  type Scenario,
} from "../src/lib/scenario.ts";
import { FIELD_MODULUS } from "../src/lib/field.ts";
import { buildCredentialInput, type CredentialCircuitInput } from "../src/lib/inputs.ts";
import {
  proveGroth16,
  verifyGroth16,
  provePlonk,
  verifyPlonk,
  groth16Calldata,
  plonkCalldata,
  type Groth16Calldata,
} from "../src/lib/prove.ts";
import { calculateWitness, patchWitnessValue, proveGroth16FromWitness } from "../src/lib/witness_patch.ts";
import {
  ATTACKER_SUBJECT_SECRET,
  NULLIFIER_WITNESS_INDEX,
  WRAPPED_BIRTHDATE,
  attackerSelfSignedCredential,
  forgeNonBooleanSelectorPath,
} from "../src/lib/zoo_attacks.ts";
import { FIXTURES_DIR, PROJECT_ROOT } from "../src/lib/artifacts.ts";

const CHECK = process.argv.includes("--check");

function log(msg: string): void {
  process.stdout.write(`[fixtures${CHECK ? ":check" : ""}] ${msg}\n`);
}

const failures: string[] = [];
function expect(cond: boolean, reason: string): void {
  if (!cond) failures.push(reason);
}

const hx = (v: bigint | string): string => `0x${(typeof v === "string" ? BigInt(v) : v).toString(16)}`;
const hxArr = (vs: string[]): string[] => vs.map(hx);
const hxGroth16 = (cd: Groth16Calldata) => ({
  a: hxArr(cd.a),
  b: [hxArr(cd.b[0]), hxArr(cd.b[1])],
  c: hxArr(cd.c),
  pub: hxArr(cd.pub),
});
const dec = (vs: bigint[]): string[] => vs.map((v) => v.toString());
type Loose = Record<string, bigint | bigint[]>;
const loose = (i: CredentialCircuitInput): Loose => i as unknown as Loose;

/** Deep equality on JSON-shaped values (key order independent). */
function jsonEqual(a: unknown, b: unknown): boolean {
  if (Array.isArray(a) && Array.isArray(b)) return a.length === b.length && a.every((x, i) => jsonEqual(x, b[i]));
  if (a && b && typeof a === "object" && typeof b === "object") {
    const ka = Object.keys(a).sort();
    const kb = Object.keys(b).sort();
    return (
      jsonEqual(ka, kb) &&
      ka.every((k) => jsonEqual((a as Record<string, unknown>)[k], (b as Record<string, unknown>)[k]))
    );
  }
  return a === b;
}

// ---------------------------------------------------------------------------
// Expected (deterministic) content
// ---------------------------------------------------------------------------

interface Expected {
  s: Scenario;
  issuerRoot: bigint;
  revocationRoot: bigint;
  gate: Record<string, unknown>;
  credPub: (nf: bigint, scope: bigint) => bigint[];
}

async function expected(): Promise<Expected> {
  const s = await buildScenario();
  const issuerRoot = s.issuerTree.root();
  const revocationRoot = s.revocationTree.root();
  const gate = {
    chainId: DEV_CHAIN_ID.toString(),
    gateAddress: DEV_GATE_ADDRESS,
    gateBAddress: DEV_GATE_B_ADDRESS,
    actionId: DEV_ACTION_ID,
    epochDuration: DEV_EPOCH_DURATION.toString(),
    timestamp: DEV_TIMESTAMP.toString(),
    epoch: DEV_EPOCH.toString(),
    appScope: hx(s.appScopeA),
    appScopeB: hx(s.appScopeB),
    recipient: DEV_RECIPIENT,
    currentDate: s.currentDate.toString(),
    issuerRoot: hx(issuerRoot),
    revocationRoot: hx(revocationRoot),
    sanctioned: dec(s.sanctioned),
  };
  const credPub = (nf: bigint, scope: bigint): bigint[] => [
    nf,
    s.currentDate,
    issuerRoot,
    revocationRoot,
    ...s.sanctioned,
    scope,
    s.recipient,
  ];
  return { s, issuerRoot, revocationRoot, gate, credPub };
}

// ---------------------------------------------------------------------------
// Fixture specs: how to prove (write mode) and what must hold (both modes)
// ---------------------------------------------------------------------------

interface ProofSpec {
  /** JSON path of the proof object inside the file ("" = top level). */
  key: string;
  system: "groth16" | "plonk";
  circuit: string;
  pub: bigint[];
}

interface FixtureSpec {
  file: string;
  proofs: ProofSpec[];
  /** Extra deterministic fields the file must carry. */
  extra: Record<string, unknown>;
  /** Produce the file content (write mode only). */
  make: () => Promise<Record<string, unknown>>;
}

async function groth16Obj(circuit: string, input: Loose) {
  const { proof, publicSignals } = await proveGroth16(circuit, input);
  return { ...hxGroth16(await groth16Calldata(proof, publicSignals)), snarkjs: { proof, publicSignals } };
}

function specs(e: Expected): FixtureSpec[] {
  const { s } = e;
  const honestNf = nullifier(s.eddsa, DEV_SUBJECT_SECRET, s.appScopeA);
  const forgedNf = (honestNf + 12345n) % FIELD_MODULUS;
  const commitment = poseidon(s.eddsa, [DEV_SUBJECT_SECRET]);
  const attackerNf = nullifier(s.eddsa, ATTACKER_SUBJECT_SECRET, s.appScopeA);
  const baselineIn = [1n, 2n, 3n, 4n, 5n, 6n];
  const baselineOut = poseidon(s.eddsa, baselineIn);

  const honestInput = async (scope: bigint) =>
    loose(await witnessFor(s, issueCredential(s, defaultCredentialFields(s.eddsa)), scope));

  return [
    {
      file: "valid_groth16.json",
      proofs: [{ key: "", system: "groth16", circuit: "credential", pub: e.credPub(honestNf, s.appScopeA) }],
      extra: {},
      make: async () => groth16Obj("credential", await honestInput(s.appScopeA)),
    },
    {
      file: "valid_plonk.json",
      proofs: [{ key: "", system: "plonk", circuit: "credential", pub: e.credPub(honestNf, s.appScopeA) }],
      extra: {},
      make: async () => {
        const { proof, publicSignals } = await provePlonk("credential", await honestInput(s.appScopeA));
        const cd = await plonkCalldata(proof, publicSignals);
        return { proof: hxArr(cd.proof), pub: hxArr(cd.pub), snarkjs: { proof, publicSignals } };
      },
    },
    {
      file: "zoo_nullifier.json",
      proofs: [
        { key: "proofA", system: "groth16", circuit: "nullifier_unconstrained", pub: e.credPub(honestNf, s.appScopeA) },
        { key: "proofB", system: "groth16", circuit: "nullifier_unconstrained", pub: e.credPub(forgedNf, s.appScopeA) },
      ],
      extra: {
        note: "Zoo #1: one credential, one scope, two DIFFERENT nullifiers; both proofs verify (proofB from a patched .wtns).",
        honestNullifier: hx(honestNf),
        forgedNullifier: hx(forgedNf),
      },
      make: async () => {
        const wtnsPath = path.join(PROJECT_ROOT, "build", "zoo", "fixture_forge.wtns");
        fs.mkdirSync(path.dirname(wtnsPath), { recursive: true });
        await calculateWitness("nullifier_unconstrained", await honestInput(s.appScopeA), wtnsPath);
        const pA = await proveGroth16FromWitness("nullifier_unconstrained", wtnsPath);
        await patchWitnessValue(wtnsPath, NULLIFIER_WITNESS_INDEX, forgedNf);
        const pB = await proveGroth16FromWitness("nullifier_unconstrained", wtnsPath);
        return {
          proofA: { ...hxGroth16(await groth16Calldata(pA.proof, pA.publicSignals)), snarkjs: pA },
          proofB: { ...hxGroth16(await groth16Calldata(pB.proof, pB.publicSignals)), snarkjs: pB },
        };
      },
    },
    {
      file: "zoo_age.json",
      proofs: [{ key: "", system: "groth16", circuit: "age_no_rangecheck", pub: e.credPub(honestNf, s.appScopeA) }],
      extra: {
        note: "Zoo #2: birthdate is a field element >= 2^32 (signed by a malicious issuer); the flawed comparator wraps and reports adult. Public signals are indistinguishable from an honest proof.",
        wrappedBirthdate: hx(WRAPPED_BIRTHDATE),
      },
      make: async () => {
        const bad = issueCredential(
          s,
          defaultCredentialFields(s.eddsa, { birthdate: WRAPPED_BIRTHDATE, credentialId: 555000111222n }),
          { emulateMaliciousIssuer: true },
        );
        return groth16Obj("age_no_rangecheck", loose(await witnessFor(s, bad, s.appScopeA)));
      },
    },
    {
      file: "zoo_merkle.json",
      proofs: [
        { key: "", system: "groth16", circuit: "merkle_selector_nonboolean", pub: e.credPub(attackerNf, s.appScopeA) },
      ],
      extra: {
        note: "Zoo #3: credential self-signed by an issuer key that is NOT in the trusted tree; a non-boolean Merkle selector makes the path hash to the REAL issuer root.",
      },
      make: async () => {
        const { credential, attackerLeaf } = attackerSelfSignedCredential(
          s.eddsa,
          defaultCredentialFields(s.eddsa, { credentialId: 31337000n }, ATTACKER_SUBJECT_SECRET),
        );
        const honest = s.issuerTree.proof(s.issuerIndex);
        const forged = forgeNonBooleanSelectorPath(honest, attackerLeaf);
        const input = buildCredentialInput({
          eddsa: s.eddsa,
          credential,
          subjectSecret: ATTACKER_SUBJECT_SECRET,
          issuerProof: { ...honest, leaf: attackerLeaf, ...forged },
          revocationProof: await s.revocationTree.nonMembership(credential.fields.credentialId),
          sanctioned: s.sanctioned,
          currentDate: s.currentDate,
          appScope: s.appScopeA,
          recipient: s.recipient,
        });
        return {
          ...(await groth16Obj("merkle_selector_nonboolean", loose(input))),
          attackerIssuerLeaf: hx(attackerLeaf),
          forgedSelector: hx(forged.selector),
        };
      },
    },
    {
      file: "zoo_scope.json",
      proofs: [
        { key: "proofA", system: "groth16", circuit: "nullifier_no_scope", pub: e.credPub(commitment, s.appScopeA) },
        { key: "proofB", system: "groth16", circuit: "nullifier_no_scope", pub: e.credPub(commitment, s.appScopeB) },
      ],
      extra: {
        note: "Zoo #4 (domain separation, fully constrained): two HONEST proofs for gates A and B carry the SAME nullifier, and it equals the issuer-signed subjectCommitment.",
        subjectCommitment: hx(commitment),
      },
      make: async () => ({
        proofA: await groth16Obj("nullifier_no_scope", await honestInput(s.appScopeA)),
        proofB: await groth16Obj("nullifier_no_scope", await honestInput(s.appScopeB)),
      }),
    },
    {
      file: "baseline_groth16.json",
      proofs: [{ key: "", system: "groth16", circuit: "baseline_committed_list", pub: [baselineOut, ...baselineIn] }],
      extra: { note: "Gas baseline only: a Groth16 proof with 7 public signals (see circuits/bench)." },
      make: async () => groth16Obj("baseline_committed_list", { a: baselineIn }),
    },
  ];
}

// ---------------------------------------------------------------------------
// Verification of one (committed or freshly written) fixture file
// ---------------------------------------------------------------------------

interface Stored {
  a?: string[];
  b?: string[][];
  c?: string[];
  proof?: string[] | unknown;
  pub?: string[];
  snarkjs?: { proof: unknown; publicSignals: string[] };
}

async function checkFile(spec: FixtureSpec): Promise<void> {
  const file = path.join(FIXTURES_DIR, spec.file);
  if (!fs.existsSync(file)) {
    failures.push(`missing fixture ${spec.file}`);
    return;
  }
  const doc = JSON.parse(fs.readFileSync(file, "utf8")) as Record<string, unknown>;
  for (const [k, v] of Object.entries(spec.extra)) {
    expect(jsonEqual(doc[k], v), `${spec.file}: field "${k}" differs from the regenerated value`);
  }
  for (const p of spec.proofs) {
    const where = `${spec.file}${p.key ? `.${p.key}` : ""}`;
    const obj = (p.key ? doc[p.key] : doc) as Stored | undefined;
    if (!obj?.snarkjs) {
      failures.push(`${where}: no snarkjs proof`);
      continue;
    }
    const { proof, publicSignals } = obj.snarkjs;
    expect(jsonEqual(publicSignals, dec(p.pub)), `${where}: public signals differ from the scenario's`);
    const ok =
      p.system === "groth16"
        ? await verifyGroth16(p.circuit, publicSignals, proof)
        : await verifyPlonk(p.circuit, publicSignals, proof);
    expect(ok, `${where}: committed proof does NOT verify against the current ${p.circuit} ${p.system} vkey`);
    if (p.system === "groth16") {
      const cd = hxGroth16(await groth16Calldata(proof, publicSignals));
      expect(
        jsonEqual({ a: obj.a, b: obj.b, c: obj.c, pub: obj.pub }, cd),
        `${where}: Solidity calldata does not match the committed proof`,
      );
    } else {
      const cd = await plonkCalldata(proof, publicSignals);
      expect(
        jsonEqual({ proof: obj.proof, pub: obj.pub }, { proof: hxArr(cd.proof), pub: hxArr(cd.pub) }),
        `${where}: Solidity calldata does not match the committed proof`,
      );
    }
  }
}

async function main(): Promise<void> {
  fs.mkdirSync(FIXTURES_DIR, { recursive: true });
  const e = await expected();
  const all = specs(e);

  if (!CHECK) {
    fs.writeFileSync(path.join(FIXTURES_DIR, "gate.json"), `${JSON.stringify(e.gate, null, 2)}\n`);
    for (const spec of all) {
      const content = { ...spec.extra, ...(await spec.make()) };
      fs.writeFileSync(path.join(FIXTURES_DIR, spec.file), `${JSON.stringify(content, null, 2)}\n`);
      log(`wrote ${spec.file}`);
    }
  }

  // Both modes: verify what is on disk.
  const gateFile = path.join(FIXTURES_DIR, "gate.json");
  if (!fs.existsSync(gateFile)) failures.push("missing fixture gate.json");
  else {
    const committed = JSON.parse(fs.readFileSync(gateFile, "utf8"));
    expect(jsonEqual(committed, e.gate), "gate.json differs from the regenerated deployment constants");
  }
  for (const spec of all) {
    await checkFile(spec);
    log(`${spec.file}: ${spec.proofs.length} proof(s) checked`);
  }
  const expectedFiles = new Set(["gate.json", ...all.map((s) => s.file)]);
  for (const f of fs.readdirSync(FIXTURES_DIR).filter((x) => x.endsWith(".json"))) {
    expect(expectedFiles.has(f), `unexpected fixture file ${f}`);
  }

  if (failures.length > 0) {
    for (const f of failures) log(`FAIL: ${f}`);
    process.exit(1);
  }
  const proofs = all.reduce((n, s) => n + s.proofs.length, 0);
  log(`${CHECK ? "verified" : "wrote and verified"} ${expectedFiles.size} fixture files (${proofs} proofs)`);
  // snarkjs keeps a curve thread pool alive; exit explicitly.
  process.exit(0);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
