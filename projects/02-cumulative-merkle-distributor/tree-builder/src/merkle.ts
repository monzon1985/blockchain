// SPDX-License-Identifier: MIT
/**
 * Merkle tree core: the array layout, proofs and multiproofs of @openzeppelin/merkle-tree, reimplemented on viem so
 * the builder does not depend on the library it is differentially tested against.
 *
 * Layout: a complete binary tree of 2n-1 nodes stored in an array; the children of node i are 2i+1 and 2i+2; leaf k
 * (in the order given to `makeTree`) sits at index 2n-2-k. Pairs are hashed in ascending order, which is what
 * OpenZeppelin's `MerkleProof` (commutative keccak256) verifies on-chain.
 */
import { concat, keccak256, type Hex } from 'viem';

export class MerkleError extends Error {
  override name = 'MerkleError';
}

export interface MultiProof {
  /** Leaf hashes in the order the verifier consumes them (descending tree index). */
  readonly leaves: readonly Hex[];
  readonly proof: readonly Hex[];
  readonly proofFlags: readonly boolean[];
}

const HASH_RE = /^0x[0-9a-f]{64}$/;

export function assertHash(value: string, what = 'node'): asserts value is Hex {
  if (!HASH_RE.test(value))
    throw new MerkleError(`${what} must be a 0x-prefixed lowercase 32-byte hex string: ${value}`);
}

/** Total order on 32-byte hashes, as unsigned 256-bit integers. */
export function compareHashes(a: Hex, b: Hex): number {
  // Canonical hashes (lowercase, same width) order lexicographically exactly as they do numerically.
  if (HASH_RE.test(a) && HASH_RE.test(b)) return a < b ? -1 : a > b ? 1 : 0;
  const x = BigInt(a);
  const y = BigInt(b);
  return x < y ? -1 : x > y ? 1 : 0;
}

/** keccak256 of the two children in ascending order (OpenZeppelin `Hashes.commutativeKeccak256`). */
export function hashPair(a: Hex, b: Hex): Hex {
  return compareHashes(a, b) <= 0 ? keccak256(concat([a, b])) : keccak256(concat([b, a]));
}

const leftChild = (i: number): number => 2 * i + 1;
const parent = (i: number): number => Math.floor((i - 1) / 2);
const sibling = (i: number): number => (i % 2 === 1 ? i + 1 : i - 1);

export function isLeafIndex(tree: readonly Hex[], i: number): boolean {
  return Number.isInteger(i) && i >= 0 && i < tree.length && leftChild(i) >= tree.length;
}

function node(tree: readonly Hex[], i: number): Hex {
  const value = tree[i];
  if (value === undefined) throw new MerkleError(`tree index ${i} out of range`);
  return value;
}

/** Builds the node array for `leaves` (already hashed), in the given order. */
export function makeTree(leaves: readonly Hex[]): Hex[] {
  if (leaves.length === 0) throw new MerkleError('expected at least one leaf');
  leaves.forEach((leaf) => {
    assertHash(leaf, 'leaf');
  });
  const tree = new Array<Hex>(2 * leaves.length - 1);
  leaves.forEach((leaf, k) => {
    tree[tree.length - 1 - k] = leaf;
  });
  for (let i = leaves.length - 2; i >= 0; i--) {
    tree[i] = hashPair(node(tree, 2 * i + 1), node(tree, 2 * i + 2));
  }
  return tree;
}

/** Sibling path from the leaf at `index` up to (excluding) the root. */
export function getProof(tree: readonly Hex[], index: number): Hex[] {
  if (!isLeafIndex(tree, index)) throw new MerkleError(`index ${index} is not a leaf`);
  const proof: Hex[] = [];
  for (let i = index; i > 0; i = parent(i)) proof.push(node(tree, sibling(i)));
  return proof;
}

/** Multiproof for the leaves at `indices`, identical to `getMultiProof` in @openzeppelin/merkle-tree. */
export function getMultiProof(tree: readonly Hex[], indices: readonly number[]): MultiProof {
  for (const i of indices) {
    if (!isLeafIndex(tree, i)) throw new MerkleError(`index ${i} is not a leaf`);
  }
  const sorted = [...indices].sort((a, b) => b - a);
  for (let k = 1; k < sorted.length; k++) {
    if (sorted[k] === sorted[k - 1]) throw new MerkleError('cannot prove a duplicated index');
  }

  // A queue of tree indices: every step pops one node (and its sibling, if also queued) and pushes the parent.
  const queue = [...sorted];
  let head = 0;
  const proof: Hex[] = [];
  const proofFlags: boolean[] = [];
  while (head < queue.length && (queue[head] ?? 0) > 0) {
    const j = queue[head++] ?? 0;
    const s = sibling(j);
    if (queue[head] === s) {
      proofFlags.push(true);
      head++;
    } else {
      proofFlags.push(false);
      proof.push(node(tree, s));
    }
    queue.push(parent(j));
  }
  if (sorted.length === 0) proof.push(node(tree, 0));
  return { leaves: sorted.map((i) => node(tree, i)), proof, proofFlags };
}

/** Root implied by `leaf` and its sibling path. */
export function processProof(leaf: Hex, proof: readonly Hex[]): Hex {
  assertHash(leaf, 'leaf');
  return proof.reduce<Hex>((acc, p) => {
    assertHash(p, 'proof element');
    return hashPair(acc, p);
  }, leaf);
}

/** Root implied by a multiproof; mirrors `MerkleProof.processMultiProof`, including its well-formedness checks. */
export function processMultiProof({ leaves, proof, proofFlags }: MultiProof): Hex {
  leaves.forEach((l) => {
    assertHash(l, 'leaf');
  });
  proof.forEach((p) => {
    assertHash(p, 'proof element');
  });
  if (leaves.length + proof.length !== proofFlags.length + 1) {
    throw new MerkleError('leaves and multiproof are not compatible');
  }
  if (proofFlags.length === 0) {
    // Exactly one node was supplied (checked above): a single leaf, or the root itself for the empty set.
    const only = leaves[0] ?? proof[0];
    if (only === undefined) throw new MerkleError('empty multiproof');
    return only;
  }
  const queue: Hex[] = [...leaves];
  let head = 0;
  let proofPos = 0;
  for (const flag of proofFlags) {
    const a = queue[head++];
    const b = flag ? queue[head++] : proof[proofPos++];
    if (a === undefined || b === undefined) throw new MerkleError('multiproof consumed more nodes than it provides');
    queue.push(hashPair(a, b));
  }
  if (proofPos !== proof.length) throw new MerkleError('multiproof left proof elements unused');
  // With leaves + proof = flags + 1 and every proof element consumed, exactly one node is left: the last one pushed.
  return queue[queue.length - 1] as Hex;
}

/** Checks that every internal node is the hash of its children. */
export function isValidTree(tree: readonly Hex[]): boolean {
  if (tree.length === 0 || tree.length % 2 === 0) return false;
  for (let i = 0; i < tree.length; i++) {
    const value = tree[i];
    if (value === undefined || !HASH_RE.test(value)) return false;
    const l = 2 * i + 1;
    if (l < tree.length && value !== hashPair(node(tree, l), node(tree, l + 1))) return false;
  }
  return true;
}
