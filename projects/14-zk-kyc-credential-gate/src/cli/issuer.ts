// SPDX-License-Identifier: MIT
//
// Issuer CLI: generate a BabyJubJub EdDSA issuer key and sign KYC credentials.
//
//   node src/cli/issuer.ts keygen --out issuer.key.json
//   node src/cli/issuer.ts sign --key-file issuer.key.json \
//        --commitment <Poseidon(secret) from `holder commit`> \
//        --birthdate 19900215 --country 724 --accredited 1 --expiry 20301231 \
//        --cid 987654321 --out credential.json
//
// The signing seed is read from --key-file or the ISSUER_SEED environment
// variable, never from the command line (argv leaks into shell history and
// process listings). The issuer signs the holder's COMMITMENT and never sees
// the holder's secret. Malformed fields (non-dates, non-boolean accredited,
// the revoked sentinel id, ...) are refused.
import { randomBytes } from "node:crypto";
import { getEddsa, issuerLeaf } from "../lib/crypto.ts";
import { issuerKeyFromSeed, signCredential } from "../lib/issuer.ts";
import { credentialToFile, type IssuerKeyFile } from "../lib/files.ts";
import { bigintFlag, parseFlags, readJson, required, runCli, writeJson, writeSecretJson } from "./args.ts";

function seedFromHex(hex: string): Uint8Array {
  const clean = hex.startsWith("0x") ? hex.slice(2) : hex;
  if (!/^[0-9a-fA-F]{64}$/.test(clean)) throw new Error("seed must be 32 bytes (64 hex chars)");
  return Uint8Array.from(Buffer.from(clean, "hex"));
}

function loadSeed(keyFile: string | undefined): Uint8Array {
  if (keyFile) return seedFromHex(readJson<IssuerKeyFile>(keyFile).seed);
  const env = process.env.ISSUER_SEED;
  if (env) return seedFromHex(env);
  throw new Error("provide the issuer seed via --key-file <file> or the ISSUER_SEED environment variable");
}

async function main(): Promise<void> {
  const [cmd, ...rest] = process.argv.slice(2);
  const eddsa = await getEddsa();

  if (cmd === "keygen") {
    const flags = parseFlags(rest, ["out"]);
    const out = required(flags, "out");
    const seed = new Uint8Array(randomBytes(32));
    const key = issuerKeyFromSeed(eddsa, seed);
    const leaf = issuerLeaf(eddsa, key.ax, key.ay);
    const file: IssuerKeyFile = {
      seed: `0x${Buffer.from(seed).toString("hex")}`,
      ax: key.ax.toString(),
      ay: key.ay.toString(),
      issuerLeaf: leaf.toString(),
    };
    writeSecretJson(out, file);
    // Print only the PUBLIC half.
    console.log(JSON.stringify({ ax: file.ax, ay: file.ay, issuerLeaf: file.issuerLeaf, keyFile: out }, null, 2));
    return;
  }

  if (cmd === "sign") {
    if (rest.includes("--seed")) {
      throw new Error("--seed is not accepted: pass the seed via --key-file or ISSUER_SEED, never on the command line");
    }
    const flags = parseFlags(rest, [
      "key-file",
      "commitment",
      "birthdate",
      "country",
      "accredited",
      "expiry",
      "cid",
      "out",
    ]);
    const key = issuerKeyFromSeed(eddsa, loadSeed(flags.get("key-file")));
    // signCredential enforces the issuer policy (credentialFieldViolations).
    const signed = signCredential(eddsa, key, {
      subjectCommitment: bigintFlag(flags, "commitment"),
      birthdate: bigintFlag(flags, "birthdate"),
      countryCode: bigintFlag(flags, "country"),
      accredited: bigintFlag(flags, "accredited"),
      expiry: bigintFlag(flags, "expiry"),
      credentialId: bigintFlag(flags, "cid"),
    });
    const file = credentialToFile(signed);
    const out = flags.get("out");
    if (out) writeJson(out, file);
    console.log(JSON.stringify(file, null, 2));
    return;
  }

  throw new Error("usage: issuer keygen --out <file> | issuer sign --key-file <file> --commitment <c> ...");
}

runCli(main);
