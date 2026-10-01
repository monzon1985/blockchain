// SPDX-License-Identifier: MIT
import { StandardMerkleTree } from '@openzeppelin/merkle-tree';
import fc from 'fast-check';
import { readFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { keccak256, maxUint256, stringToBytes, type Address } from 'viem';
import { describe, expect, it } from 'vitest';
import { formatEpochCsv, parseEpochCsv, type EpochRow } from '../src/csv.ts';
import {
  LedgerError,
  applyEpoch,
  buildEpochs,
  ledgerAllocations,
  proofsFile,
  toJson,
  verifyProofsFile,
  type EpochInput,
  type Ledger,
  type ProofsFile,
} from '../src/cumulative.ts';
import { LEAF_ENCODING } from '../src/tree.ts';
import { address } from './arbitraries.ts';

type Row = Omit<EpochRow, 'line'>;

/** A few epochs of rows over small account / token pools (duplicates and zero amounts included). */
const epochsArb: fc.Arbitrary<Row[][]> = fc
  .tuple(
    fc.uniqueArray(address, { minLength: 1, maxLength: 8 }),
    fc.uniqueArray(address, { minLength: 1, maxLength: 3 }),
  )
  .chain(([accounts, tokens]) =>
    fc.array(
      fc.array(
        fc.record({
          account: fc.constantFrom(...accounts),
          token: fc.constantFrom(...tokens),
          amount: fc.oneof(fc.constant(0n), fc.bigInt({ min: 1n, max: 10n ** 27n })),
        }),
        { minLength: 1, maxLength: 20 },
      ),
      { minLength: 1, maxLength: 5 },
    ),
  )
  .filter((epochs) => epochs[0]!.some((r) => r.amount > 0n));

const toInputs = (epochs: Row[][]): EpochInput[] =>
  epochs.map((rows, i) => {
    const text = formatEpochCsv(rows);
    return { text, rows: parseEpochCsv(text, `epoch-${i + 1}`) };
  });

const pair = (account: Address, token: Address) => `${account.toLowerCase()}:${token.toLowerCase()}`;

describe('cumulative accounting (properties)', () => {
  it('cumulative amounts are monotonic across epochs and pairs are carried forward', () => {
    fc.assert(
      fc.property(epochsArb, (epochs) => {
        const builds = buildEpochs(toInputs(epochs));
        for (let e = 1; e < builds.length; e++) {
          const next = new Map(builds[e]!.allocations.map((a) => [pair(a.account, a.token), a.cumulativeAmount]));
          for (const a of builds[e - 1]!.allocations) {
            const later = next.get(pair(a.account, a.token));
            expect(later, 'pair dropped from a later epoch').toBeDefined();
            expect(later! >= a.cumulativeAmount).toBe(true);
          }
        }
      }),
    );
  });

  it("every cumulative amount equals the sum of that pair's rows so far", () => {
    fc.assert(
      fc.property(epochsArb, (epochs) => {
        const builds = buildEpochs(toInputs(epochs));
        const running = new Map<string, bigint>();
        epochs.forEach((rows, e) => {
          for (const r of rows)
            running.set(pair(r.account, r.token), (running.get(pair(r.account, r.token)) ?? 0n) + r.amount);
          const expected = [...running.entries()].filter(([, v]) => v > 0n);
          const got = builds[e]!.allocations.map((a) => [pair(a.account, a.token), a.cumulativeAmount] as const);
          expect(new Map(got)).toEqual(new Map(expected));
        });
      }),
    );
  });

  it("every leaf of every epoch verifies against that epoch's root (and with StandardMerkleTree)", () => {
    fc.assert(
      fc.property(epochsArb, (epochs) => {
        for (const b of buildEpochs(toInputs(epochs))) {
          const file = proofsFile(b);
          expect(file.root).toBe(b.tree.root);
          for (const [account, byToken] of Object.entries(file.claims)) {
            for (const [token, entry] of Object.entries(byToken)) {
              const value = [account, token, entry.cumulativeAmount];
              expect(StandardMerkleTree.verify(b.tree.root, [...LEAF_ENCODING], value, [...entry.proof])).toBe(true);
            }
          }
        }
      }),
      { numRuns: 100 },
    );
  });

  it('shuffling rows within an epoch changes nothing but the input hash (tree.json and proofs.json are byte-identical)', () => {
    fc.assert(
      fc.property(
        epochsArb.chain((epochs) =>
          fc.tuple(
            fc.constant(epochs),
            fc.tuple(...epochs.map((rows) => fc.shuffledSubarray(rows, { minLength: rows.length }))),
          ),
        ),
        ([epochs, shuffled]) => {
          const inputsA = toInputs(epochs);
          const inputsB = toInputs(shuffled);
          const a = buildEpochs(inputsA);
          const b = buildEpochs(inputsB);
          a.forEach((build, e) => {
            const other = b[e]!;
            expect(other.tree.root).toBe(build.tree.root);
            expect(toJson(other.tree.dump())).toBe(toJson(build.tree.dump()));
            expect(toJson(proofsFile(other))).toBe(toJson(proofsFile(build)));
            // The manifest binds the exact input bytes: every other field is order-independent.
            expect({ ...other.manifest, inputHash: null }).toEqual({ ...build.manifest, inputHash: null });
            const sameBytes = inputsA[e]!.text === inputsB[e]!.text;
            expect(other.manifest.inputHash === build.manifest.inputHash).toBe(sameBytes);
            expect(other.metadataHash === build.metadataHash).toBe(sameBytes);
          });
        },
      ),
    );
  });

  it('building twice gives byte-identical outputs', () => {
    fc.assert(
      fc.property(epochsArb, (epochs) => {
        const inputs = toInputs(epochs);
        const a = buildEpochs(inputs);
        const b = buildEpochs(inputs);
        a.forEach((build, e) => {
          expect(b[e]!.manifestJson).toBe(build.manifestJson);
          expect(b[e]!.metadataHash).toBe(build.metadataHash);
          expect(JSON.stringify(proofsFile(b[e]!))).toBe(JSON.stringify(proofsFile(build)));
        });
      }),
      { numRuns: 50 },
    );
  });

  it('verifyProofsFile accepts every proofs file the builder writes, and none with an entry dropped or re-cased', () => {
    fc.assert(
      fc.property(epochsArb, fc.nat(), (epochs, pick) => {
        const build = buildEpochs(toInputs(epochs)).at(-1)!;
        const file = proofsFile(build);
        expect(verifyProofsFile(build.tree, file)).toBe(build.tree.length);

        const accounts = Object.keys(file.claims) as Address[];
        const victim = accounts[pick % accounts.length]!;
        const dropped: ProofsFile = {
          ...file,
          claims: Object.fromEntries(Object.entries(file.claims).filter(([a]) => a !== victim)),
        };
        expect(() => verifyProofsFile(build.tree, dropped)).toThrow(/proofs cover/);

        // A lowercase copy of an entry, whether next to the original or instead of it, never counts as another leaf.
        const recased = { ...file, claims: { ...file.claims, [victim.toLowerCase()]: file.claims[victim]! } };
        if (victim !== victim.toLowerCase()) expect(() => verifyProofsFile(build.tree, recased)).toThrow(/duplicate/);
        const moved: ProofsFile = {
          ...dropped,
          claims: { ...dropped.claims, [victim.toLowerCase()]: file.claims[victim]! },
        };
        expect(verifyProofsFile(build.tree, moved)).toBe(build.tree.length);
      }),
      { numRuns: 100 },
    );
  });
});

describe('cumulative accounting (examples)', () => {
  const alice = '0x328809Bc894f92807417D2dAD6b7C998c1aFdac6';
  const bob = '0x1D96F2f6BeF1202E4Ce1Ff6Dad0c2CB002861d3e';
  const reward = '0x6e107075c50e05cAAc17c25FBc6c61389Da06961';

  it('sums duplicate rows, skips zero pairs and links manifests', () => {
    const e1 = formatEpochCsv([
      { account: alice, token: reward, amount: 5n },
      { account: alice, token: reward, amount: 7n },
      { account: bob, token: reward, amount: 0n },
    ]);
    const e2 = formatEpochCsv([{ account: bob, token: reward, amount: 3n }]);
    const [b1, b2] = buildEpochs([
      { text: e1, rows: parseEpochCsv(e1) },
      { text: e2, rows: parseEpochCsv(e2) },
    ]);
    expect(b1!.allocations).toEqual([{ account: alice, token: reward, cumulativeAmount: 12n }]);
    expect(b1!.manifest.previousRoot).toBeNull();
    expect(b1!.manifest.inputHash).toBe(keccak256(stringToBytes(e1)));
    expect(b1!.manifest.tokens).toEqual([{ token: reward, cumulativeTotal: '12', epochTotal: '12' }]);
    expect(b1!.metadataHash).toBe(keccak256(stringToBytes(b1!.manifestJson)));

    expect(b2!.manifest.previousRoot).toBe(b1!.tree.root);
    expect(b2!.manifest.epoch).toBe(2);
    expect(b2!.manifest.leafCount).toBe(2);
    expect(b2!.manifest.accountCount).toBe(2);
    expect(b2!.manifest.tokens).toEqual([{ token: reward, cumulativeTotal: '15', epochTotal: '3' }]);
  });

  it('reordering the rows of examples/epochs/epoch-1.csv changes only inputHash and metadataHash', () => {
    const text = readFileSync(join(resolve(import.meta.dirname, '..'), 'examples/epochs/epoch-1.csv'), 'utf8');
    const lines = text.trimEnd().split(/\r?\n/);
    const reversed = [lines[0], ...lines.slice(1).reverse()].join('\n') + '\n';
    expect(reversed).not.toBe(text);
    const [a] = buildEpochs([{ text, rows: parseEpochCsv(text) }]);
    const [b] = buildEpochs([{ text: reversed, rows: parseEpochCsv(reversed) }]);
    expect(toJson(b!.tree.dump())).toBe(toJson(a!.tree.dump()));
    expect(toJson(proofsFile(b!))).toBe(toJson(proofsFile(a!)));
    expect(b!.manifest.inputHash).not.toBe(a!.manifest.inputHash);
    expect(b!.metadataHash).not.toBe(a!.metadataHash);
    const before = a!.manifestJson.split('\n');
    const changed = b!.manifestJson.split('\n').filter((line, i) => line !== before[i]);
    expect(changed).toEqual([`  "inputHash": "${b!.manifest.inputHash}",`]);
  });

  it('rejects overflow and empty first epochs', () => {
    const big = formatEpochCsv([{ account: alice, token: reward, amount: maxUint256 }]);
    const one = formatEpochCsv([{ account: alice, token: reward, amount: 1n }]);
    expect(() =>
      buildEpochs([
        { text: big, rows: parseEpochCsv(big) },
        { text: one, rows: parseEpochCsv(one) },
      ]),
    ).toThrow(LedgerError);
    const zero = formatEpochCsv([{ account: alice, token: reward, amount: 0n }]);
    expect(() => buildEpochs([{ text: zero, rows: parseEpochCsv(zero) }])).toThrow(/nothing allocated/);
  });

  it('applyEpoch never mutates the previous ledger', () => {
    const before: Ledger = applyEpoch(
      new Map(),
      parseEpochCsv(formatEpochCsv([{ account: alice, token: reward, amount: 1n }])),
    );
    const snapshot = JSON.stringify(ledgerAllocations(before), (_, v: unknown) =>
      typeof v === 'bigint' ? v.toString() : v,
    );
    applyEpoch(before, parseEpochCsv(formatEpochCsv([{ account: alice, token: reward, amount: 9n }])));
    expect(
      JSON.stringify(ledgerAllocations(before), (_, v: unknown) => (typeof v === 'bigint' ? v.toString() : v)),
    ).toBe(snapshot);
  });
});
