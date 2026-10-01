// SPDX-License-Identifier: MIT
import * as oz from '@openzeppelin/merkle-tree/dist/core.js';
import fc from 'fast-check';
import type { Hex } from 'viem';
import { describe, expect, it } from 'vitest';
import {
  MerkleError,
  compareHashes,
  getMultiProof,
  getProof,
  hashPair,
  isValidTree,
  makeTree,
  processMultiProof,
  processProof,
} from '../src/merkle.ts';
import { hash32 } from './arbitraries.ts';

const leavesArb = fc.uniqueArray(hash32, { minLength: 1, maxLength: 70 });

/** Leaves plus a (possibly empty) subset of their tree indices. */
const leavesWithSubset = leavesArb.chain((leaves) =>
  fc.tuple(fc.constant(leaves), fc.subarray(leaves.map((_, k) => 2 * leaves.length - 2 - k))),
);

describe('merkle core vs @openzeppelin/merkle-tree core', () => {
  it('builds the identical node array', () => {
    fc.assert(
      fc.property(leavesArb, (leaves) => {
        expect(makeTree(leaves)).toEqual(oz.makeMerkleTree(leaves));
      }),
    );
  });

  it('produces identical single proofs that reach the root', () => {
    fc.assert(
      fc.property(leavesArb, fc.nat(), (leaves, pick) => {
        const tree = makeTree(leaves);
        const index = tree.length - 1 - (pick % leaves.length);
        const proof = getProof(tree, index);
        expect(proof).toEqual(oz.getProof(tree, index));
        expect(processProof(tree[index]!, proof)).toBe(tree[0]);
        expect(proof.length).toBeLessThanOrEqual(Math.ceil(Math.log2(leaves.length)) + 1);
      }),
    );
  });

  it('produces identical multiproofs that reach the root', () => {
    fc.assert(
      fc.property(leavesWithSubset, ([leaves, indices]) => {
        const tree = makeTree(leaves);
        const mine = getMultiProof(tree, indices);
        const theirs = oz.getMultiProof(tree, [...indices]);
        expect(mine).toEqual(theirs);
        expect(processMultiProof(mine)).toBe(tree[0]);
        expect(processMultiProof(mine)).toBe(oz.processMultiProof(theirs));
      }),
    );
  });

  it('orders hashes numerically, whatever their case', () => {
    fc.assert(
      fc.property(hash32, hash32, fc.boolean(), (a, b, upper) => {
        const x = BigInt(a);
        const y = BigInt(b);
        const expected = x < y ? -1 : x > y ? 1 : 0;
        expect(compareHashes(a, b)).toBe(expected);
        const shout = (h: Hex): Hex => `0x${h.slice(2).toUpperCase()}`;
        expect(compareHashes(upper ? shout(a) : a, shout(b))).toBe(expected);
      }),
    );
  });

  it('hashes pairs commutatively', () => {
    fc.assert(
      fc.property(hash32, hash32, (a, b) => {
        expect(hashPair(a, b)).toBe(hashPair(b, a));
      }),
    );
  });
});

describe('merkle core: tampering and malformed input', () => {
  it('a tampered proof element changes the root', () => {
    fc.assert(
      fc.property(fc.uniqueArray(hash32, { minLength: 2, maxLength: 40 }), fc.nat(), fc.nat(), (leaves, pick, at) => {
        const tree = makeTree(leaves);
        const index = tree.length - 1 - (pick % leaves.length);
        const proof = getProof(tree, index);
        const k = at % proof.length;
        const flipped = [...proof];
        flipped[k] = `0x${(BigInt(proof[k]!) ^ 1n).toString(16).padStart(64, '0')}`;
        expect(processProof(tree[index]!, flipped)).not.toBe(tree[0]);
      }),
    );
  });

  it('detects a corrupted node', () => {
    fc.assert(
      fc.property(fc.uniqueArray(hash32, { minLength: 2, maxLength: 40 }), fc.nat(), hash32, (leaves, at, junk) => {
        const tree = makeTree(leaves);
        expect(isValidTree(tree)).toBe(true);
        const k = at % tree.length;
        fc.pre(tree[k] !== junk);
        const corrupted = [...tree];
        corrupted[k] = junk;
        expect(isValidTree(corrupted)).toBe(false);
      }),
    );
  });

  it('rejects malformed input', () => {
    const leaves = ['0x' + '11'.repeat(32), '0x' + '22'.repeat(32), '0x' + '33'.repeat(32)] as Hex[];
    const tree = makeTree(leaves);
    expect(() => makeTree([])).toThrow(MerkleError);
    expect(() => makeTree(['0x1234'])).toThrow(/32-byte/);
    expect(() => makeTree(['0x' + 'AB'.repeat(32)] as Hex[])).toThrow(/lowercase/);
    expect(() => getProof(tree, 0)).toThrow(/not a leaf/);
    expect(() => getProof(tree, 99)).toThrow(/not a leaf/);
    expect(() => getMultiProof(tree, [4, 4])).toThrow(/duplicated/);
    expect(() => getMultiProof(tree, [1])).toThrow(/not a leaf/);
    expect(() => processMultiProof({ leaves: [leaves[0]!], proof: [], proofFlags: [true] })).toThrow(/compatible/);
    expect(() =>
      processMultiProof({ leaves: [leaves[0]!, leaves[1]!], proof: [leaves[2]!], proofFlags: [true, true] }),
    ).toThrow(/consumed more/);
    expect(() => processMultiProof({ leaves: [], proof: [], proofFlags: [] })).toThrow(MerkleError);
    expect(isValidTree([])).toBe(false);
    expect(isValidTree(tree.slice(0, 2))).toBe(false);
    expect(isValidTree(['0x12'])).toBe(false);
  });

  it('handles the degenerate cases like OpenZeppelin', () => {
    const [leaf] = ['0x' + '44'.repeat(32)] as Hex[];
    const tree = makeTree([leaf!]);
    expect(tree).toEqual([leaf]);
    expect(getProof(tree, 0)).toEqual([]);
    const empty = getMultiProof(tree, []);
    expect(empty).toEqual(oz.getMultiProof(tree, []));
    expect(processMultiProof(empty)).toBe(leaf);
    expect(processMultiProof(getMultiProof(tree, [0]))).toBe(leaf);
  });
});
