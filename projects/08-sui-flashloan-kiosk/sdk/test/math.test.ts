// SPDX-License-Identifier: MIT
import { readFile } from 'node:fs/promises';
import { describe, expect, it } from 'vitest';
import {
  BPS,
  MINIMUM_LIQUIDITY,
  MathError,
  type PoolSnapshot,
  U64_MAX,
  amountOut,
  deposit,
  feeUp,
  initialLp,
  isqrt,
  mulDivDown,
  mulDivUp,
  optimalBorrow,
  quoteArbitrage,
  royaltyFee,
  withdraw,
} from '../src/math.js';

/** Deterministic xorshift64 so property tests are reproducible. */
function rng(seed: bigint): () => bigint {
  let x = seed | 1n;
  return () => {
    x ^= (x << 13n) & U64_MAX;
    x ^= x >> 7n;
    x ^= (x << 17n) & U64_MAX;
    return x;
  };
}

const RUNS = 2_000;

describe('mulDiv', () => {
  it('floors and ceils', () => {
    expect(mulDivDown(7n, 3n, 2n)).toBe(10n);
    expect(mulDivUp(7n, 3n, 2n)).toBe(11n);
    expect(mulDivUp(6n, 4n, 3n)).toBe(8n);
    expect(mulDivDown(U64_MAX, U64_MAX, U64_MAX)).toBe(U64_MAX);
  });

  it('rejects zero divisors, non-u64 operands and oversized quotients', () => {
    expect(() => mulDivDown(1n, 1n, 0n)).toThrow(MathError);
    expect(() => mulDivUp(1n, 1n, 0n)).toThrow(MathError);
    expect(() => mulDivDown(U64_MAX, 2n, 1n)).toThrow(/quotient/);
    expect(() => mulDivUp(U64_MAX, 2n, 1n)).toThrow(/quotient/);
    expect(() => mulDivDown(-1n, 1n, 1n)).toThrow(/a is not a u64/);
    expect(() => mulDivUp(1n, U64_MAX + 1n, 1n)).toThrow(/b is not a u64/);
  });

  it('up is floor or floor + 1 (property)', () => {
    const next = rng(1n);
    for (let i = 0; i < RUNS; i++) {
      const d = (next() % U64_MAX) + 1n;
      const b = next() % d;
      const a = next();
      const down = mulDivDown(a, b, d);
      const up = mulDivUp(a, b, d);
      expect(up - down).toBe((a * b) % d === 0n ? 0n : 1n);
    }
  });
});

describe('feeUp', () => {
  it('matches the Move unit tests', () => {
    expect(feeUp(0n, 30n)).toBe(0n);
    expect(feeUp(1n, 1n)).toBe(1n);
    expect(feeUp(10_000n, 30n)).toBe(30n);
    expect(feeUp(10_001n, 30n)).toBe(31n);
    expect(feeUp(3_333n, 30n)).toBe(10n);
  });

  it('is the smallest fee that covers amount * bps / 10_000 (property)', () => {
    const next = rng(2n);
    for (let i = 0; i < RUNS; i++) {
      const amount = next();
      const bps = next() % (BPS + 1n);
      const fee = feeUp(amount, bps);
      expect(fee * BPS >= amount * bps).toBe(true);
      if (fee > 0n) expect((fee - 1n) * BPS < amount * bps).toBe(true);
    }
  });
});

describe('isqrt / initialLp', () => {
  it('is exact at the edges', () => {
    expect(isqrt(0n)).toBe(0n);
    expect(isqrt(1n)).toBe(1n);
    expect(isqrt(6n)).toBe(2n);
    expect(isqrt(U64_MAX * U64_MAX)).toBe(U64_MAX);
    expect(() => isqrt(-1n)).toThrow(MathError);
  });

  it('floors (property)', () => {
    const next = rng(3n);
    for (let i = 0; i < RUNS; i++) {
      const n = next() * next();
      const r = isqrt(n);
      expect(r * r <= n && (r + 1n) * (r + 1n) > n).toBe(true);
    }
  });

  it('locks MINIMUM_LIQUIDITY', () => {
    expect(initialLp(2_000_000n, 500_000n)).toBe(1_000_000n - MINIMUM_LIQUIDITY);
    expect(() => initialLp(1_000n, 1_000n)).toThrow(/too small/);
  });
});

describe('amountOut', () => {
  it('matches the Move pool tests', () => {
    expect(amountOut(10_000n, 1_000_000n, 1_000_000n, 30n)).toEqual({ amountOut: 9_871n, fee: 30n });
    expect(amountOut(50_000n, 1_000_000n, 1_000_000n, 30n)).toEqual({ amountOut: 47_482n, fee: 150n });
  });

  it('never decreases k and never drains the output reserve (property)', () => {
    const next = rng(4n);
    for (let i = 0; i < RUNS; i++) {
      const reserveIn = (next() % (U64_MAX / 2n)) + 1n;
      const reserveOut = (next() % U64_MAX) + 1n;
      const amountIn = (next() % (U64_MAX - reserveIn)) + 1n;
      const feeBps = (next() % 100n) + 1n;
      const { amountOut: out } = amountOut(amountIn, reserveIn, reserveOut, feeBps);
      expect(out < reserveOut).toBe(true);
      expect((reserveIn + amountIn) * (reserveOut - out) >= reserveIn * reserveOut).toBe(true);
    }
  });

  it('rejects out-of-range inputs', () => {
    expect(() => amountOut(0n, 0n, 1n, 30n)).toThrow(/division by zero/);
    expect(() => amountOut(U64_MAX + 1n, 1n, 1n, 30n)).toThrow(/not a u64/);
  });
});

describe('deposit / withdraw', () => {
  it('matches the Move pool test', () => {
    expect(deposit(1_010_000n, 990_129n, 1_000_000n, 101_000n, 200_000n)).toEqual({
      lp: 100_000n,
      usedA: 101_000n,
      usedB: 99_013n,
    });
  });

  it('never dilutes existing LPs, and never pulls more than offered (property)', () => {
    const next = rng(5n);
    for (let i = 0; i < RUNS; i++) {
      const reserveA = (next() % 10n ** 15n) + 1_000_000n;
      const reserveB = (next() % 10n ** 15n) + 1_000_000n;
      const supply = isqrt(reserveA * reserveB);
      const amountA = (next() % (reserveA * 2n)) + 1n;
      const amountB = (next() % (reserveB * 2n)) + 1n;
      const q = deposit(reserveA, reserveB, supply, amountA, amountB);
      expect(q.usedA <= amountA && q.usedB <= amountB).toBe(true);
      const k = reserveA * reserveB;
      const k2 = (reserveA + q.usedA) * (reserveB + q.usedB);
      const s2 = supply + q.lp;
      expect(k2 * supply * supply >= k * s2 * s2).toBe(true);

      const burn = (next() % (supply - MINIMUM_LIQUIDITY)) + 1n;
      const w = withdraw(reserveA, reserveB, supply, burn);
      const k3 = (reserveA - w.amountA) * (reserveB - w.amountB);
      const s3 = supply - burn;
      expect(k3 * supply * supply >= k * s3 * s3).toBe(true);
    }
  });
});

describe('royaltyFee', () => {
  it('takes the larger of percentage and floor, rounding up', () => {
    expect(royaltyFee(1_000_000_000n, 500n, 10_000_000n)).toBe(50_000_000n);
    expect(royaltyFee(100_000_000n, 500n, 10_000_000n)).toBe(10_000_000n);
    expect(royaltyFee(0n, 500n, 10_000_000n)).toBe(10_000_000n);
    expect(royaltyFee(41n, 250n, 0n)).toBe(2n);
  });
});

describe('arbitrage quoting', () => {
  const pool = (reserveA: bigint, reserveB: bigint): PoolSnapshot => ({
    reserveA,
    reserveB,
    swapFeeBps: 30n,
    flashFeeBps: 30n,
  });
  const lender = pool(1_000_000_000n, 1_000_000_000n);
  const x = pool(500_000_000n, 1_000_000_000n);
  const y = pool(1_000_000_000n, 1_000_000_000n);

  it('reproduces the Move cross-pool arbitrage test', () => {
    const q = quoteArbitrage(lender, x, y, 'A', 10_000_000n);
    expect(q.fee).toBe(30_000n);
    expect(q.due).toBe(10_030_000n);
    expect(q.profit).toBe(9_088_862n);
  });

  it('quotes the mirrored B-side cycle', () => {
    // Swapping the roles of the pools makes borrowing B profitable instead.
    const q = quoteArbitrage(lender, pool(1_000_000_000n, 500_000_000n), y, 'B', 10_000_000n);
    expect(q.profit).toBe(9_088_862n);
  });

  it('rejects borrow sizes the pool would refuse', () => {
    expect(() => quoteArbitrage(lender, x, y, 'A', 0n)).toThrow(/out of range/);
    expect(() => quoteArbitrage(lender, x, y, 'B', lender.reserveB + 1n)).toThrow(/out of range/);
  });

  it('finds the brute-force optimum on a small pool', () => {
    const l = pool(100_000n, 100_000n);
    const px = pool(40_000n, 100_000n);
    const py = pool(100_000n, 100_000n);
    let best = -1n << 64n;
    for (let a = 1n; a <= l.reserveA; a++) {
      const p = quoteArbitrage(l, px, py, 'A', a).profit;
      if (p > best) best = p;
    }
    const found = optimalBorrow(l, px, py, 'A');
    expect(found?.profit).toBe(best);
  });

  it('returns undefined when pools agree on the price', () => {
    expect(optimalBorrow(lender, y, y, 'A')).toBeUndefined();
  });

  /** Most profitable size by exhaustive search over `[1, reserve]` (first on ties). */
  const bruteForce = (l: PoolSnapshot, px: PoolSnapshot, py: PoolSnapshot): bigint => {
    let best = 1n;
    let bestProfit = quoteArbitrage(l, px, py, 'A', 1n).profit;
    for (let a = 2n; a <= l.reserveA; a++) {
      const p = quoteArbitrage(l, px, py, 'A', a).profit;
      if (p > bestProfit) [best, bestProfit] = [a, p];
    }
    return best;
  };

  it('borrows the whole reserve when the lender is shallower than the opportunity', () => {
    // x* is in the millions; the lender holds 2_000. Before the fix the search
    // window [x* - 256, x* + 256] lay entirely above the reserve and the
    // function wrongly reported "nothing profitable".
    const shallow = pool(2_000n, 2_000n);
    const found = optimalBorrow(shallow, x, y, 'A');
    expect(found?.borrowed).toBe(bruteForce(shallow, x, y));
    expect(found?.borrowed).toBe(2_000n);
    expect(found?.profit).toBe(quoteArbitrage(shallow, x, y, 'A', 2_000n).profit);
  });

  it('agrees with brute force when the optimum sits just below the reserve', () => {
    const px = pool(40_000n, 100_000n);
    const py = pool(100_000n, 100_000n);
    const optimum = bruteForce(pool(100_000n, 100_000n), px, py);
    for (const extra of [0n, 1n, 3n, 300n]) {
      const l = pool(optimum + extra, optimum + extra);
      expect(bruteForce(l, px, py)).toBe(optimum);
      expect(optimalBorrow(l, px, py, 'A')?.borrowed).toBe(optimum);
    }
  });

  it('reproduces the review case: 1e6 lender, 5e11 / 1e12 mispricing', () => {
    const l = pool(1_000_000n, 1_000_000n);
    const px = pool(500_000_000_000n, 1_000_000_000_000n);
    const py = pool(1_000_000_000_000n, 1_000_000_000_000n);
    const found = optimalBorrow(l, px, py, 'A');
    expect(found?.borrowed).toBe(1_000_000n);
    expect(found?.profit).toBe(985_010n);
    // Profit still rises at the reserve, so nothing smaller can beat it.
    expect(quoteArbitrage(l, px, py, 'A', 999_999n).profit < 985_010n).toBe(true);
  });

  it('quotes the whole reserve even when the window stops short of it', () => {
    const l = pool(2_000n, 2_000n);
    expect(optimalBorrow(l, x, y, 'A', 0n)?.borrowed).toBe(2_000n);
  });

  it('returns undefined for an empty lender', () => {
    expect(optimalBorrow(pool(0n, 0n), x, y, 'A')).toBeUndefined();
  });

  it('returns undefined when only real-number math sees a profit', () => {
    // In real numbers a 5 % mispricing pays: the composed swap gains
    // 0.997^2 * 21 / 20 > 1.003, the flash-fee factor. On 20-unit pools the
    // rounded-up fees eat every integer size, so there is nothing to borrow.
    expect((0.997 ** 2 * 21) / 20 > 1.003).toBe(true);
    const tiny = pool(20n, 20n);
    for (let a = 1n; a <= 20n; a++)
      expect(quoteArbitrage(tiny, pool(20n, 21n), tiny, 'A', a).profit <= 0n).toBe(true);
    expect(optimalBorrow(tiny, pool(20n, 21n), tiny, 'A')).toBeUndefined();
  });

  it('takes the whole reserve when it beats every size in the window', () => {
    // floor(x*) = 11_532; with no window, the reserve 11_533 is quoted
    // separately and is one unit of profit better.
    const px = pool(40_000n, 100_000n);
    const py = pool(100_000n, 100_000n);
    const l = pool(11_533n, 11_533n);
    const found = optimalBorrow(l, px, py, 'A', 0n);
    expect(found?.borrowed).toBe(11_533n);
    expect(found?.profit).toBe(quoteArbitrage(l, px, py, 'A', bruteForce(l, px, py)).profit);
  });

  it('starts the window at 1 when the optimum is small', () => {
    const l = pool(1_000n, 1_000n);
    const px = pool(400n, 1_000n);
    const py = pool(1_000n, 1_000n);
    const found = optimalBorrow(l, px, py, 'A');
    expect(found?.borrowed).toBe(bruteForce(l, px, py));
    expect(found !== undefined && found.borrowed < 256n).toBe(true);
  });

  it('finds the mirrored optimum on the B side', () => {
    const l = pool(100_000n, 100_000n);
    const a = optimalBorrow(l, pool(40_000n, 100_000n), pool(100_000n, 100_000n), 'A');
    const b = optimalBorrow(l, pool(100_000n, 40_000n), pool(100_000n, 100_000n), 'B');
    expect(b).toEqual(a);
  });
});

// The JSON vectors are produced by math.ts itself, so replaying them through
// math.ts would only prove the file is current (that is `npm run vectors:check`).
// The differential test is the Move replay in tests/vectors_tests.move. Here each
// vector is checked against the *definition* of what it computes, written as
// integer inequalities that share no code with math.ts.
describe('test-vectors/amm-math.json against the defining inequalities (independent of math.ts)', () => {
  interface Vectors {
    mulDiv: Record<'a' | 'b' | 'd' | 'down' | 'up', string>[];
    swap: Record<'amountIn' | 'reserveIn' | 'reserveOut' | 'feeBps' | 'amountOut' | 'fee', string>[];
    poolSwap: Record<'amountIn' | 'reserveA' | 'reserveB' | 'amountOut', string>[];
    deposit: Record<'reserveA' | 'reserveB' | 'amountA' | 'amountB' | 'lp' | 'usedA' | 'usedB', string>[];
    withdraw: Record<'reserveA' | 'reserveB' | 'lp' | 'amountA' | 'amountB', string>[];
    flashFee: Record<'amount' | 'feeBps' | 'fee', string>[];
    royalty: Record<'price' | 'bps' | 'minAmount' | 'fee', string>[];
  }
  const load = async (): Promise<Vectors> =>
    JSON.parse(
      await readFile(new URL('../../test-vectors/amm-math.json', import.meta.url), 'utf8'),
    ) as Vectors;
  const n = BigInt;
  /** `q` is floor(num / den): q * den <= num < (q + 1) * den. */
  const isFloor = (q: bigint, num: bigint, den: bigint): boolean => q * den <= num && num < (q + 1n) * den;
  /** `q` is ceil(num / den): (q - 1) * den < num <= q * den. */
  const isCeil = (q: bigint, num: bigint, den: bigint): boolean => (q - 1n) * den < num && num <= q * den;
  /** Fee of `bps` on `amount`, rounded up: the smallest fee with fee * 10_000 >= amount * bps. */
  const isFee = (fee: bigint, amount: bigint, bps: bigint): boolean => isCeil(fee, amount * bps, 10_000n);
  /** `out` is the largest output whose trade keeps k: (in + x)(out_reserve - out) >= in * out_reserve. */
  const keepsK = (out: bigint, x: bigint, rIn: bigint, rOut: bigint): boolean =>
    (rIn + x) * (rOut - out) >= rIn * rOut && (rIn + x) * (rOut - out - 1n) < rIn * rOut;
  /** Integer square root by bisection (math.ts uses Newton's method). */
  const sqrtFloor = (v: bigint): bigint => {
    let [lo, hi] = [0n, 1n << 64n];
    while (lo < hi) {
      const mid = (lo + hi + 1n) / 2n;
      if (mid * mid <= v) lo = mid;
      else hi = mid - 1n;
    }
    return lo;
  };

  it('mul_div: down is the floor and up the ceiling of a * b / d', async () => {
    for (const c of (await load()).mulDiv) {
      expect(isFloor(n(c.down), n(c.a) * n(c.b), n(c.d))).toBe(true);
      expect(isCeil(n(c.up), n(c.a) * n(c.b), n(c.d))).toBe(true);
    }
  });

  it('amount_out: the fee rounds up and the output is the largest that keeps k', async () => {
    for (const c of (await load()).swap) {
      expect(isFee(n(c.fee), n(c.amountIn), n(c.feeBps))).toBe(true);
      const net = n(c.amountIn) - n(c.fee);
      expect(keepsK(n(c.amountOut), net, n(c.reserveIn), n(c.reserveOut))).toBe(true);
    }
  });

  it('pool swaps (30 bps): same definition on real pool sizes', async () => {
    for (const c of (await load()).poolSwap) {
      const fee = (n(c.amountIn) * 30n + 9_999n) / 10_000n;
      expect(isFee(fee, n(c.amountIn), 30n)).toBe(true);
      expect(keepsK(n(c.amountOut), n(c.amountIn) - fee, n(c.reserveA), n(c.reserveB))).toBe(true);
    }
  });

  it('deposits: the largest LP mint either coin covers, and pulls rounded up', async () => {
    for (const c of (await load()).deposit) {
      const [ra, rb, a, b, lp] = [n(c.reserveA), n(c.reserveB), n(c.amountA), n(c.amountB), n(c.lp)];
      const supply = sqrtFloor(ra * rb);
      // Both coins cover `lp` shares, and at least one cannot cover `lp + 1`.
      expect(lp * ra <= a * supply && lp * rb <= b * supply).toBe(true);
      expect((lp + 1n) * ra > a * supply || (lp + 1n) * rb > b * supply).toBe(true);
      expect(isCeil(n(c.usedA), lp * ra, supply) && isCeil(n(c.usedB), lp * rb, supply)).toBe(true);
    }
  });

  it('withdrawals: each output is the pro-rata share rounded down', async () => {
    for (const c of (await load()).withdraw) {
      const supply = sqrtFloor(n(c.reserveA) * n(c.reserveB));
      expect(isFloor(n(c.amountA), n(c.lp) * n(c.reserveA), supply)).toBe(true);
      expect(isFloor(n(c.amountB), n(c.lp) * n(c.reserveB), supply)).toBe(true);
    }
  });

  it('flash fees and royalties: fees round up, royalties never go below their floor', async () => {
    const v = await load();
    for (const c of v.flashFee) expect(isFee(n(c.fee), n(c.amount), n(c.feeBps))).toBe(true);
    for (const c of v.royalty) {
      const fee = n(c.fee);
      const floor = n(c.minAmount);
      expect(fee >= floor).toBe(true);
      // Either the percentage (rounded up) is the fee, or the floor is and the percentage is below it.
      const pct = isFee(fee, n(c.price), n(c.bps));
      expect(pct || (fee === floor && floor * 10_000n >= n(c.price) * n(c.bps))).toBe(true);
    }
  });
});
