// SPDX-License-Identifier: MIT
import { bcs } from '@mysten/sui/bcs';
import { describe, expect, it } from 'vitest';
import { type FlashArbitrageParams, buildFlashArbitrageTx } from '../src/flash-arbitrage.js';
import { PtbInputError } from '../src/refs.js';
import { ALPHA, BETA, PKG, RECIPIENT, id, pool } from './fixtures.js';

const base = (): FlashArbitrageParams => ({
  packageId: PKG,
  lender: { ...pool(1, 'LP_L', 7), flashFeeBps: 30n },
  sellOn: pool(2, 'LP_X', 8),
  buyOn: pool(3, 'LP_Y', 9),
  side: 'A',
  amount: 10_000_000n,
  minProfit: 1_000n,
  recipient: RECIPIENT,
});

type Data = ReturnType<ReturnType<typeof buildFlashArbitrageTx>['getData']>;
type Cmd = Data['commands'][number];

function moveCall(cmd: Cmd | undefined): NonNullable<Cmd['MoveCall']> {
  if (cmd?.MoveCall == null) throw new Error(`expected MoveCall, got ${cmd?.$kind}`);
  return cmd.MoveCall;
}

/** Decodes a pure u64 input referenced by a command argument. */
function pureU64(data: Data, arg: unknown): bigint {
  const index = (arg as { Input: number }).Input;
  const input = data.inputs[index];
  if (input?.Pure == null) throw new Error('expected a pure input');
  return BigInt(bcs.u64().fromBase64(input.Pure.bytes));
}

describe('buildFlashArbitrageTx', () => {
  it('borrows, swaps twice, repays from the receipt and sends the rest to the recipient', () => {
    const data = buildFlashArbitrageTx(base()).getData();
    expect(data.commands.map((c) => c.$kind)).toEqual([
      'MoveCall',
      'MoveCall',
      'MoveCall',
      'MoveCall',
      'SplitCoins',
      'MoveCall',
      'TransferObjects',
    ]);

    const borrow = moveCall(data.commands[0]);
    expect(`${borrow.module}::${borrow.function}`).toBe('pool::flash_borrow_a');
    expect(borrow.typeArguments).toEqual([ALPHA, BETA, expect.stringMatching(/::markers::LP_L$/)]);
    expect(pureU64(data, borrow.arguments[1])).toBe(10_000_000n);

    const sell = moveCall(data.commands[1]);
    expect(sell.function).toBe('swap_a_for_b');
    expect(sell.typeArguments[2]).toMatch(/::markers::LP_X$/);
    expect(sell.arguments[1]).toEqual({ $kind: 'NestedResult', NestedResult: [0, 0] }); // the loan

    const buy = moveCall(data.commands[2]);
    expect(buy.function).toBe('swap_b_for_a');
    expect(buy.typeArguments[2]).toMatch(/::markers::LP_Y$/);
    // min out = principal + ceil(30 bps) + minProfit
    expect(pureU64(data, buy.arguments[2])).toBe(10_000_000n + 30_000n + 1_000n);

    const due = moveCall(data.commands[3]);
    expect(due.function).toBe('amount_due');
    expect(due.arguments).toEqual([{ $kind: 'NestedResult', NestedResult: [0, 1] }]); // &receipt

    const split = data.commands[4]?.SplitCoins;
    expect(split?.coin).toEqual({ $kind: 'Result', Result: 2 }); // proceeds of the buy-back
    expect(split?.amounts).toEqual([{ $kind: 'Result', Result: 3 }]); // amount_due, read on chain

    const repay = moveCall(data.commands[5]);
    expect(repay.function).toBe('flash_repay_a');
    expect(repay.arguments[0]).toEqual(borrow.arguments[0]); // same lender input
    expect(repay.arguments[1]).toEqual({ $kind: 'NestedResult', NestedResult: [0, 1] }); // the receipt, by value
    expect(repay.arguments[2]).toEqual({ $kind: 'NestedResult', NestedResult: [4, 0] });

    expect(data.commands[6]?.TransferObjects?.objects).toEqual([{ $kind: 'Result', Result: 2 }]);
  });

  it('uses fully resolved, mutable shared inputs when versions are known', () => {
    const data = buildFlashArbitrageTx(base()).getData();
    const shared = data.inputs.filter((i) => i.Object?.SharedObject).map((i) => i.Object?.SharedObject);
    expect(shared).toEqual([
      { objectId: id(1), initialSharedVersion: 7, mutable: true },
      { objectId: id(2), initialSharedVersion: 8, mutable: true },
      { objectId: id(3), initialSharedVersion: 9, mutable: true },
    ]);
  });

  it('builds to BCS offline when every input is resolved', async () => {
    const bytes = await buildFlashArbitrageTx(base()).build({ onlyTransactionKind: true });
    const kind = bcs.TransactionKind.parse(bytes);
    expect(kind.ProgrammableTransaction?.commands).toHaveLength(7);
  });

  it('falls back to unresolved object inputs without versions', () => {
    const p = base();
    const data = buildFlashArbitrageTx({
      ...p,
      lender: { objectId: p.lender.objectId, coinA: ALPHA, coinB: BETA, lp: p.lender.lp, flashFeeBps: 30n },
    }).getData();
    expect(data.inputs[0]?.UnresolvedObject?.objectId).toBe(id(1));
  });

  it('mirrors every call for a B-side loan', () => {
    const data = buildFlashArbitrageTx({ ...base(), side: 'B', minIntermediate: 5n }).getData();
    const fns = data.commands.filter((c) => c.MoveCall).map((c) => c.MoveCall?.function);
    expect(fns).toEqual(['flash_borrow_b', 'swap_b_for_a', 'swap_a_for_b', 'amount_due', 'flash_repay_b']);
    expect(pureU64(data, moveCall(data.commands[1]).arguments[2])).toBe(5n);
  });

  it.each<[string, Partial<FlashArbitrageParams>, RegExp]>([
    ['zero amount', { amount: 0n }, /amount must be positive/],
    ['negative profit', { minProfit: -1n }, /minProfit/],
    ['zero intermediate', { minIntermediate: 0n }, /minIntermediate/],
    ['bad recipient', { recipient: 'bob' }, /recipient/],
    ['lender reused as sell pool', { sellOn: pool(1, 'LP_L') }, /locked while its loan is open/],
    ['lender reused as buy pool', { buyOn: pool(1, 'LP_L') }, /locked while its loan is open/],
    ['different pair', { buyOn: { ...pool(3, 'LP_Y'), coinB: '0x2::sui::SUI' } }, /same pair/],
    ['bad package id', { packageId: 'nope' }, /invalid object id/],
    ['bad type tag', { sellOn: { ...pool(2, 'LP_X'), lp: 'not a type' } }, /invalid type tag/],
  ])('rejects %s', (_label, override, message) => {
    expect(() => buildFlashArbitrageTx({ ...base(), ...override })).toThrow(PtbInputError);
    expect(() => buildFlashArbitrageTx({ ...base(), ...override })).toThrow(message);
  });
});
