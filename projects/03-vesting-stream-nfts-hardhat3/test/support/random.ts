// SPDX-License-Identifier: MIT

/**
 * Small deterministic PRNG (SplitMix32) for the TypeScript property tests. The seed is fixed so CI is reproducible;
 * set `PROPERTY_SEED` to explore other sequences locally.
 */
export class Rng {
  #state: number;

  constructor(seed: number = Number(process.env.PROPERTY_SEED ?? 0x3e57ed)) {
    this.#state = seed >>> 0;
  }

  /** Uniform 32-bit unsigned integer. */
  next(): number {
    this.#state = (this.#state + 0x9e3779b9) >>> 0;
    let z = this.#state;
    z = Math.imul(z ^ (z >>> 16), 0x85ebca6b) >>> 0;
    z = Math.imul(z ^ (z >>> 13), 0xc2b2ae35) >>> 0;
    return (z ^ (z >>> 16)) >>> 0;
  }

  /**
   * Uniform integer in `[min, max]`. Works for any range of safe integers, including ranges wider than 2^32 (uint40
   * timestamps): the offset is drawn with as many 32-bit words as the range needs, by rejection sampling, so there is
   * no modulo bias either.
   */
  int(min: number, max: number): number {
    if (!Number.isSafeInteger(min) || !Number.isSafeInteger(max) || min > max) {
      throw new RangeError(`int(${min}, ${max}): the bounds must be safe integers with min <= max`);
    }
    return min + Number(this.below(BigInt(max) - BigInt(min) + 1n));
  }

  /** Uniform bigint in `[0, n)`, by rejection sampling over the bit length of `n`. */
  below(n: bigint): bigint {
    if (n <= 0n) throw new RangeError(`below(${n}): the bound must be positive`);
    const bits = n.toString(2).length;
    for (;;) {
      const candidate = this.bigint(bits);
      if (candidate < n) return candidate;
    }
  }

  /** Uniform bigint with `bits` random bits. */
  bigint(bits: number): bigint {
    let value = 0n;
    for (let i = 0; i < bits; i += 32) value = (value << 32n) | BigInt(this.next());
    return value & ((1n << BigInt(bits)) - 1n);
  }

  pick<T>(items: readonly T[]): T {
    if (items.length === 0) throw new Error("pick from empty list");
    const item = items[this.int(0, items.length - 1)];
    if (item === undefined) throw new Error("index out of range");
    return item;
  }
}

/** Number of iterations for a property test: `PROPERTY_RUNS` overrides the default. */
export function runs(defaultRuns: number): number {
  return Number(process.env.PROPERTY_RUNS ?? defaultRuns);
}
