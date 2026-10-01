// SPDX-License-Identifier: MIT
// Deterministic xorshift64* generator for property tests (fixed seeds, reproducible in CI).

/** Returns a function r(n) giving a uniform-ish bigint in [0, n). */
export function prng(seed: bigint): (bound: bigint) => bigint {
  let state = (seed ^ 0x9e3779b97f4a7c15n) & 0xffffffffffffffffn;
  if (state === 0n) state = 1n;
  const next64 = (): bigint => {
    state ^= state >> 12n;
    state ^= (state << 25n) & 0xffffffffffffffffn;
    state ^= state >> 27n;
    return (state * 0x2545f4914f6cdd1dn) & 0xffffffffffffffffn;
  };
  return (bound: bigint): bigint => {
    if (bound <= 0n) return 0n;
    let value = 0n;
    for (let i = 0; i < 4; i++) value = (value << 64n) | next64();
    return value % bound;
  };
}
