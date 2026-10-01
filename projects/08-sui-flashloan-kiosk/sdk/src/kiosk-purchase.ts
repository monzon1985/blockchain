// SPDX-License-Identifier: MIT
//
// PTB 2: buy a Collectible from a kiosk and satisfy every rule of its
// TransferPolicy in ONE programmable transaction.
//
//   SplitCoins(gas, [price])                                   -> payment
//   MoveCall  0x2::kiosk::purchase<T>(seller, item, payment)   -> (item, request)
//   MoveCall  collectible::prove_cooldown(&mut item, policy, &mut request, clock)
//  [MoveCall  0x2::kiosk::new()                                -> (kiosk, cap)]   first-time buyer
//   MoveCall  0x2::kiosk::lock<T>(kiosk, cap, policy, item)
//   MoveCall  kiosk_lock_rule::prove<T>(&mut request, &kiosk)
//   SplitCoins(gas, [maxRoyalty])                              -> budget
//   MoveCall  royalty_rule::pay<T>(policy, &mut request, &mut budget)
//   MergeCoins(gas, [budget])                                  (change back to gas)
//   MoveCall  0x2::transfer_policy::confirm_request<T>(policy, request)
//  [MoveCall  0x2::transfer::public_share_object<Kiosk>(kiosk); TransferObjects([cap], buyer)]
//
// `TransferRequest` is a hot potato, exactly like the flash receipt: if any
// rule is skipped, `confirm_request` aborts and the purchase never happened.
//
// Package ids after an upgrade: Move calls should target the latest package
// (`packageId`), while a struct type keeps the id of the package that first
// defined it. Sui resolves a type argument written with an upgraded package id
// to the type's defining id, so `packageId` alone works (the e2e suite buys
// through a real upgrade that way); `originalPackageId` makes the builder emit
// the canonical type tag instead.

import { Transaction, type TransactionObjectArgument } from '@mysten/sui/transactions';
import { isValidSuiAddress, normalizeSuiAddress } from '@mysten/sui/utils';
import {
  type OwnedRef,
  PtbInputError,
  type SharedRef,
  nth,
  objectId,
  ownedInput,
  sharedInput,
} from './refs.js';

/** The buyer's existing kiosk, or `'new'` to open one inside the same PTB. */
export type BuyerKiosk = { kiosk: SharedRef; cap: OwnedRef } | 'new';

/** Inputs of `buildKioskPurchaseTx`. */
export interface KioskPurchaseParams {
  /** Latest package id of `flash_kiosk`: the target of every Move call. */
  packageId: string;
  /**
   * Id of the package version that first published `flash_kiosk`, i.e. the
   * defining id of `collectible::Collectible`, which upgrades never change.
   * Used for the `Collectible` type arguments; defaults to `packageId`.
   */
  originalPackageId?: string;
  /** The shared `TransferPolicy<Collectible>`. */
  policy: SharedRef;
  /** The seller's kiosk. */
  sellerKiosk: SharedRef;
  /** Listed item. */
  itemId: string;
  /** Listed price in MIST (must match the listing exactly). */
  price: bigint;
  /**
   * Upper bound on the royalty, in MIST. The rule takes exactly what is due
   * (see `royaltyFee`) and the change is merged back into the gas coin, so a
   * misconfigured policy can never take more than this.
   */
  maxRoyalty: bigint;
  /** Where the item gets locked. */
  buyerKiosk: BuyerKiosk;
  /** Owner of the new kiosk's cap when `buyerKiosk === 'new'`. */
  buyer?: string;
}

/** Builds the single-transaction compliant purchase (see the file header). */
export function buildKioskPurchaseTx(p: KioskPurchaseParams): Transaction {
  if (p.price < 0n) throw new PtbInputError('price must be non-negative');
  if (p.maxRoyalty <= 0n) throw new PtbInputError('maxRoyalty must be positive');
  if (p.buyerKiosk === 'new' && (p.buyer === undefined || !isValidSuiAddress(normalizeSuiAddress(p.buyer)))) {
    throw new PtbInputError('a valid buyer address is required to open a new kiosk');
  }
  const pkg = objectId(p.packageId, 'packageId');
  const typeOrigin = objectId(p.originalPackageId ?? p.packageId, 'originalPackageId');
  const itemType = `${typeOrigin}::collectible::Collectible`;
  const tx = new Transaction();

  const policy = sharedInput(tx, p.policy, true, 'policy');
  const seller = sharedInput(tx, p.sellerKiosk, true, 'sellerKiosk');
  const payment = nth(tx.splitCoins(tx.gas, [tx.pure.u64(p.price)]), 0);
  const purchase = tx.moveCall({
    target: '0x2::kiosk::purchase',
    typeArguments: [itemType],
    arguments: [seller, tx.pure.id(objectId(p.itemId, 'itemId')), payment],
  });
  const item = nth(purchase, 0);
  const request = nth(purchase, 1);
  tx.moveCall({
    target: `${pkg}::collectible::prove_cooldown`,
    arguments: [item, policy, request, tx.object.clock()],
  });

  let kiosk: TransactionObjectArgument;
  let cap: TransactionObjectArgument;
  if (p.buyerKiosk === 'new') {
    const opened = tx.moveCall({ target: '0x2::kiosk::new' });
    kiosk = nth(opened, 0);
    cap = nth(opened, 1);
  } else {
    kiosk = sharedInput(tx, p.buyerKiosk.kiosk, true, 'buyerKiosk');
    cap = ownedInput(tx, p.buyerKiosk.cap, 'buyerKioskCap');
  }
  tx.moveCall({
    target: '0x2::kiosk::lock',
    typeArguments: [itemType],
    arguments: [kiosk, cap, policy, item],
  });
  tx.moveCall({
    target: `${pkg}::kiosk_lock_rule::prove`,
    typeArguments: [itemType],
    arguments: [request, kiosk],
  });

  const budget = nth(tx.splitCoins(tx.gas, [tx.pure.u64(p.maxRoyalty)]), 0);
  tx.moveCall({
    target: `${pkg}::royalty_rule::pay`,
    typeArguments: [itemType],
    arguments: [policy, request, budget],
  });
  tx.mergeCoins(tx.gas, [budget]);
  tx.moveCall({
    target: '0x2::transfer_policy::confirm_request',
    typeArguments: [itemType],
    arguments: [policy, request],
  });

  if (p.buyerKiosk === 'new') {
    tx.moveCall({
      target: '0x2::transfer::public_share_object',
      typeArguments: ['0x2::kiosk::Kiosk'],
      arguments: [kiosk],
    });
    tx.transferObjects([cap], normalizeSuiAddress(p.buyer as string));
  }
  return tx;
}
