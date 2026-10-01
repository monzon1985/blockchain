// SPDX-License-Identifier: MIT
import fc from 'fast-check'
import { describe, expect, it } from 'vitest'

import {
  QuoteError,
  UINT112_MAX,
  UINT256_MAX,
  assertReservesFit,
  burnAmounts,
  getAmountIn,
  getAmountOut,
  getAmountsIn,
  getAmountsOut,
  liquidityMinted,
  maximumAmountIn,
  minimumAmountOut,
  optimalDeposit,
  priceImpactBps,
  quote,
  sqrt,
} from '@/lib/quote'

// Fixed seed: property runs are reproducible locally and in CI.
const params = { seed: 0x12a33, numRuns: 500 }
const reserve = fc.bigInt({ min: 1_000n, max: 10n ** 33n })

/** The pair's fee-adjusted k check (AMMPair.swap), used as the oracle for the quote properties. */
function kHolds(amountIn: bigint, amountOut: bigint, reserveIn: bigint, reserveOut: bigint): boolean {
  if (amountOut >= reserveOut) return false
  const balanceIn = reserveIn + amountIn
  const balanceOut = reserveOut - amountOut
  return (balanceIn * 1000n - amountIn * 3n) * (balanceOut * 1000n) >= reserveIn * reserveOut * 1_000_000n
}

describe('quote library: known vectors', () => {
  it('matches the Uniswap v2 formulas', () => {
    expect(quote(1n, 100n, 200n)).toBe(2n)
    expect(getAmountOut(1000n, 1_000_000n, 1_000_000n)).toBe(996n)
    expect(getAmountIn(996n, 1_000_000n, 1_000_000n)).toBe(1000n)
    expect(getAmountOut(10n ** 18n, 500n * 10n ** 18n, 1_500_000n * 10n ** 6n)).toBe(2_985_047_814n) // 1 TETH into the seeded 500 TETH : 1.5M TUSD pool
  })

  it('rejects degenerate inputs with the same reasons as AMMLibrary', () => {
    const code = (fn: () => unknown) => {
      try {
        fn()
      } catch (error) {
        return error instanceof QuoteError ? error.code : 'other'
      }
      return 'none'
    }
    expect(code(() => quote(0n, 1n, 1n))).toBe('INSUFFICIENT_AMOUNT')
    expect(code(() => quote(1n, 0n, 1n))).toBe('INSUFFICIENT_LIQUIDITY')
    expect(code(() => getAmountOut(0n, 1n, 1n))).toBe('INSUFFICIENT_INPUT_AMOUNT')
    expect(code(() => getAmountOut(1n, 1n, 0n))).toBe('INSUFFICIENT_LIQUIDITY')
    expect(code(() => getAmountIn(0n, 1n, 1n))).toBe('INSUFFICIENT_OUTPUT_AMOUNT')
    expect(code(() => getAmountIn(5n, 10n, 5n))).toBe('INSUFFICIENT_LIQUIDITY')
    expect(code(() => getAmountsOut(1n, []))).toBe('INVALID_PATH')
    expect(code(() => getAmountsIn(1n, []))).toBe('INVALID_PATH')
    expect(code(() => minimumAmountOut(1n, 10_000n))).toBe('INVALID_SLIPPAGE')
    expect(code(() => maximumAmountIn(1n, -1n))).toBe('INVALID_SLIPPAGE')
  })

  it('overflows exactly where Solidity 0.8 checked arithmetic does', () => {
    const code = (fn: () => unknown) => {
      try {
        fn()
      } catch (error) {
        return error instanceof QuoteError ? error.code : 'other'
      }
      return 'none'
    }
    // The seeded TGLD/TETH pool: 500 TETH in, 250M TGLD out. amountIn * 997 * reserveOut >= 2^256 for 5e47 TETH.
    const reserveIn = 500n * 10n ** 18n
    const reserveOut = 250n * 10n ** 24n
    expect(code(() => getAmountOut(5n * 10n ** 47n, reserveIn, reserveOut))).toBe('ARITHMETIC_OVERFLOW')
    // The largest input whose products still fit, and one more wei.
    const largest = UINT256_MAX / (997n * reserveOut)
    expect(code(() => getAmountOut(largest, reserveIn, reserveOut))).toBe('none')
    expect(code(() => getAmountOut(largest + 1n, reserveIn, reserveOut))).toBe('ARITHMETIC_OVERFLOW')
    // An input that is not even a uint256.
    expect(code(() => getAmountOut(UINT256_MAX + 1n, 1n, 1n))).toBe('ARITHMETIC_OVERFLOW')
    // reserveIn * 1000 on its own.
    expect(code(() => getAmountOut(1n, UINT256_MAX / 1000n + 1n, 1n))).toBe('ARITHMETIC_OVERFLOW')
    // getAmountIn: reserveIn * amountOut, then * 1000.
    expect(code(() => getAmountIn(2n ** 60n, 2n ** 200n, 2n ** 61n))).toBe('ARITHMETIC_OVERFLOW')
    expect(code(() => getAmountIn(2n ** 50n, 2n ** 200n, 2n ** 51n))).toBe('ARITHMETIC_OVERFLOW')
    expect(code(() => getAmountIn(2n ** 40n, 2n ** 200n, 2n ** 41n))).toBe('none')
    // quote: amountA * reserveB.
    expect(code(() => quote(2n ** 200n, 1n, 2n ** 100n))).toBe('ARITHMETIC_OVERFLOW')
    // A chained quote fails on the hop that overflows.
    expect(code(() => getAmountsOut(largest + 1n, [{ reserveIn, reserveOut }]))).toBe('ARITHMETIC_OVERFLOW')
  })

  it('flags an input that would push a pair over its 112-bit reserve ceiling', () => {
    const hops = [{ reserveIn: 10n ** 18n, reserveOut: 10n ** 18n }]
    expect(() => assertReservesFit([UINT112_MAX - 10n ** 18n, 1n], hops)).not.toThrow()
    expect(() => assertReservesFit([UINT112_MAX - 10n ** 18n + 1n, 1n], hops)).toThrow(/2\^112/)
  })
})

describe('quote library: properties (the pair k check is the oracle)', () => {
  it('getAmountOut is exactly the k boundary: the quote passes, one more wei fails', () => {
    fc.assert(
      fc.property(reserve, reserve, fc.bigInt({ min: 1n, max: 10n ** 34n }), (rIn, rOut, amountIn) => {
        const out = getAmountOut(amountIn, rIn, rOut)
        expect(kHolds(amountIn, out, rIn, rOut) || out === 0n).toBe(true)
        expect(kHolds(amountIn, out + 1n, rIn, rOut)).toBe(false)
      }),
      params,
    )
  })

  it('getAmountIn buys the requested output and has at most one wei of slack', () => {
    fc.assert(
      fc.property(reserve, reserve, fc.double({ min: 1e-9, max: 0.99, noNaN: true }), (rIn, rOut, share) => {
        const out = BigInt(Math.max(1, Math.floor(Number(rOut) * share)))
        fc.pre(out < rOut)
        const amountIn = getAmountIn(out, rIn, rOut)
        expect(kHolds(amountIn, out, rIn, rOut)).toBe(true)
        expect(getAmountOut(amountIn, rIn, rOut)).toBeGreaterThanOrEqual(out)
        if (amountIn > 2n) expect(getAmountOut(amountIn - 2n, rIn, rOut)).toBeLessThan(out)
      }),
      params,
    )
  })

  it('output is monotonic in the input and always below the reserve', () => {
    fc.assert(
      fc.property(
        reserve,
        reserve,
        fc.bigInt({ min: 1n, max: 10n ** 30n }),
        fc.bigInt({ min: 0n, max: 10n ** 30n }),
        (rIn, rOut, a, d) => {
          const small = getAmountOut(a, rIn, rOut)
          const large = getAmountOut(a + d, rIn, rOut)
          expect(large).toBeGreaterThanOrEqual(small)
          expect(large).toBeLessThan(rOut)
        },
      ),
      params,
    )
  })

  it('multi-hop quotes chain single-hop quotes in both directions', () => {
    fc.assert(
      fc.property(
        reserve,
        reserve,
        reserve,
        reserve,
        fc.bigInt({ min: 1n, max: 10n ** 24n }),
        (a, b, c, d, amountIn) => {
          const hops = [
            { reserveIn: a, reserveOut: b },
            { reserveIn: c, reserveOut: d },
          ]
          const first = getAmountOut(amountIn, a, b)
          fc.pre(first > 0n)
          expect(getAmountsOut(amountIn, hops)).toEqual([amountIn, first, getAmountOut(first, c, d)])
          const target = d / 3n
          fc.pre(target > 0n)
          let back: bigint[]
          try {
            back = getAmountsIn(target, hops)
          } catch {
            return // the first hop cannot supply the intermediate amount: both the router and the library revert
          }
          expect(back[1]).toBe(getAmountIn(target, c, d))
          expect(back[0]).toBe(getAmountIn(back[1]!, a, b))
          expect(getAmountsOut(back[0]!, hops)[2]).toBeGreaterThanOrEqual(target)
        },
      ),
      params,
    )
  })

  it('checked arithmetic: a quote throws ARITHMETIC_OVERFLOW exactly when a uint256 product overflows', () => {
    const uint256 = fc.bigInt({ min: 1n, max: UINT256_MAX })
    fc.assert(
      fc.property(uint256, uint256, uint256, (amountIn, rIn, rOut) => {
        const overflows =
          amountIn * 997n > UINT256_MAX ||
          amountIn * 997n * rOut > UINT256_MAX ||
          rIn * 1000n > UINT256_MAX ||
          rIn * 1000n + amountIn * 997n > UINT256_MAX
        let result: bigint | 'overflow'
        try {
          result = getAmountOut(amountIn, rIn, rOut)
        } catch (error) {
          if (!(error instanceof QuoteError) || error.code !== 'ARITHMETIC_OVERFLOW') throw error
          result = 'overflow'
        }
        expect(result === 'overflow').toBe(overflows)
        if (result !== 'overflow') expect(result).toBe((amountIn * 997n * rOut) / (rIn * 1000n + amountIn * 997n))
      }),
      params,
    )
  })

  it('slippage bounds round toward the user never getting worse than stated', () => {
    fc.assert(
      fc.property(fc.bigInt({ min: 0n, max: 10n ** 30n }), fc.bigInt({ min: 0n, max: 9_999n }), (amount, bps) => {
        const min = minimumAmountOut(amount, bps)
        const max = maximumAmountIn(amount, bps)
        expect(min).toBeLessThanOrEqual(amount)
        expect(max).toBeGreaterThanOrEqual(amount)
        expect(min * 10_000n).toBeLessThanOrEqual(amount * (10_000n - bps))
        expect(max * 10_000n).toBeGreaterThanOrEqual(amount * (10_000n + bps))
      }),
      params,
    )
  })

  it('price impact includes the fee (~30 bps for dust) and grows with size', () => {
    const hops = [{ reserveIn: 10n ** 24n, reserveOut: 10n ** 24n }]
    const dust = 10n ** 12n
    expect(priceImpactBps(dust, getAmountOut(dust, 10n ** 24n, 10n ** 24n), hops)).toBe(30n)
    fc.assert(
      fc.property(fc.bigInt({ min: 10n ** 15n, max: 10n ** 24n }), fc.bigInt({ min: 1n, max: 10n ** 24n }), (x, d) => {
        const a = priceImpactBps(x, getAmountOut(x, 10n ** 24n, 10n ** 24n), hops)
        const b = priceImpactBps(x + d, getAmountOut(x + d, 10n ** 24n, 10n ** 24n), hops)
        expect(b).toBeGreaterThanOrEqual(a)
        expect(b).toBeLessThanOrEqual(10_000n)
      }),
      params,
    )
  })

  it('sqrt is the floor square root', () => {
    fc.assert(
      fc.property(fc.bigInt({ min: 0n, max: 2n ** 256n - 1n }), (n) => {
        const r = sqrt(n)
        expect(r * r).toBeLessThanOrEqual(n)
        expect((r + 1n) * (r + 1n)).toBeGreaterThan(n)
      }),
      params,
    )
    expect(() => sqrt(-1n)).toThrow(RangeError)
  })

  it('liquidity math mirrors AMMPair.mint / burn and the router deposit logic', () => {
    expect(liquidityMinted(10n ** 18n, 4n * 10n ** 18n, 0n, 0n, 0n)).toBe(2n * 10n ** 18n - 1000n)
    expect(liquidityMinted(1000n, 1000n, 0n, 0n, 0n)).toBe(0n)
    expect(liquidityMinted(1n, 1n, 0n, 5n, 10n)).toBe(0n)
    expect(liquidityMinted(10n, 40n, 100n, 200n, 1_000n)).toBe(100n) // min(100, 200)
    expect(burnAmounts(250n, 1000n, 3000n, 1000n)).toEqual({ amountA: 250n, amountB: 750n })
    expect(burnAmounts(1n, 1n, 1n, 0n)).toEqual({ amountA: 0n, amountB: 0n })
    expect(optimalDeposit(5n, 7n, 0n, 0n)).toEqual({ amountA: 5n, amountB: 7n })
    expect(optimalDeposit(10n, 100n, 100n, 200n)).toEqual({ amountA: 10n, amountB: 20n })
    expect(optimalDeposit(100n, 20n, 100n, 200n)).toEqual({ amountA: 10n, amountB: 20n })
  })
})
