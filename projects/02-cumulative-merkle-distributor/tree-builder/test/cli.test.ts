// SPDX-License-Identifier: MIT
import { StandardMerkleTree } from '@openzeppelin/merkle-tree';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { getAddress, keccak256, stringToBytes } from 'viem';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { isEntryPoint, runCli, type Output } from '../src/cli.ts';
import { leafHash } from '../src/tree.ts';
import type { Manifest, ProofsFile } from '../src/cumulative.ts';

const ROOT = resolve(import.meta.dirname, '..');
const EXAMPLES = ['epoch-1.csv', 'epoch-2.csv', 'epoch-3.csv'].map((f) => join(ROOT, 'examples/epochs', f));

function capture(): Output & { lines: string[]; errors: string[] } {
  const lines: string[] = [];
  const errors: string[] = [];
  return { lines, errors, log: (l) => lines.push(l), error: (l) => errors.push(l) };
}

describe('tree-builder CLI', () => {
  let dir: string;
  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), 'tree-builder-'));
  });
  afterEach(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  it('build writes tree, proofs and manifest per epoch, loadable by StandardMerkleTree', () => {
    const out = capture();
    expect(runCli(['build', '--out', dir, ...EXAMPLES], out)).toBe(0);
    expect(readdirSync(dir).sort()).toEqual(['epoch-001', 'epoch-002', 'epoch-003']);

    let previousRoot: string | null = null;
    for (const epoch of ['epoch-001', 'epoch-002', 'epoch-003']) {
      const treeJson = readFileSync(join(dir, epoch, 'tree.json'), 'utf8');
      const oz = StandardMerkleTree.load(JSON.parse(treeJson) as Parameters<typeof StandardMerkleTree.load>[0]);
      const proofs = JSON.parse(readFileSync(join(dir, epoch, 'proofs.json'), 'utf8')) as ProofsFile;
      const manifestJson = readFileSync(join(dir, epoch, 'manifest.json'), 'utf8');
      const manifest = JSON.parse(manifestJson) as Manifest;

      expect(proofs.root).toBe(oz.root);
      expect(manifest.root).toBe(oz.root);
      expect(manifest.previousRoot).toBe(previousRoot);
      expect(out.lines.join('\n')).toContain(keccak256(stringToBytes(manifestJson)));
      for (const [i, value] of oz.entries()) {
        const [account, token, amount] = value as [string, string, string];
        const entry = proofs.claims[account as `0x${string}`]?.[token as `0x${string}`];
        expect(entry?.cumulativeAmount).toBe(amount);
        expect(entry?.proof).toEqual(oz.getProof(i));
      }
      expect(runCli(['verify', join(dir, epoch, 'tree.json'), join(dir, epoch, 'proofs.json')], out)).toBe(0);
      previousRoot = oz.root;
    }
    expect(out.errors).toEqual([]);
    expect(out.lines.some((l) => l.startsWith('proofs ok: 8 proofs verified'))).toBe(true);
  });

  it('verify rejects a tampered proof and a proofs file for another root', () => {
    const out = capture();
    expect(runCli(['build', '--out', dir, ...EXAMPLES], out)).toBe(0);
    const proofsPath = join(dir, 'epoch-002', 'proofs.json');
    const proofs = JSON.parse(readFileSync(proofsPath, 'utf8')) as {
      claims: Record<string, Record<string, { proof: string[] }>>;
    };
    const first = Object.values(Object.values(proofs.claims)[0]!)[0]!;
    first.proof[0] = '0x' + '00'.repeat(32);
    writeFileSync(proofsPath, JSON.stringify(proofs));
    expect(runCli(['verify', join(dir, 'epoch-002', 'tree.json'), proofsPath], out)).toBe(1);
    expect(out.errors.join('\n')).toMatch(/invalid proof/);

    expect(runCli(['verify', join(dir, 'epoch-001', 'tree.json'), join(dir, 'epoch-003', 'proofs.json')], out)).toBe(1);
    expect(out.errors.join('\n')).toMatch(/!= tree root/);

    const partial = JSON.parse(readFileSync(join(dir, 'epoch-003', 'proofs.json'), 'utf8')) as ProofsFile;
    const trimmed = { ...partial, claims: Object.fromEntries(Object.entries(partial.claims).slice(1)) };
    writeFileSync(join(dir, 'partial.json'), JSON.stringify(trimmed));
    expect(runCli(['verify', join(dir, 'epoch-003', 'tree.json'), join(dir, 'partial.json')], out)).toBe(1);
    // The first account holds two tokens: both of its leaves are reported missing, by name.
    const [removed, removedTokens] = Object.entries(partial.claims)[0]!;
    const missing = Object.keys(removedTokens).map((token) => `${removed} / ${token}`);
    expect(missing).toHaveLength(2);
    expect(out.errors.at(-1)).toBe(`error: proofs cover 6 of 8 leaves; missing ${missing.join(', ')}`);
  });

  it('verify counts leaves, not entries: a re-cased duplicate cannot stand in for a missing entry', () => {
    const out = capture();
    expect(runCli(['build', '--out', dir, ...EXAMPLES], out)).toBe(0);
    const treePath = join(dir, 'epoch-003', 'tree.json');
    type Claims = Record<string, Record<string, { cumulativeAmount: string; leaf: string; proof: string[] }>>;
    const proofs = JSON.parse(readFileSync(join(dir, 'epoch-003', 'proofs.json'), 'utf8')) as { claims: Claims };
    const firstEntry = (claims: Claims) => {
      const account = Object.keys(claims)[0]!;
      const token = Object.keys(claims[account]!)[0]!;
      return { account, token, entry: claims[account]![token]! };
    };

    // Same entry count as the tree (8), but one leaf has no entry and another has two, under differently-cased keys.
    const [drop, dup] = Object.keys(proofs.claims).filter((a) => Object.keys(proofs.claims[a]!).length === 1);
    const dupToken = Object.keys(proofs.claims[dup!]!)[0]!;
    const kept = Object.entries(proofs.claims).filter(([account]) => account !== drop);
    const forged = { ...proofs, claims: { ...Object.fromEntries(kept), [dup!.toLowerCase()]: proofs.claims[dup!]! } };
    expect(Object.values(forged.claims).flatMap((byToken) => Object.keys(byToken))).toHaveLength(8);
    writeFileSync(join(dir, 'forged.json'), JSON.stringify(forged));
    expect(runCli(['verify', treePath, join(dir, 'forged.json')], out)).toBe(1);
    expect(out.errors.at(-1)).toBe(
      `error: duplicate entry for ${dup!} / ${dupToken} (keys ${dup!.toLowerCase()} / ${dupToken})`,
    );

    // The stored leaf hash must be the one the entry's own values produce.
    const wrongLeaf = structuredClone(proofs);
    firstEntry(wrongLeaf.claims).entry.leaf = '0x' + 'ab'.repeat(32);
    writeFileSync(join(dir, 'wrong-leaf.json'), JSON.stringify(wrongLeaf));
    expect(runCli(['verify', treePath, join(dir, 'wrong-leaf.json')], out)).toBe(1);
    expect(out.errors.at(-1)).toMatch(/leaf mismatch for .* file has 0x(ab){32}, expected 0x[0-9a-f]{64}$/);

    // An entry for a value the tree does not hold (consistent leaf, real proof) is not a leaf of the tree.
    const foreign = structuredClone(proofs);
    const f = firstEntry(foreign.claims);
    f.entry.cumulativeAmount = (BigInt(f.entry.cumulativeAmount) + 1n).toString();
    f.entry.leaf = leafHash(getAddress(f.account), getAddress(f.token), BigInt(f.entry.cumulativeAmount));
    writeFileSync(join(dir, 'foreign.json'), JSON.stringify(foreign));
    expect(runCli(['verify', treePath, join(dir, 'foreign.json')], out)).toBe(1);
    expect(out.errors.at(-1)).toMatch(/is not a leaf of the tree$/);

    // Non-canonical amounts are rejected (BigInt alone would accept hex or padded strings).
    const hexAmount = structuredClone(proofs);
    const h = firstEntry(hexAmount.claims).entry;
    h.cumulativeAmount = '0x' + BigInt(h.cumulativeAmount).toString(16);
    writeFileSync(join(dir, 'hex.json'), JSON.stringify(hexAmount));
    expect(runCli(['verify', treePath, join(dir, 'hex.json')], out)).toBe(1);
    expect(out.errors.at(-1)).toMatch(/not a canonical decimal/);
  });

  it('reports usage and input errors with exit code 1', () => {
    const out = capture();
    expect(runCli(['frobnicate'], out)).toBe(1);
    expect(runCli(['build', ...EXAMPLES], out)).toBe(1);
    expect(runCli(['verify'], out)).toBe(1);
    expect(out.errors.filter((e) => e.startsWith('usage:')).length).toBe(3);

    const bad = join(dir, 'bad.csv');
    writeFileSync(bad, 'account,token,amount\n0x1234,0x1234,1\n');
    expect(runCli(['build', '--out', dir, bad], out)).toBe(1);
    expect(out.errors.at(-1)).toMatch(/bad\.csv:2: invalid account address/);

    expect(runCli(['help'], out)).toBe(0);
    expect(out.lines.at(-1)).toMatch(/^usage:/);
  });

  it('detects its own entry point without import.meta.main (absent before Node 24.2)', () => {
    const self = fileURLToPath(import.meta.url);
    expect(isEntryPoint(self, import.meta.url)).toBe(true);
    expect(isEntryPoint(self, pathToFileURL(join(ROOT, 'src/cli.ts')).href)).toBe(false);
    expect(isEntryPoint(undefined, import.meta.url)).toBe(false);
    expect(isEntryPoint(join(dir, 'does-not-exist.ts'), import.meta.url)).toBe(false);
  });

  it('runs as a binary under plain Node 24 (type stripping)', () => {
    const res = spawnSync(process.execPath, ['src/cli.ts', 'build', '--out', dir, ...EXAMPLES], {
      cwd: ROOT,
      encoding: 'utf8',
    });
    expect(res.status, res.stderr).toBe(0);
    expect(res.stdout).toMatch(/epoch 3: 8 leaves, 5 accounts/);
    const bad = spawnSync(process.execPath, ['src/cli.ts', 'nope'], { cwd: ROOT, encoding: 'utf8' });
    expect(bad.status).toBe(1);
    expect(bad.stderr).toMatch(/unknown command/);
  });
});
