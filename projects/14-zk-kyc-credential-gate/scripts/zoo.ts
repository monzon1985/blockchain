// SPDX-License-Identifier: MIT
//
// The bug zoo, demonstrated end to end with real Groth16 proofs.
//
//   #1 nullifier assigned with `<--`         forged proof (patched .wtns)
//   #2 birthdate without Num2Bits             forged proof (field-wrapped value)
//   #3 Merkle selector not boolean            forged proof (untrusted issuer key)
//   #4 nullifier without appScope             honest proofs, wrong statement
//
// For each entry the flawed circuit's proof verifies against its own flawed
// verification key, and the production circuit refuses the same attack.
// Bug #1 also runs a like-for-like `snarkjs wtns check` differential. The two
// layouts differ by exactly one wire (the flawed `<--` keeps nf.out apart from
// the output), but index 1 is the nullifier in both, so the same patch
// (index 1) is applied to each circuit's own honest witness; the patched
// witness passes the flawed r1cs and fails the production r1cs, and both
// unpatched witnesses pass (control).
//
// Exits non-zero if any expected outcome does not hold.
import * as fs from "node:fs";
import * as path from "node:path";
import { wtns } from "snarkjs";
import {
  buildScenario,
  defaultCredentialFields,
  issueCredential,
  witnessFor,
  DEV_SUBJECT_SECRET,
  type Scenario,
} from "../src/lib/scenario.ts";
import { FIELD_MODULUS, stringifyInputs } from "../src/lib/field.ts";
import { nullifier } from "../src/lib/crypto.ts";
import { buildCredentialInput, type CredentialCircuitInput } from "../src/lib/inputs.ts";
import { proveGroth16, verifyGroth16 } from "../src/lib/prove.ts";
import {
  calculateWitness,
  checkWitness,
  patchWitnessValue,
  proveGroth16FromWitness,
  r1csWireCount,
  readWitnessValue,
  witnessLength,
} from "../src/lib/witness_patch.ts";
import {
  ATTACKER_SUBJECT_SECRET,
  NULLIFIER_WITNESS_INDEX,
  WRAPPED_BIRTHDATE,
  attackerSelfSignedCredential,
  forgeNonBooleanSelectorPath,
} from "../src/lib/zoo_attacks.ts";
import { artifactPaths, PROJECT_ROOT } from "../src/lib/artifacts.ts";

interface Check {
  bug: string;
  claim: string;
  ok: boolean;
}
const checks: Check[] = [];
function record(bug: string, claim: string, ok: boolean): void {
  checks.push({ bug, claim, ok });
  process.stdout.write(`  ${ok ? "PASS" : "FAIL"}  ${bug}: ${claim}\n`);
}

const SCRATCH = path.join(PROJECT_ROOT, "build", "zoo");
type Loose = Record<string, bigint | bigint[]>;
const loose = (i: CredentialCircuitInput): Loose => i as unknown as Loose;

/** Compute a production witness; return the failure message (or undefined if it succeeded). */
async function productionFailure(input: CredentialCircuitInput): Promise<string | undefined> {
  const out = path.join(SCRATCH, "production_reject.wtns");
  try {
    await wtns.calculate(stringifyInputs(loose(input)), artifactPaths("credential").wasm, out);
    return undefined;
  } catch (err) {
    return err instanceof Error ? err.message : String(err);
  }
}

function rejectedIn(msg: string | undefined, template: string): boolean {
  return msg !== undefined && msg.includes("Assert Failed") && msg.includes(`Error in template ${template}`);
}

async function bug1UnconstrainedNullifier(s: Scenario): Promise<void> {
  process.stdout.write("\n[zoo] #1 under-constrained nullifier (`<--`)\n");
  const cred = issueCredential(s, defaultCredentialFields(s.eddsa));
  const input = await witnessFor(s, cred, s.appScopeA);
  const flawed = artifactPaths("nullifier_unconstrained");
  const prod = artifactPaths("credential");

  const flawedWires = await r1csWireCount(flawed.r1cs);
  const prodWires = await r1csWireCount(prod.r1cs);
  record("#1", `flawed r1cs has exactly one more wire than production (${flawedWires} vs ${prodWires})`, flawedWires === prodWires + 1);

  const fz = path.join(SCRATCH, "n1_flawed.wtns");
  const fp = path.join(SCRATCH, "n1_production.wtns");
  await calculateWitness("nullifier_unconstrained", loose(input), fz);
  await calculateWitness("credential", loose(input), fp);
  record(
    "#1",
    "each witness has its own r1cs's layout",
    (await witnessLength(fz)) === flawedWires && (await witnessLength(fp)) === prodWires,
  );

  const honestNull = nullifier(s.eddsa, DEV_SUBJECT_SECRET, s.appScopeA);
  record(
    "#1",
    "witness index 1 is the nullifier in BOTH layouts",
    (await readWitnessValue(fz, NULLIFIER_WITNESS_INDEX)) === honestNull &&
      (await readWitnessValue(fp, NULLIFIER_WITNESS_INDEX)) === honestNull,
  );

  const controlFlawed = await checkWitness(flawed.r1cs, fz);
  const controlProd = await checkWitness(prod.r1cs, fp);
  record("#1", "control: both UNPATCHED witnesses pass `wtns check`", controlFlawed.ok && controlProd.ok);

  const honestProof = await proveGroth16FromWitness("nullifier_unconstrained", fz);
  record(
    "#1",
    "honest proof verifies on the flawed verifier",
    await verifyGroth16("nullifier_unconstrained", honestProof.publicSignals, honestProof.proof),
  );

  // Same patch on both: overwrite the nullifier with an arbitrary value.
  const forged = (honestNull + 987654321n) % FIELD_MODULUS;
  await patchWitnessValue(fz, NULLIFIER_WITNESS_INDEX, forged);
  await patchWitnessValue(fp, NULLIFIER_WITNESS_INDEX, forged);

  const flawedPatched = await checkWitness(flawed.r1cs, fz);
  record("#1", "`wtns check` PASSES the patched witness on the flawed r1cs", flawedPatched.ok);
  const prodPatched = await checkWitness(prod.r1cs, fp);
  record(
    "#1",
    "`wtns check` FAILS the same patch on the production r1cs",
    !prodPatched.ok && prodPatched.log.some((l) => l.includes("aborting checking process at constraint")),
  );

  const forgedProof = await proveGroth16FromWitness("nullifier_unconstrained", fz);
  record(
    "#1",
    "FORGED proof (same credential, different nullifier) verifies on the flawed verifier",
    (await verifyGroth16("nullifier_unconstrained", forgedProof.publicSignals, forgedProof.proof)) &&
      forgedProof.publicSignals[0] === forged.toString(),
  );
}

async function bug2AgeFieldWrap(s: Scenario): Promise<void> {
  process.stdout.write("\n[zoo] #2 missing range check (field-wrapped birthdate)\n");
  record("#2", "attacker birthdate is >= 2^32 (not a date)", WRAPPED_BIRTHDATE >= 1n << 32n);
  // Precondition: an issuer that signs a non-date (the CLI's policy refuses).
  const badCred = issueCredential(
    s,
    defaultCredentialFields(s.eddsa, { birthdate: WRAPPED_BIRTHDATE, credentialId: 999000111n }),
    { emulateMaliciousIssuer: true },
  );
  const badInput = await witnessFor(s, badCred, s.appScopeA);
  const proof = await proveGroth16("age_no_rangecheck", loose(badInput));
  record(
    "#2",
    "FORGED proof verifies on the flawed age verifier",
    await verifyGroth16("age_no_rangecheck", proof.publicSignals, proof.proof),
  );
  const msg = await productionFailure(badInput);
  record(
    "#2",
    "production witness generation fails in AgeAtLeast18's Num2Bits guard",
    rejectedIn(msg, "AgeAtLeast18") && rejectedIn(msg, "Num2Bits"),
  );
}

async function bug3MerkleSelector(s: Scenario): Promise<void> {
  process.stdout.write("\n[zoo] #3 non-boolean Merkle selector (untrusted issuer)\n");
  const { credential, attackerLeaf } = attackerSelfSignedCredential(
    s.eddsa,
    defaultCredentialFields(s.eddsa, { credentialId: 31337000n }, ATTACKER_SUBJECT_SECRET),
  );
  const honest = s.issuerTree.proof(s.issuerIndex);
  let trusted = false;
  for (let i = 0; i <= s.issuerIndex; i++) trusted ||= s.issuerTree.proof(i).leaf === attackerLeaf;
  record("#3", "attacker's issuer key is NOT in the trusted tree", !trusted);

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
  record("#3", "forged path uses a non-boolean selector", forged.selector > 1n);
  const proof = await proveGroth16("merkle_selector_nonboolean", loose(input));
  record(
    "#3",
    "FORGED proof verifies on the flawed verifier against the REAL issuer root",
    (await verifyGroth16("merkle_selector_nonboolean", proof.publicSignals, proof.proof)) &&
      proof.publicSignals[2] === honest.root.toString(),
  );
  const msg = await productionFailure(input);
  record("#3", "production witness generation fails in MerkleInclusionProof", rejectedIn(msg, "MerkleInclusionProof"));
}

async function bug4NullifierNoScope(s: Scenario): Promise<void> {
  process.stdout.write("\n[zoo] #4 nullifier not bound to appScope (domain separation, fully constrained)\n");
  const cred = issueCredential(s, defaultCredentialFields(s.eddsa));
  const inA = await witnessFor(s, cred, s.appScopeA);
  const inB = await witnessFor(s, cred, s.appScopeB);
  const a = await proveGroth16("nullifier_no_scope", loose(inA));
  const b = await proveGroth16("nullifier_no_scope", loose(inB));
  record(
    "#4",
    "both HONEST proofs verify on the flawed verifier",
    (await verifyGroth16("nullifier_no_scope", a.publicSignals, a.proof)) &&
      (await verifyGroth16("nullifier_no_scope", b.publicSignals, b.proof)),
  );
  record("#4", "SAME nullifier at two different scopes (cross-app linkage)", a.publicSignals[0] === b.publicSignals[0]);
  record(
    "#4",
    "the nullifier IS the issuer-signed subjectCommitment (issuer de-anonymisation)",
    a.publicSignals[0] === cred.fields.subjectCommitment.toString(),
  );
  const pa = nullifier(s.eddsa, DEV_SUBJECT_SECRET, s.appScopeA);
  const pb = nullifier(s.eddsa, DEV_SUBJECT_SECRET, s.appScopeB);
  record(
    "#4",
    "production nullifiers differ across scopes and from the commitment",
    pa !== pb && pa !== cred.fields.subjectCommitment,
  );
}

async function main(): Promise<void> {
  process.stdout.write("=== ZK KYC credential gate: bug zoo ===\n");
  fs.mkdirSync(SCRATCH, { recursive: true });
  const s = await buildScenario();
  await bug1UnconstrainedNullifier(s);
  await bug2AgeFieldWrap(s);
  await bug3MerkleSelector(s);
  await bug4NullifierNoScope(s);

  const failed = checks.filter((c) => !c.ok);
  process.stdout.write(`\n[zoo] ${checks.length - failed.length}/${checks.length} checks passed\n`);
  // snarkjs leaves a curve thread pool alive; exit explicitly so the gate does
  // not hang waiting for the event loop to drain.
  process.exit(failed.length > 0 ? 1 : 0);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
