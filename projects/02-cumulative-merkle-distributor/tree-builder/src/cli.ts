#!/usr/bin/env node
// SPDX-License-Identifier: MIT
/**
 * tree-builder CLI.
 *
 *   node src/cli.ts build --out <dir> <epoch-1.csv> [<epoch-2.csv> ...]
 *       Reads the epoch CSVs in order and writes, for every epoch N:
 *         <dir>/epoch-NNN/tree.json      StandardMerkleTree dump (load it with StandardMerkleTree.load)
 *         <dir>/epoch-NNN/proofs.json    per-account, per-token cumulative amounts and proofs
 *         <dir>/epoch-NNN/manifest.json  root, totals and input hash; keccak256 of this file is the metadataHash
 *
 *   node src/cli.ts verify <tree.json> [<proofs.json>]
 *       Re-checks every node and leaf of a tree dump and, optionally, a proofs file: exactly one entry per leaf, each
 *       with the right leaf hash and a proof that reaches the root.
 */
import { mkdirSync, readFileSync, realpathSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { parseArgs } from 'node:util';
import { parseEpochCsv } from './csv.ts';
import { buildEpochs, proofsFile, toJson, verifyProofsFile, type ProofsFile } from './cumulative.ts';
import { CumulativeMerkleTree, type StandardTreeDump } from './tree.ts';

const USAGE = `usage:
  node src/cli.ts build --out <dir> <epoch-1.csv> [<epoch-2.csv> ...]
  node src/cli.ts verify <tree.json> [<proofs.json>]`;

class UsageError extends Error {
  override name = 'UsageError';
}

/** Where the CLI writes; tests pass collectors, the binary passes the console. */
export interface Output {
  readonly log: (line: string) => void;
  readonly error: (line: string) => void;
}

const consoleOutput: Output = {
  log: (line) => {
    console.log(line);
  },
  error: (line) => {
    console.error(line);
  },
};

function build(args: string[], out: Output): void {
  const { values, positionals } = parseArgs({ args, options: { out: { type: 'string' } }, allowPositionals: true });
  if (values.out === undefined || positionals.length === 0)
    throw new UsageError('build needs --out and at least one CSV');
  const inputs = positionals.map((file) => {
    const text = readFileSync(file, 'utf8');
    return { text, rows: parseEpochCsv(text, file) };
  });
  const builds = buildEpochs(inputs);
  for (const b of builds) {
    const dir = join(resolve(values.out), `epoch-${String(b.epoch).padStart(3, '0')}`);
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, 'tree.json'), toJson(b.tree.dump()));
    writeFileSync(join(dir, 'proofs.json'), toJson(proofsFile(b)));
    writeFileSync(join(dir, 'manifest.json'), b.manifestJson);
    out.log(`epoch ${b.epoch}: ${b.tree.length} leaves, ${b.manifest.accountCount} accounts -> ${dir}`);
    out.log(`  root          ${b.tree.root}`);
    out.log(`  metadataHash  ${b.metadataHash}`);
    for (const t of b.manifest.tokens) {
      out.log(`  ${t.token}  cumulative ${t.cumulativeTotal}  (+${t.epochTotal} this epoch)`);
    }
  }
}

function verify(args: string[], out: Output): void {
  const [treeFile, proofsPath] = args;
  if (treeFile === undefined) throw new UsageError('verify needs a tree.json');
  const tree = CumulativeMerkleTree.load(JSON.parse(readFileSync(treeFile, 'utf8')) as StandardTreeDump);
  out.log(`tree ok: ${tree.length} leaves, root ${tree.root}`);
  if (proofsPath === undefined) return;

  const proofs = JSON.parse(readFileSync(proofsPath, 'utf8')) as ProofsFile;
  const checked = verifyProofsFile(tree, proofs);
  out.log(`proofs ok: ${checked} proofs verified against ${tree.root}, one per leaf`);
}

/** Runs one CLI command and returns the process exit code. */
export function runCli(argv: readonly string[], out: Output = consoleOutput): number {
  const [command, ...rest] = argv;
  try {
    if (command === 'build') build(rest, out);
    else if (command === 'verify') verify(rest, out);
    else if (command === 'help' || command === '--help' || command === undefined) out.log(USAGE);
    else throw new UsageError(`unknown command "${command}"`);
    return 0;
  } catch (err) {
    out.error(`error: ${err instanceof Error ? err.message : String(err)}`);
    if (err instanceof UsageError) out.error(USAGE);
    return 1;
  }
}

/**
 * True when the module at `moduleUrl` is the script Node was started with. Node turns its entry point into
 * `pathToFileURL(realpathSync(path.resolve(argv[1])))`, and `process.argv[1]` is already absolute, so this is the
 * test `import.meta.main` performs, on every Node 24 release: `import.meta.main` only exists from 24.2, and on 24.0
 * and 24.1 the CLI would silently do nothing.
 */
export function isEntryPoint(argv1: string | undefined, moduleUrl: string): boolean {
  if (argv1 === undefined) return false;
  try {
    return pathToFileURL(realpathSync(argv1)).href === moduleUrl;
  } catch {
    return false;
  }
}

if (isEntryPoint(process.argv[1], import.meta.url)) process.exitCode = runCli(process.argv.slice(2));
