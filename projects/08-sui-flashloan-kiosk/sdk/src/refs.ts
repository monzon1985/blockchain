// SPDX-License-Identifier: MIT
//
// Object references accepted by the PTB builders, and the helpers that turn
// them into transaction inputs.

import type { Transaction, TransactionObjectArgument, TransactionResult } from '@mysten/sui/transactions';
import { isValidSuiObjectId, normalizeStructTag, normalizeSuiObjectId } from '@mysten/sui/utils';

/**
 * A shared object. With `initialSharedVersion` the builder emits a fully
 * resolved `SharedObject` input (no RPC round trip at build time, and the
 * transaction can be built offline); without it the SDK resolves the object
 * through the client when the transaction is built.
 */
export interface SharedRef {
  objectId: string;
  initialSharedVersion?: string | number;
}

/** An owned object, either by id (resolved at build time) or fully resolved. */
export type OwnedRef = string | { objectId: string; version: string | number; digest: string };

/** A pool: its shared reference plus its three type arguments. */
export interface PoolRef extends SharedRef {
  /** Type of coin A. */
  coinA: string;
  /** Type of coin B. */
  coinB: string;
  /** LP marker type; the pool's LP coin is `<flash_kiosk>::pool::LpCoin<lp>`. */
  lp: string;
}

/** Thrown by the builders on inputs that would certainly abort on chain. */
export class PtbInputError extends Error {
  override name = 'PtbInputError';
}

/** Validates and normalises an object id. */
export function objectId(id: string, label: string): string {
  if (!isValidSuiObjectId(normalizeSuiObjectId(id)))
    throw new PtbInputError(`${label}: invalid object id ${id}`);
  return normalizeSuiObjectId(id);
}

/** Normalises a Move type tag such as `0x2::sui::SUI`. */
export function typeTag(tag: string): string {
  try {
    return normalizeStructTag(tag);
  } catch {
    throw new PtbInputError(`invalid type tag ${tag}`);
  }
}

/** Adds a shared object input, fully resolved when possible. */
export function sharedInput(
  tx: Transaction,
  ref: SharedRef,
  mutable: boolean,
  label: string,
): TransactionObjectArgument {
  const id = objectId(ref.objectId, label);
  if (ref.initialSharedVersion === undefined) return tx.object(id);
  return tx.sharedObjectRef({ objectId: id, initialSharedVersion: ref.initialSharedVersion, mutable });
}

/** Adds an owned object input, fully resolved when possible. */
export function ownedInput(tx: Transaction, ref: OwnedRef, label: string): TransactionObjectArgument {
  if (typeof ref === 'string') return tx.object(objectId(ref, label));
  return tx.objectRef({ objectId: objectId(ref.objectId, label), version: ref.version, digest: ref.digest });
}

/** `[A, B, LP]` type arguments of a pool, normalised. */
export function poolTypeArgs(pool: PoolRef): [string, string, string] {
  return [typeTag(pool.coinA), typeTag(pool.coinB), typeTag(pool.lp)];
}

/**
 * The `index`-th value returned by a Move call. `TransactionResult` is typed as
 * an open-ended array, so destructuring yields `T | undefined` under
 * `noUncheckedIndexedAccess`; this keeps the builders free of `!` assertions.
 */
export function nth(result: TransactionResult, index: number): TransactionObjectArgument {
  const value = result[index];
  if (value === undefined) throw new PtbInputError(`missing result #${index}`);
  return value;
}
