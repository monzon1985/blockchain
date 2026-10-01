// SPDX-License-Identifier: MIT
import { StandardMerkleTree } from '@openzeppelin/merkle-tree';
import fc from 'fast-check';
import { encodeAbiParameters, getAddress, keccak256, maxUint256, type Hex } from 'viem';
import { describe, expect, it } from 'vitest';
import { CumulativeMerkleTree, LEAF_ENCODING, fromLeafValue, leafHash, type StandardTreeDump } from '../src/tree.ts';
import { address, allocations } from './arbitraries.ts';

const encoding = [...LEAF_ENCODING];

describe('CumulativeMerkleTree vs StandardMerkleTree', () => {
  it('dump() is byte-identical to StandardMerkleTree.of(...).dump()', () => {
    fc.assert(
      fc.property(allocations(), (allocs) => {
        const mine = CumulativeMerkleTree.of(allocs);
        const theirs = StandardMerkleTree.of(
          mine.values.map((v) => [...v.value]),
          encoding,
        );
        expect(JSON.stringify(mine.dump(), null, 2)).toBe(JSON.stringify(theirs.dump(), null, 2));
        expect(mine.root).toBe(theirs.root);
      }),
    );
  });

  it('every leaf verifies, with our verifier and with StandardMerkleTree.verify', () => {
    fc.assert(
      fc.property(allocations(), (allocs) => {
        const tree = CumulativeMerkleTree.of(allocs);
        tree.values.forEach(({ value }, i) => {
          const proof = tree.getProof(i);
          expect(tree.verify(tree.allocationAt(i), proof)).toBe(true);
          expect(StandardMerkleTree.verify(tree.root, encoding, [...value], proof)).toBe(true);
        });
      }),
    );
  });

  it('a tampered leaf (amount, account or token) does not verify', () => {
    fc.assert(
      fc.property(
        allocations(),
        fc.nat(),
        fc.bigInt({ min: 1n, max: 10n ** 20n }),
        address,
        (allocs, pick, delta, other) => {
          const tree = CumulativeMerkleTree.of(allocs);
          const i = pick % tree.length;
          const a = tree.allocationAt(i);
          const proof = tree.getProof(i);
          const bumped =
            a.cumulativeAmount + delta <= maxUint256 ? a.cumulativeAmount + delta : a.cumulativeAmount - delta;
          expect(tree.verify({ ...a, cumulativeAmount: bumped }, proof)).toBe(false);
          if (other !== a.account) expect(tree.verify({ ...a, account: other }, proof)).toBe(false);
          if (other !== a.token) expect(tree.verify({ ...a, token: other }, proof)).toBe(false);
        },
      ),
    );
  });

  it('is deterministic: the root does not depend on input order', () => {
    fc.assert(
      fc.property(
        allocations(2).chain((xs) => fc.tuple(fc.constant(xs), fc.shuffledSubarray(xs, { minLength: xs.length }))),
        ([allocs, shuffled]) => {
          const a = CumulativeMerkleTree.of(allocs);
          const b = CumulativeMerkleTree.of(shuffled);
          expect(b.root).toBe(a.root);
          expect([...b.tree]).toEqual([...a.tree]);
          expect(JSON.stringify(CumulativeMerkleTree.of(allocs).dump())).toBe(JSON.stringify(a.dump()));
        },
      ),
    );
  });

  it('multiproofs match StandardMerkleTree.getMultiProof and verify with it', () => {
    fc.assert(
      fc.property(
        allocations(1).chain((xs) =>
          fc.tuple(
            fc.constant(xs),
            fc.subarray(
              xs.map((_, i) => i),
              { minLength: 1 },
            ),
          ),
        ),
        ([allocs, subset]) => {
          const tree = CumulativeMerkleTree.of(allocs);
          const oz = StandardMerkleTree.load(tree.dump() as unknown as Parameters<typeof StandardMerkleTree.load>[0]);
          const mine = tree.getMultiProof(subset);
          const theirs = oz.getMultiProof(subset);
          expect(mine.values.map((v) => [...v])).toEqual(theirs.leaves);
          expect(mine.proof).toEqual(theirs.proof);
          expect(mine.proofFlags).toEqual(theirs.proofFlags);
          expect(
            StandardMerkleTree.verifyMultiProof(tree.root, encoding, {
              leaves: mine.values.map((v) => [...v]),
              proof: [...mine.proof],
              proofFlags: [...mine.proofFlags],
            }),
          ).toBe(true);
        },
      ),
    );
  });

  it('leafHash is the double keccak of the ABI encoding (the Solidity formula)', () => {
    fc.assert(
      fc.property(allocations(1, 1), ([a]) => {
        const encoded = encodeAbiParameters(
          [{ type: 'address' }, { type: 'address' }, { type: 'uint256' }],
          [a!.account, a!.token, a!.cumulativeAmount],
        );
        expect(encoded.length).toBe(2 + 96 * 2); // 96 bytes: never a 64-byte inner-node preimage
        expect(leafHash(a!.account, a!.token, a!.cumulativeAmount)).toBe(keccak256(keccak256(encoded)));
      }),
    );
  });
});

describe('CumulativeMerkleTree.load', () => {
  const tree = CumulativeMerkleTree.of([
    { account: getAddress('0x' + '11'.repeat(20)), token: getAddress('0x' + '22'.repeat(20)), cumulativeAmount: 5n },
    { account: getAddress('0x' + '33'.repeat(20)), token: getAddress('0x' + '22'.repeat(20)), cumulativeAmount: 7n },
    { account: getAddress('0x' + '44'.repeat(20)), token: getAddress('0x' + '55'.repeat(20)), cumulativeAmount: 9n },
  ]);
  const dump = (): StandardTreeDump => JSON.parse(JSON.stringify(tree.dump())) as StandardTreeDump;

  it('round-trips a dump', () => {
    const loaded = CumulativeMerkleTree.load(dump());
    expect(loaded.root).toBe(tree.root);
    expect(loaded.getProof(1)).toEqual(tree.getProof(1));
  });

  it('rejects corrupted dumps', () => {
    expect(() => CumulativeMerkleTree.load({ ...dump(), format: 'simple-v1' as 'standard-v1' })).toThrow(/format/);
    expect(() => CumulativeMerkleTree.load({ ...dump(), leafEncoding: ['address', 'uint256'] })).toThrow(/encoding/);

    const badNode = dump();
    (badNode.tree as Hex[])[0] = ('0x' + '00'.repeat(32)) as Hex;
    expect(() => CumulativeMerkleTree.load(badNode)).toThrow(/inconsistent/);

    const badValue = dump();
    (badValue.values as unknown as { value: string[] }[])[0]!.value[2] = '6';
    expect(() => CumulativeMerkleTree.load(badValue)).toThrow(/does not match/);

    const nonCanonical = dump();
    (nonCanonical.values as unknown as { value: string[] }[])[0]!.value[2] = '05';
    expect(() => CumulativeMerkleTree.load(nonCanonical)).toThrow(/canonical/);

    const internal = dump();
    (internal.values as unknown as { treeIndex: number }[])[0]!.treeIndex = 0;
    expect(() => CumulativeMerkleTree.load(internal)).toThrow();

    const missing = dump();
    (missing.values as unknown[]).pop();
    expect(() => CumulativeMerkleTree.load(missing)).toThrow(/exactly one/);
  });

  it('rejects out-of-range indices', () => {
    expect(() => tree.getProof(3)).toThrow(/out of bounds/);
    expect(() => tree.getMultiProof([0, 7])).toThrow(/out of bounds/);
    expect(fromLeafValue(tree.values[0]!.value).cumulativeAmount).toBe(tree.allocationAt(0).cumulativeAmount);
  });
});
