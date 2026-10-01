// SPDX-License-Identifier: MIT
//
// Holder CLI: generate the subject secret LOCALLY and print only its
// commitment, which is what the holder hands to the issuer. The secret never
// leaves this machine and is never passed on a command line.
//
//   node src/cli/holder.ts commit --out holder.json
import { getEddsa } from "../lib/crypto.ts";
import { generateSubjectSecret, subjectCommitment } from "../lib/holder.ts";
import { type HolderFile } from "../lib/files.ts";
import { parseFlags, required, runCli, writeSecretJson } from "./args.ts";

async function main(): Promise<void> {
  const [cmd, ...rest] = process.argv.slice(2);
  if (cmd !== "commit") {
    throw new Error("usage: holder commit --out <holder.json>");
  }
  const flags = parseFlags(rest, ["out"]);
  const out = required(flags, "out");
  const eddsa = await getEddsa();
  const secret = generateSubjectSecret();
  const c = subjectCommitment(eddsa, secret);
  const file: HolderFile = { subjectSecret: `0x${secret.toString(16)}`, subjectCommitment: c.toString() };
  writeSecretJson(out, file);
  console.log(JSON.stringify({ subjectCommitment: c.toString(), secretFile: out }, null, 2));
}

runCli(main);
