// SPDX-License-Identifier: MIT
//
// Deterministic local trusted setup for dev/CI.
//
//  Phase 1 (universal):  newAccumulator -> beacon -> preparePhase2, at 2^16.
//  Phase 2 (per circuit, Groth16): newZKey -> beacon.
//  PLONK (production only): plonk.setup (uses the phase-1 ptau directly).
//
// Every step is a pure function of public inputs: there is NO `contribute()`
// call, because snarkjs' contribute mixes 64 bytes of OS randomness into the
// supplied entropy (misc.getRandomRng), which made earlier versions of this
// script produce a different tau, different keys and different verifiers on
// every fresh clone. A beacon contribution derives its key only from the
// public beacon hash and the transcript, so the ceremony is reproducible
// byte for byte. Its "toxic waste" is therefore PUBLIC: NOT production-secure.
//
//   node scripts/setup-dev.mjs          build (or reuse cached) keys and write
//                                       contracts/generated/*.sol + PROVENANCE.json
//   node scripts/setup-dev.mjs --check  build (or reuse cached) keys and FAIL if
//                                       any regenerated verifier or provenance
//                                       record differs from the committed one
//
// Cached zkeys under build/keys are reused only when a sidecar records the
// exact r1cs + ptau hashes they were derived from, so a changed circuit can
// never silently reuse a stale key.
import * as fs from "node:fs";
import * as path from "node:path";
import { createHash } from "node:crypto";
import { powersOfTau, zKey, plonk } from "snarkjs";
import { getCurveFromName } from "ffjavascript";
import { CIRCUITS, DIRS, PTAU_POWER, CEREMONY, circuitPaths, PROVENANCE_FILE } from "./config.mjs";

const CHECK = process.argv.includes("--check");

function log(msg) {
  process.stdout.write(`[setup:dev${CHECK ? ":check" : ""}] ${msg}\n`);
}

/** Minimal snarkjs logger: surfaces info/warn/error, drops the per-chunk debug noise. */
const snarkLogger = {
  info: (m) => log(`  snarkjs: ${m}`),
  warn: (m) => log(`  snarkjs WARN: ${m}`),
  error: (m) => log(`  snarkjs ERROR: ${m}`),
  debug: () => {},
};

function sha256File(file) {
  return createHash("sha256").update(fs.readFileSync(file)).digest("hex");
}
function sha256Text(text) {
  return createHash("sha256").update(text).digest("hex");
}

const PTAU_FINAL = path.join(DIRS.ptau, `pot${PTAU_POWER}_final.ptau`);
const ROOT_PKG = JSON.parse(fs.readFileSync(path.join(DIRS.circuits, "..", "package.json"), "utf8"));
const SNARKJS_VERSION = JSON.parse(
  fs.readFileSync(path.join(DIRS.circuits, "..", "node_modules", "snarkjs", "package.json"), "utf8"),
).version;

async function buildPtau(curve) {
  if (fs.existsSync(PTAU_FINAL)) {
    log(`ptau cached: ${path.basename(PTAU_FINAL)}`);
    return;
  }
  const p0 = path.join(DIRS.ptau, "pot_0000.ptau");
  const pb = path.join(DIRS.ptau, "pot_beacon.ptau");
  const tmpFinal = `${PTAU_FINAL}.partial`;

  log(`phase 1: new accumulator 2^${PTAU_POWER}`);
  await powersOfTau.newAccumulator(curve, PTAU_POWER, p0);
  log("phase 1: deterministic beacon contribution");
  await powersOfTau.beacon(p0, pb, CEREMONY.ptauBeaconName, CEREMONY.ptauBeaconHash, CEREMONY.beaconIterExp);
  log("phase 1: prepare phase 2");
  await powersOfTau.preparePhase2(pb, tmpFinal);
  // Rename only once complete so an interrupted run never leaves a truncated
  // file that a later run would mistake for a finished ceremony.
  fs.renameSync(tmpFinal, PTAU_FINAL);

  for (const f of [p0, pb]) fs.rmSync(f, { force: true });
  log(`phase 1 done: ${path.basename(PTAU_FINAL)}`);
}

/** Reuse a cached zkey only if its sidecar matches the current r1cs + ptau. */
function cachedKeyIsFresh(zkeyFile, inputs) {
  const sidecar = `${zkeyFile}.inputs.json`;
  if (!fs.existsSync(zkeyFile) || !fs.existsSync(sidecar)) return false;
  try {
    const recorded = JSON.parse(fs.readFileSync(sidecar, "utf8"));
    return recorded.r1csSha256 === inputs.r1csSha256 && recorded.ptauSha256 === inputs.ptauSha256;
  } catch {
    return false;
  }
}

function writeSidecar(zkeyFile, inputs) {
  fs.writeFileSync(`${zkeyFile}.inputs.json`, `${JSON.stringify(inputs, null, 2)}\n`);
}

async function groth16Setup(circuit, inputs) {
  const p = circuitPaths(circuit.name);
  if (cachedKeyIsFresh(p.groth16Zkey, inputs)) {
    log(`groth16 cached: ${circuit.name}`);
  } else {
    const zkey0 = path.join(DIRS.keys, `${circuit.name}.groth16.0.zkey`);
    log(`groth16 setup: ${circuit.name}`);
    fs.rmSync(p.groth16Zkey, { force: true });
    await zKey.newZKey(p.r1cs, PTAU_FINAL, zkey0, snarkLogger);
    await zKey.beacon(
      zkey0,
      p.groth16Zkey,
      CEREMONY.zkeyBeaconName,
      CEREMONY.zkeyBeaconHash,
      CEREMONY.beaconIterExp,
    );
    fs.rmSync(zkey0, { force: true });
    writeSidecar(p.groth16Zkey, inputs);
  }
  const vkey = await zKey.exportVerificationKey(p.groth16Zkey);
  fs.writeFileSync(p.groth16Vkey, `${JSON.stringify(vkey, null, 2)}\n`);
  return { vkeyFile: p.groth16Vkey, zkeyFile: p.groth16Zkey };
}

async function plonkSetup(circuit, inputs) {
  const p = circuitPaths(circuit.name);
  if (cachedKeyIsFresh(p.plonkZkey, inputs)) {
    log(`plonk cached: ${circuit.name}`);
  } else {
    log(`plonk setup: ${circuit.name}`);
    fs.rmSync(p.plonkZkey, { force: true });
    await plonk.setup(p.r1cs, PTAU_FINAL, p.plonkZkey, snarkLogger);
    writeSidecar(p.plonkZkey, inputs);
  }
  const vkey = await zKey.exportVerificationKey(p.plonkZkey);
  fs.writeFileSync(p.plonkVkey, `${JSON.stringify(vkey, null, 2)}\n`);
  return { vkeyFile: p.plonkVkey, zkeyFile: p.plonkZkey };
}

/** Render the Solidity verifier (renamed per circuit) without writing it. */
async function renderVerifier(circuit, templates, system, zkeyFile) {
  const sol = await zKey.exportSolidityVerifier(zkeyFile, templates);
  // snarkjs emits a contract literally named `Groth16Verifier` / `PlonkVerifier`.
  // Rename it to a per-circuit name so multiple verifiers coexist in one build.
  const emitted = system === "groth16" ? "Groth16Verifier" : "PlonkVerifier";
  const suffix = system === "groth16" ? "" : "Plonk";
  const targetName = `${circuit.verifierName}${suffix}`;
  const source = sol.replace(new RegExp(`contract\\s+${emitted}\\b`), `contract ${targetName}`);
  if (!source.includes(`contract ${targetName}`)) {
    throw new Error(`could not rename ${emitted} to ${targetName}`);
  }
  return { file: path.join(DIRS.verifiers, `${targetName}.sol`), targetName, source };
}

async function main() {
  fs.mkdirSync(DIRS.keys, { recursive: true });
  fs.mkdirSync(DIRS.ptau, { recursive: true });
  fs.mkdirSync(DIRS.verifiers, { recursive: true });

  const templates = {
    groth16: fs.readFileSync(
      path.join(DIRS.circuits, "..", "node_modules", "snarkjs", "templates", "verifier_groth16.sol.ejs"),
      "utf8",
    ),
    plonk: fs.readFileSync(
      path.join(DIRS.circuits, "..", "node_modules", "snarkjs", "templates", "verifier_plonk.sol.ejs"),
      "utf8",
    ),
  };

  const curve = await getCurveFromName("bn128");
  await buildPtau(curve);
  const ptauSha256 = sha256File(PTAU_FINAL);

  const provenance = {
    note:
      "DETERMINISTIC DEV CEREMONY - NOT PRODUCTION SECURE. Phase 1 is a single public beacon " +
      "(no secret contribution), so the toxic waste is derivable by anyone. Regenerate with " +
      "`npm run setup:dev`; `npm run setup:dev -- --check` fails if a fresh run differs from this file.",
    package: `${ROOT_PKG.name}@${ROOT_PKG.version}`,
    snarkjs: SNARKJS_VERSION,
    ptauPower: PTAU_POWER,
    ceremony: CEREMONY,
    ptauFinalSha256: ptauSha256,
    circuits: {},
  };

  const rendered = [];
  for (const circuit of CIRCUITS) {
    const p = circuitPaths(circuit.name);
    if (!fs.existsSync(p.r1cs)) {
      throw new Error(`missing ${p.r1cs}; run \`npm run circuits:build\` first`);
    }
    const inputs = { r1csSha256: sha256File(p.r1cs), ptauSha256 };
    const entry = { kind: circuit.kind, r1csSha256: inputs.r1csSha256, groth16: null, plonk: null };

    const g = await groth16Setup(circuit, inputs);
    const gv = await renderVerifier(circuit, templates, "groth16", g.zkeyFile);
    rendered.push(gv);
    entry.groth16 = {
      zkeySha256: sha256File(g.zkeyFile),
      vkeySha256: sha256File(g.vkeyFile),
      verifier: path.basename(gv.file),
      verifierContract: gv.targetName,
      verifierSha256: sha256Text(gv.source),
    };

    if (circuit.plonk) {
      const pl = await plonkSetup(circuit, inputs);
      const pv = await renderVerifier(circuit, templates, "plonk", pl.zkeyFile);
      rendered.push(pv);
      entry.plonk = {
        zkeySha256: sha256File(pl.zkeyFile),
        vkeySha256: sha256File(pl.vkeyFile),
        verifier: path.basename(pv.file),
        verifierContract: pv.targetName,
        verifierSha256: sha256Text(pv.source),
      };
    }
    provenance.circuits[circuit.name] = entry;
  }
  const provenanceText = `${JSON.stringify(provenance, null, 2)}\n`;

  if (CHECK) {
    const mismatches = [];
    for (const v of rendered) {
      if (!fs.existsSync(v.file)) {
        mismatches.push(`missing committed verifier ${path.relative(DIRS.verifiers, v.file)}`);
      } else if (fs.readFileSync(v.file, "utf8") !== v.source) {
        mismatches.push(`regenerated ${path.basename(v.file)} differs from the committed file`);
      }
    }
    const committed = fs.existsSync(PROVENANCE_FILE) ? fs.readFileSync(PROVENANCE_FILE, "utf8") : "";
    if (committed !== provenanceText) {
      mismatches.push(`regenerated PROVENANCE.json differs from the committed ${path.basename(PROVENANCE_FILE)}`);
      fs.writeFileSync(path.join(DIRS.keys, "PROVENANCE.regenerated.json"), provenanceText);
      mismatches.push(`  (fresh copy written to ${path.relative(DIRS.build, DIRS.keys)}/PROVENANCE.regenerated.json)`);
    }
    if (mismatches.length > 0) {
      for (const m of mismatches) log(`FAIL: ${m}`);
      throw new Error("trusted setup is not reproducible from the committed artifacts");
    }
    log(`reproducible: ${rendered.length} verifiers and PROVENANCE.json match byte for byte`);
  } else {
    for (const v of rendered) fs.writeFileSync(v.file, v.source);
    fs.writeFileSync(PROVENANCE_FILE, provenanceText);
    log(`wrote ${rendered.length} verifiers and ${path.basename(PROVENANCE_FILE)}`);
  }

  if (typeof curve.terminate === "function") {
    await curve.terminate();
  }
  log("done");
}

main().then(
  () => process.exit(0),
  (err) => {
    console.error(err instanceof Error ? err.message : err);
    process.exit(1);
  },
);
