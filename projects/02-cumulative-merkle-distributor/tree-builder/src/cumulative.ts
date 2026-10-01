// SPDX-License-Identifier: MIT
/**
 * Cumulative accounting across epochs. Every epoch adds non-negative amounts to a ledger keyed by (account, token);
 * each epoch's tree commits the running totals of every pair ever allocated (pairs are carried forward even if the
 * epoch does not mention them), so claimed[account][token] on-chain can only ever grow towards the committed total.
 */
import { keccak256, maxUint256, stringToBytes, type Address, type Hex } from 'viem';
import type { EpochRow } from './csv.ts';
import {
  CumulativeMerkleTree,
  LEAF_ENCODING,
  fromLeafValue,
  leafHash,
  type Allocation,
  type LeafValue,
} from './tree.ts';

export class LedgerError extends Error {
  override name = 'LedgerError';
}

/** Running totals keyed by `${account}:${token}` (lowercase). Immutable: `applyEpoch` returns a new ledger. */
export type Ledger = ReadonlyMap<string, Allocation>;

const pairKey = (account: Address, token: Address): string => `${account.toLowerCase()}:${token.toLowerCase()}`;

/** Adds one epoch's rows to `previous`. Duplicate rows for a pair within an epoch are summed. */
export function applyEpoch(previous: Ledger, rows: readonly EpochRow[]): Ledger {
  const next = new Map(previous);
  for (const row of rows) {
    const key = pairKey(row.account, row.token);
    const before = next.get(key)?.cumulativeAmount ?? 0n;
    const cumulativeAmount = before + row.amount;
    if (cumulativeAmount > maxUint256) {
      throw new LedgerError(`line ${row.line}: cumulative amount for ${row.account}/${row.token} overflows uint256`);
    }
    next.set(key, { account: row.account, token: row.token, cumulativeAmount });
  }
  return next;
}

/** Canonical leaf order: by account, then token (lowercase hex). Zero allocations are not worth a leaf. */
export function ledgerAllocations(ledger: Ledger): Allocation[] {
  return [...ledger.entries()]
    .filter(([, a]) => a.cumulativeAmount > 0n)
    .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))
    .map(([, a]) => a);
}

export interface TokenTotals {
  readonly token: Address;
  /** Sum of cumulative amounts in this epoch's tree: what the vault must have received in total. */
  readonly cumulativeTotal: string;
  /** What this epoch added. */
  readonly epochTotal: string;
}

export interface Manifest {
  readonly format: 'cumulative-merkle-distributor/manifest-v1';
  readonly epoch: number;
  readonly root: Hex;
  readonly previousRoot: Hex | null;
  readonly leafEncoding: readonly string[];
  readonly leafCount: number;
  readonly accountCount: number;
  /** keccak256 of the raw bytes of this epoch's input CSV. */
  readonly inputHash: Hex;
  readonly tokens: readonly TokenTotals[];
}

export interface ClaimEntry {
  readonly cumulativeAmount: string;
  readonly leaf: Hex;
  readonly proof: readonly Hex[];
}

export interface ProofsFile {
  readonly format: 'cumulative-merkle-distributor/proofs-v1';
  readonly epoch: number;
  readonly root: Hex;
  /** claims[account][token] */
  readonly claims: Readonly<Record<Address, Readonly<Record<Address, ClaimEntry>>>>;
}

export interface EpochBuild {
  readonly epoch: number;
  readonly ledger: Ledger;
  readonly allocations: readonly Allocation[];
  readonly tree: CumulativeMerkleTree;
  readonly manifest: Manifest;
  /** Exact bytes of manifest.json. */
  readonly manifestJson: string;
  /** keccak256(manifestJson): the `metadataHash` to pass to `proposeRoot`. */
  readonly metadataHash: Hex;
}

export interface EpochInput {
  /** Raw CSV text, hashed into the manifest. */
  readonly text: string;
  readonly rows: readonly EpochRow[];
}

/** Stable JSON: 2-space indentation and a trailing newline, the format of every file the builder writes. */
export function toJson(value: unknown): string {
  return JSON.stringify(value, null, 2) + '\n';
}

function tokenTotals(allocations: readonly Allocation[], rows: readonly EpochRow[]): TokenTotals[] {
  const cumulative = new Map<string, { token: Address; total: bigint; added: bigint }>();
  for (const a of allocations) {
    const k = a.token.toLowerCase();
    const t = cumulative.get(k) ?? { token: a.token, total: 0n, added: 0n };
    t.total += a.cumulativeAmount;
    cumulative.set(k, t);
  }
  for (const r of rows) {
    const t = cumulative.get(r.token.toLowerCase());
    if (t !== undefined) t.added += r.amount;
  }
  return [...cumulative.entries()]
    .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))
    .map(([, t]) => ({ token: t.token, cumulativeTotal: t.total.toString(10), epochTotal: t.added.toString(10) }));
}

/** Builds every epoch in order. Epoch numbers start at 1. */
export function buildEpochs(inputs: readonly EpochInput[]): EpochBuild[] {
  const builds: EpochBuild[] = [];
  let ledger: Ledger = new Map();
  let previousRoot: Hex | null = null;
  inputs.forEach((input, i) => {
    ledger = applyEpoch(ledger, input.rows);
    const allocations = ledgerAllocations(ledger);
    if (allocations.length === 0) throw new LedgerError(`epoch ${i + 1}: nothing allocated yet, no tree to build`);
    const tree = CumulativeMerkleTree.of(allocations);
    const manifest: Manifest = {
      format: 'cumulative-merkle-distributor/manifest-v1',
      epoch: i + 1,
      root: tree.root,
      previousRoot,
      leafEncoding: [...LEAF_ENCODING],
      leafCount: tree.length,
      accountCount: new Set(allocations.map((a) => a.account)).size,
      inputHash: keccak256(stringToBytes(input.text)),
      tokens: tokenTotals(allocations, input.rows),
    };
    const manifestJson = toJson(manifest);
    builds.push({
      epoch: i + 1,
      ledger,
      allocations,
      tree,
      manifest,
      manifestJson,
      metadataHash: keccak256(stringToBytes(manifestJson)),
    });
    previousRoot = tree.root;
  });
  return builds;
}

/** Per-account proofs for one epoch, keyed by account then token (both in canonical order). */
export function proofsFile(build: EpochBuild): ProofsFile {
  const claims: Record<Address, Record<Address, ClaimEntry>> = {};
  build.tree.values.forEach(({ value }, i) => {
    const [account, token, cumulativeAmount] = value;
    const byToken = (claims[account] ??= {});
    byToken[token] = { cumulativeAmount, leaf: build.tree.leafHashAt(i), proof: build.tree.getProof(i) };
  });
  return { format: 'cumulative-merkle-distributor/proofs-v1', epoch: build.epoch, root: build.tree.root, claims };
}

/**
 * Re-checks a proofs file against its tree and returns the number of entries verified. The file must hold exactly
 * one entry per leaf of the tree: every entry's `leaf` is recomputed, its proof must reach the root, and duplicates
 * and missing leaves are errors. Keys are plain JSON object keys, so they are normalized first: a differently-cased
 * copy of one account's entry can neither count twice nor stand in for another account's missing entry.
 */
export function verifyProofsFile(tree: CumulativeMerkleTree, proofs: ProofsFile): number {
  // `proofs` usually comes from JSON.parse: check what the type system cannot.
  const format: string = proofs.format;
  if (format !== 'cumulative-merkle-distributor/proofs-v1') throw new LedgerError(`unknown proofs format: ${format}`);
  if (proofs.root !== tree.root) throw new LedgerError(`proofs root ${proofs.root} != tree root ${tree.root}`);

  const treeLeaves = new Map<Hex, string>();
  for (let i = 0; i < tree.length; i++) {
    const a = tree.allocationAt(i);
    treeLeaves.set(tree.leafHashAt(i), `${a.account} / ${a.token}`);
  }
  const seen = new Set<Hex>();
  for (const [rawAccount, byToken] of Object.entries(proofs.claims)) {
    for (const [rawToken, entry] of Object.entries(byToken)) {
      const allocation = fromLeafValue([rawAccount, rawToken, entry.cumulativeAmount] as LeafValue);
      const where = `${allocation.account} / ${allocation.token}`;
      const leaf = leafHash(allocation.account, allocation.token, allocation.cumulativeAmount);
      if (seen.has(leaf)) throw new LedgerError(`duplicate entry for ${where} (keys ${rawAccount} / ${rawToken})`);
      if (entry.leaf !== leaf)
        throw new LedgerError(`leaf mismatch for ${where}: file has ${entry.leaf}, expected ${leaf}`);
      if (!treeLeaves.has(leaf))
        throw new LedgerError(`${where} with ${entry.cumulativeAmount} is not a leaf of the tree`);
      if (!tree.verify(allocation, entry.proof)) throw new LedgerError(`invalid proof for ${where}`);
      seen.add(leaf);
    }
  }
  const missing = [...treeLeaves].filter(([leaf]) => !seen.has(leaf)).map(([, where]) => where);
  if (missing.length > 0) {
    throw new LedgerError(`proofs cover ${seen.size} of ${tree.length} leaves; missing ${missing.join(', ')}`);
  }
  return seen.size;
}
