// SPDX-License-Identifier: MIT
//
// World CLI: the governor's view of the PUBLIC state (trusted issuers,
// revoked credential ids, sanctioned list, reference date) and the roots to
// publish on-chain. Provers use the same file to rebuild their Merkle paths.
//
//   node src/cli/world.ts init --issuer-key-file issuer.key.json --date 20260929 --out world.json
//   node src/cli/world.ts revoke --world world.json --cid 42
//   node src/cli/world.ts roots --world world.json
import { getEddsa } from "../lib/crypto.ts";
import { buildWorld, type WorldFile } from "../lib/world.ts";
import { REVOKED_SENTINEL, isValidYyyymmdd } from "../lib/issuer.ts";
import { SANCTIONED_COUNTRIES } from "../lib/scenario.ts";
import { bigintFlag, parseFlags, readJson, required, runCli, writeJson } from "./args.ts";
import { type IssuerKeyFile } from "../lib/files.ts";

async function printRoots(file: WorldFile): Promise<void> {
  const eddsa = await getEddsa();
  const world = await buildWorld(eddsa, file);
  console.log(
    JSON.stringify(
      {
        issuerRoot: world.issuerTree.root().toString(),
        revocationRoot: world.revocationTree.root().toString(),
        currentDate: world.currentDate.toString(),
        sanctioned: world.sanctioned.map((s) => s.toString()),
      },
      null,
      2,
    ),
  );
}

async function main(): Promise<void> {
  const [cmd, ...rest] = process.argv.slice(2);

  if (cmd === "init") {
    const flags = parseFlags(rest, ["issuer-key-file", "date", "out"]);
    const key = readJson<IssuerKeyFile>(required(flags, "issuer-key-file"));
    const date = bigintFlag(flags, "date");
    if (!isValidYyyymmdd(date)) throw new Error(`--date ${date} is not a valid YYYYMMDD date`);
    const file: WorldFile = {
      // Two public decoy leaves keep the demo tree non-trivial.
      issuers: [
        { ax: "1", ay: "2" },
        { ax: "3", ay: "4" },
        { ax: key.ax, ay: key.ay },
      ],
      revoked: [REVOKED_SENTINEL.toString()],
      sanctioned: SANCTIONED_COUNTRIES.map((s) => s.toString()),
      currentDate: date.toString(),
    };
    writeJson(required(flags, "out"), file);
    await printRoots(file);
    return;
  }

  if (cmd === "revoke") {
    const flags = parseFlags(rest, ["world", "cid"]);
    const path = required(flags, "world");
    const file = readJson<WorldFile>(path);
    const cid = bigintFlag(flags, "cid");
    if (!file.revoked.includes(cid.toString())) file.revoked.push(cid.toString());
    writeJson(path, file);
    await printRoots(file);
    return;
  }

  if (cmd === "roots") {
    const flags = parseFlags(rest, ["world"]);
    await printRoots(readJson<WorldFile>(required(flags, "world")));
    return;
  }

  throw new Error("usage: world init|revoke|roots [--flags]");
}

runCli(main);
