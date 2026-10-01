// SPDX-License-Identifier: MIT
import { bcs } from '@mysten/sui/bcs';
import { describe, expect, it } from 'vitest';
import { type KioskPurchaseParams, buildKioskPurchaseTx } from '../src/kiosk-purchase.js';
import { PtbInputError } from '../src/refs.js';
import { PKG, RECIPIENT, id } from './fixtures.js';

const ITEM_TYPE = `${PKG}::collectible::Collectible`;

const base = (): KioskPurchaseParams => ({
  packageId: PKG,
  policy: { objectId: id(0x9011c7), initialSharedVersion: 3 },
  sellerKiosk: { objectId: id(0x5e11e2), initialSharedVersion: 4 },
  itemId: id(0x17e3),
  price: 1_000_000_000n,
  maxRoyalty: 60_000_000n,
  buyerKiosk: {
    kiosk: { objectId: id(0xb0b), initialSharedVersion: 5 },
    cap: { objectId: id(0xca9), version: 12, digest: '4vJ9JU1bJJE96FWSJKvHsmmFADCg4gpZQff4P3bkLKi' },
  },
});

type Data = ReturnType<ReturnType<typeof buildKioskPurchaseTx>['getData']>;

const targets = (data: Data): string[] =>
  data.commands.map((c) => (c.MoveCall ? `${c.MoveCall.module}::${c.MoveCall.function}` : `<${c.$kind}>`));

describe('buildKioskPurchaseTx', () => {
  it('purchases, satisfies all three rules and confirms, into an existing kiosk', () => {
    const data = buildKioskPurchaseTx(base()).getData();
    expect(targets(data)).toEqual([
      '<SplitCoins>',
      'kiosk::purchase',
      'collectible::prove_cooldown',
      'kiosk::lock',
      'kiosk_lock_rule::prove',
      '<SplitCoins>',
      'royalty_rule::pay',
      '<MergeCoins>',
      'transfer_policy::confirm_request',
    ]);
    // Every generic call is instantiated with the collectible type.
    for (const c of data.commands) {
      if (c.MoveCall && c.MoveCall.typeArguments.length > 0)
        expect(c.MoveCall.typeArguments).toEqual([ITEM_TYPE]);
    }
    // The request (result #1 of purchase) threads through every rule and into confirm.
    const request = { $kind: 'NestedResult', NestedResult: [1, 1] };
    expect(data.commands[2]?.MoveCall?.arguments[2]).toEqual(request);
    expect(data.commands[4]?.MoveCall?.arguments[0]).toEqual(request);
    expect(data.commands[6]?.MoveCall?.arguments[1]).toEqual(request);
    expect(data.commands[8]?.MoveCall?.arguments[1]).toEqual(request);
    // Payment and royalty budget both come out of gas; the change goes back to gas.
    expect(data.commands[0]?.SplitCoins?.coin).toEqual({ $kind: 'GasCoin', GasCoin: true });
    expect(data.commands[7]?.MergeCoins?.destination).toEqual({ $kind: 'GasCoin', GasCoin: true });
    const priceInput = data.inputs[(data.commands[0]?.SplitCoins?.amounts[0] as { Input: number }).Input];
    expect(BigInt(bcs.u64().fromBase64(priceInput?.Pure?.bytes ?? ''))).toBe(1_000_000_000n);
  });

  it('reads the on-chain clock and passes owned / shared refs fully resolved', () => {
    const data = buildKioskPurchaseTx(base()).getData();
    const clockArg = data.commands[2]?.MoveCall?.arguments[3] as { Input: number };
    const clock = data.inputs[clockArg.Input];
    expect(clock?.Object?.SharedObject?.objectId ?? clock?.UnresolvedObject?.objectId).toBe(id(6));
    expect(data.inputs.some((i) => i.Object?.ImmOrOwnedObject?.objectId === id(0xca9))).toBe(true);
  });

  it('opens, shares and hands over a kiosk for a first-time buyer in the same PTB', () => {
    const data = buildKioskPurchaseTx({ ...base(), buyerKiosk: 'new', buyer: RECIPIENT }).getData();
    expect(targets(data)).toEqual([
      '<SplitCoins>',
      'kiosk::purchase',
      'collectible::prove_cooldown',
      'kiosk::new',
      'kiosk::lock',
      'kiosk_lock_rule::prove',
      '<SplitCoins>',
      'royalty_rule::pay',
      '<MergeCoins>',
      'transfer_policy::confirm_request',
      'transfer::public_share_object',
      '<TransferObjects>',
    ]);
    expect(data.commands[4]?.MoveCall?.arguments[0]).toEqual({ $kind: 'NestedResult', NestedResult: [3, 0] });
    expect(data.commands[11]?.TransferObjects?.objects).toEqual([
      { $kind: 'NestedResult', NestedResult: [3, 1] },
    ]);
  });

  it('builds to BCS offline when every input is resolved', async () => {
    const bytes = await buildKioskPurchaseTx(base()).build({ onlyTransactionKind: true });
    expect(bcs.TransactionKind.parse(bytes).ProgrammableTransaction?.commands).toHaveLength(9);
  });

  it('accepts owned objects by id and shared objects without versions', () => {
    const data = buildKioskPurchaseTx({
      ...base(),
      policy: { objectId: id(0x9011c7) },
      buyerKiosk: { kiosk: { objectId: id(0xb0b) }, cap: id(0xca9) },
    }).getData();
    const unresolved = data.inputs.filter((i) => i.UnresolvedObject).map((i) => i.UnresolvedObject?.objectId);
    expect(unresolved).toEqual(expect.arrayContaining([id(0x9011c7), id(0xb0b), id(0xca9)]));
  });

  it('can call the latest package while naming the Collectible type by its original package', () => {
    const latest = id(0xf1a5_0002);
    const data = buildKioskPurchaseTx({ ...base(), packageId: latest, originalPackageId: PKG }).getData();
    const calls = data.commands.flatMap((c) => (c.MoveCall ? [c.MoveCall] : []));
    // Our own modules are called through the upgraded package ...
    const ours = calls.filter((c) => c.package !== id(2));
    expect(ours.map((c) => `${c.module}::${c.function}`)).toEqual([
      'collectible::prove_cooldown',
      'kiosk_lock_rule::prove',
      'royalty_rule::pay',
    ]);
    for (const c of ours) expect(c.package).toBe(latest);
    // ... while every type argument keeps the defining id, which never changes.
    for (const c of calls) {
      if (c.typeArguments.length > 0) expect(c.typeArguments).toEqual([ITEM_TYPE]);
    }
    expect(JSON.stringify(data)).not.toContain(`${latest}::collectible::Collectible`);
  });

  it.each<[string, Partial<KioskPurchaseParams>, RegExp]>([
    ['negative price', { price: -1n }, /price/],
    ['zero royalty budget', { maxRoyalty: 0n }, /maxRoyalty/],
    ['new kiosk without buyer', { buyerKiosk: 'new' }, /buyer address/],
    ['new kiosk with bad buyer', { buyerKiosk: 'new', buyer: 'x' }, /buyer address/],
    ['bad item id', { itemId: '0xZZ' }, /invalid object id/],
    ['bad original package id', { originalPackageId: 'nope' }, /originalPackageId/],
  ])('rejects %s', (_label, override, message) => {
    expect(() => buildKioskPurchaseTx({ ...base(), ...override })).toThrow(PtbInputError);
    expect(() => buildKioskPurchaseTx({ ...base(), ...override })).toThrow(message);
  });
});
