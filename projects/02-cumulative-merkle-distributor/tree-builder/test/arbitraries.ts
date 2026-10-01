// SPDX-License-Identifier: MIT
import fc from 'fast-check';
import { bytesToHex, getAddress, maxUint256, type Address, type Hex } from 'viem';
import type { Allocation } from '../src/tree.ts';

export const hash32: fc.Arbitrary<Hex> = fc.uint8Array({ minLength: 32, maxLength: 32 }).map((b) => bytesToHex(b));

export const address: fc.Arbitrary<Address> = fc
  .uint8Array({ minLength: 20, maxLength: 20 })
  .filter((b) => b.some((x) => x !== 0))
  .map((b) => getAddress(bytesToHex(b)));

/** Amounts biased towards the interesting edges: tiny, token-sized and near 2^256. */
export const amount: fc.Arbitrary<bigint> = fc.oneof(
  fc.bigInt({ min: 1n, max: 1000n }),
  fc.bigInt({ min: 1n, max: 10n ** 30n }),
  fc.bigInt({ min: maxUint256 - 1000n, max: maxUint256 }),
);

/** Distinct (account, token) pairs drawn from small pools, so accounts hold several tokens and tokens several accounts. */
export function allocations(minLength = 1, maxLength = 40): fc.Arbitrary<Allocation[]> {
  return fc
    .tuple(
      fc.uniqueArray(address, { minLength: Math.max(1, minLength), maxLength: Math.max(12, minLength) }),
      fc.uniqueArray(address, { minLength: 1, maxLength: 4 }),
    )
    .chain(([accounts, tokens]) =>
      fc.uniqueArray(
        fc.record({
          account: fc.constantFrom(...accounts),
          token: fc.constantFrom(...tokens),
          cumulativeAmount: amount,
        }),
        {
          minLength,
          maxLength: Math.min(maxLength, accounts.length * tokens.length),
          selector: (a) => `${a.account}:${a.token}`,
        },
      ),
    )
    .filter((xs) => xs.length >= minLength);
}
