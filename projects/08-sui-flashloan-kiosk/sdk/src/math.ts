// SPDX-License-Identifier: MIT
//
// BigInt reference implementation of the on-chain math in sources/math.move,
// sources/pool.move and sources/royalty_rule.move. It is used for quoting in
// the PTB builders and as the independent side of the differential test
// vectors (test-vectors/amm-math.json -> tests/vectors_tests.move).
//
// The Move code widens u64 to u128; here every intermediate is an exact
// BigInt and the only overflow check is on the final u64 result, so the two
// implementations fail and round in the same places for different reasons.

/** Basis-point denominator. */
export const BPS = 10_000n;
/** Largest u64. */
export const U64_MAX = (1n << 64n) - 1n;
/** LP units locked in every pool at creation (pool::MINIMUM_LIQUIDITY). */
export const MINIMUM_LIQUIDITY = 1_000n;

/** Thrown where the Move code would abort. */
export class MathError extends Error {
  override name = 'MathError';
}

function assertU64(value: bigint, label: string): void {
  if (value < 0n || value > U64_MAX) throw new MathError(`${label} is not a u64: ${value}`);
}

/** `floor(a * b / d)`; throws on a zero divisor or a quotient above u64. */
export function mulDivDown(a: bigint, b: bigint, d: bigint): bigint {
  assertU64(a, 'a');
  assertU64(b, 'b');
  assertU64(d, 'd');
  if (d === 0n) throw new MathError('division by zero');
  const q = (a * b) / d;
  assertU64(q, 'quotient');
  return q;
}

/** `ceil(a * b / d)`; throws on a zero divisor or a quotient above u64. */
export function mulDivUp(a: bigint, b: bigint, d: bigint): bigint {
  assertU64(a, 'a');
  assertU64(b, 'b');
  assertU64(d, 'd');
  if (d === 0n) throw new MathError('division by zero');
  const q = (a * b + d - 1n) / d;
  assertU64(q, 'quotient');
  return q;
}

/** Fee of `bps` on `amount`, rounded up (math::fee_up!). */
export function feeUp(amount: bigint, bps: bigint): bigint {
  return mulDivUp(amount, bps, BPS);
}

/** Integer square root, rounded down (Newton's method). */
export function isqrt(n: bigint): bigint {
  if (n < 0n) throw new MathError('negative square root');
  if (n < 2n) return n;
  let x = n;
  let y = (x + 1n) / 2n;
  while (y < x) {
    x = y;
    y = (x + n / x) / 2n;
  }
  return x;
}

/** Result of a constant-product swap quote. */
export interface SwapQuote {
  amountOut: bigint;
  fee: bigint;
}

/** math::amount_out: input fee rounded up, output rounded down. */
export function amountOut(
  amountIn: bigint,
  reserveIn: bigint,
  reserveOut: bigint,
  feeBps: bigint,
): SwapQuote {
  assertU64(amountIn, 'amountIn');
  assertU64(reserveIn, 'reserveIn');
  assertU64(reserveOut, 'reserveOut');
  const fee = feeUp(amountIn, feeBps);
  const inAfterFee = amountIn - fee;
  const denominator = reserveIn + inAfterFee;
  if (denominator === 0n) throw new MathError('division by zero');
  return { amountOut: (inAfterFee * reserveOut) / denominator, fee };
}

/** LP minted by the first deposit (after locking MINIMUM_LIQUIDITY). */
export function initialLp(amountA: bigint, amountB: bigint): bigint {
  const lp = isqrt(amountA * amountB);
  if (lp <= MINIMUM_LIQUIDITY) throw new MathError('initial liquidity too small');
  return lp - MINIMUM_LIQUIDITY;
}

/** Outcome of pool::add_liquidity. */
export interface DepositQuote {
  lp: bigint;
  usedA: bigint;
  usedB: bigint;
}

/** pool::add_liquidity: LP rounded down, pulled amounts rounded up. */
export function deposit(
  reserveA: bigint,
  reserveB: bigint,
  supply: bigint,
  amountA: bigint,
  amountB: bigint,
): DepositQuote {
  const fromA = mulDivDown(amountA, supply, reserveA);
  const fromB = mulDivDown(amountB, supply, reserveB);
  const lp = fromA < fromB ? fromA : fromB;
  return { lp, usedA: mulDivUp(lp, reserveA, supply), usedB: mulDivUp(lp, reserveB, supply) };
}

/** pool::remove_liquidity: both outputs rounded down. */
export function withdraw(
  reserveA: bigint,
  reserveB: bigint,
  supply: bigint,
  lp: bigint,
): { amountA: bigint; amountB: bigint } {
  return { amountA: mulDivDown(lp, reserveA, supply), amountB: mulDivDown(lp, reserveB, supply) };
}

/** royalty_rule::fee_amount: `max(ceil(price * bps / 10_000), min)`. */
export function royaltyFee(price: bigint, amountBps: bigint, minAmount: bigint): bigint {
  const pct = feeUp(price, amountBps);
  return pct > minAmount ? pct : minAmount;
}

/** Snapshot of the pool fields the quoting functions need. */
export interface PoolSnapshot {
  reserveA: bigint;
  reserveB: bigint;
  swapFeeBps: bigint;
  flashFeeBps: bigint;
}

/** Which reserve a flash loan borrows from. */
export type Side = 'A' | 'B';

/** Step-by-step quote of a borrow -> swap -> swap -> repay cycle. */
export interface ArbitrageQuote {
  borrowed: bigint;
  fee: bigint;
  due: bigint;
  /** Output of the first swap (the *other* coin). */
  intermediate: bigint;
  /** Output of the second swap (the borrowed coin again). */
  final: bigint;
  /** `final - due`; negative when the cycle loses money. */
  profit: bigint;
}

/**
 * Quotes the cycle the flash-arbitrage PTB executes: borrow `amount` of `side`
 * from `lender`, sell it on `sellOn`, buy it back on `buyOn`, repay.
 */
export function quoteArbitrage(
  lender: PoolSnapshot,
  sellOn: PoolSnapshot,
  buyOn: PoolSnapshot,
  side: Side,
  amount: bigint,
): ArbitrageQuote {
  const reserve = side === 'A' ? lender.reserveA : lender.reserveB;
  if (amount <= 0n || amount > reserve) throw new MathError('borrow amount out of range');
  const fee = feeUp(amount, lender.flashFeeBps);
  const due = amount + fee;
  const first =
    side === 'A'
      ? amountOut(amount, sellOn.reserveA, sellOn.reserveB, sellOn.swapFeeBps)
      : amountOut(amount, sellOn.reserveB, sellOn.reserveA, sellOn.swapFeeBps);
  const second =
    side === 'A'
      ? amountOut(first.amountOut, buyOn.reserveB, buyOn.reserveA, buyOn.swapFeeBps)
      : amountOut(first.amountOut, buyOn.reserveA, buyOn.reserveB, buyOn.swapFeeBps);
  return {
    borrowed: amount,
    fee,
    due,
    intermediate: first.amountOut,
    final: second.amountOut,
    profit: second.amountOut - due,
  };
}

/**
 * Borrow size that maximises `quoteArbitrage(...).profit`.
 *
 * Two chained constant-product swaps compose into `f(x) = a*x / (b + c*x)`
 * with `a = gx*gy*Xout*Yout`, `b = Xin*Yin`, `c = gx*(Yin + gy*Xout)` (`g = 1 -
 * fee`), so `f(x) - (1 + flashFee)*x` peaks at
 * `x* = (sqrt(a*b / (1 + flashFee)) - b) / c`. The closed form is evaluated in
 * floating point as a starting point and clamped to what the lender can lend:
 * when the opportunity is deeper than the lender's reserve, `x*` lies above it
 * and the best feasible size is at (or just below) the whole reserve. Every
 * integer in `[center - window, center + window] ∩ [1, reserve]` is then quoted
 * exactly with the on-chain rounding, the whole reserve is always quoted too,
 * and the best size is returned. Integer rounding makes the true discrete
 * optimum noisy by a few base units, so on very deep pools it can sit outside
 * the window; the result is then optimal to within that noise.
 * Returns `undefined` when no size is profitable.
 */
export function optimalBorrow(
  lender: PoolSnapshot,
  sellOn: PoolSnapshot,
  buyOn: PoolSnapshot,
  side: Side,
  window = 256n,
): ArbitrageQuote | undefined {
  const max = side === 'A' ? lender.reserveA : lender.reserveB;
  if (max <= 0n) return undefined;
  const [xIn, xOut] = side === 'A' ? [sellOn.reserveA, sellOn.reserveB] : [sellOn.reserveB, sellOn.reserveA];
  const [yIn, yOut] = side === 'A' ? [buyOn.reserveB, buyOn.reserveA] : [buyOn.reserveA, buyOn.reserveB];
  const gx = 1 - Number(sellOn.swapFeeBps) / Number(BPS);
  const gy = 1 - Number(buyOn.swapFeeBps) / Number(BPS);
  const growth = 1 + Number(lender.flashFeeBps) / Number(BPS);
  const a = gx * gy * Number(xOut) * Number(yOut);
  const b = Number(xIn) * Number(yIn);
  const c = gx * (Number(yIn) + gy * Number(xOut));
  if (a / b <= growth) return undefined;

  const xStar = (Math.sqrt((a * b) / growth) - b) / c;
  const unclamped = BigInt(Math.max(1, Math.floor(xStar)));
  const center = unclamped < max ? unclamped : max;
  const from = center > window ? center - window : 1n;
  const to = center + window < max ? center + window : max;
  // `from <= center <= to` because `1 <= center <= max`, so the window is never empty.
  let best = quoteArbitrage(lender, sellOn, buyOn, side, from);
  for (let amount = from + 1n; amount <= to; amount++) {
    const quote = quoteArbitrage(lender, sellOn, buyOn, side, amount);
    if (quote.profit > best.profit) best = quote;
  }
  if (to < max) {
    const whole = quoteArbitrage(lender, sellOn, buyOn, side, max);
    if (whole.profit > best.profit) best = whole;
  }
  return best.profit > 0n ? best : undefined;
}
