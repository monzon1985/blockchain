// SPDX-License-Identifier: MIT
// Deterministic ids and types shared by the builder tests (no network).

import type { PoolRef } from '../src/refs.js';

export const id = (n: number): string => `0x${n.toString(16).padStart(64, '0')}`;

export const PKG = id(0xf1a5);
export const COINS = id(0xc014);
export const ALPHA = `${COINS}::alpha::ALPHA`;
export const BETA = `${COINS}::beta::BETA`;

export const pool = (n: number, lp: string, initialSharedVersion?: number): PoolRef => ({
  objectId: id(n),
  coinA: ALPHA,
  coinB: BETA,
  lp: `${COINS}::markers::${lp}`,
  ...(initialSharedVersion === undefined ? {} : { initialSharedVersion }),
});

export const RECIPIENT = id(0xbeef);
