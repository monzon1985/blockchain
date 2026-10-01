// SPDX-License-Identifier: MIT
/**
 * Constant-product quote math, bit-for-bit identical to `contracts/src/libraries/AMMLibrary.sol` (which is itself
 * the Uniswap v2 math). Every amount is a raw `bigint` in token base units; nothing here touches floats.
 *
 * `bigint` is unbounded, Solidity's `uint256` is not: every intermediate product is checked like Solidity 0.8 checked
 * arithmetic, so an input the router rejects with `Panic(0x11)` is rejected here too instead of being quoted.
 *
 * The library is differential-tested against the deployed router on anvil (`test/quote.anvil.test.ts`), up to
 * 2^256 - 1, so a number rendered by the UI is a number the chain accepts.
 */

export const FEE_NUMERATOR = 997n
export const FEE_DENOMINATOR = 1000n
export const BPS = 10_000n
export const MINIMUM_LIQUIDITY = 1000n
/** Largest value of Solidity's `uint256`; checked arithmetic reverts with Panic(0x11) above it. */
export const UINT256_MAX = (1n << 256n) - 1n
/** Largest pair reserve: `AMMPair._update` reverts with `Overflow` when a balance would exceed it. */
export const UINT112_MAX = (1n << 112n) - 1n

export type QuoteErrorCode =
  | 'INSUFFICIENT_AMOUNT'
  | 'INSUFFICIENT_INPUT_AMOUNT'
  | 'INSUFFICIENT_OUTPUT_AMOUNT'
  | 'INSUFFICIENT_LIQUIDITY'
  | 'INVALID_PATH'
  | 'INVALID_SLIPPAGE'
  | 'ARITHMETIC_OVERFLOW'
  | 'RESERVE_OVERFLOW'

/** The AMMLibrary custom error each QuoteError corresponds to (checked by the differential test). */
export const SOLIDITY_ERROR: Record<QuoteErrorCode, string> = {
  INSUFFICIENT_AMOUNT: 'InsufficientAmount',
  INSUFFICIENT_INPUT_AMOUNT: 'InsufficientInputAmount',
  INSUFFICIENT_OUTPUT_AMOUNT: 'InsufficientOutputAmount',
  INSUFFICIENT_LIQUIDITY: 'InsufficientLiquidity',
  INVALID_PATH: 'InvalidPath',
  INVALID_SLIPPAGE: 'InvalidSlippage',
  ARITHMETIC_OVERFLOW: 'Panic', // Panic(0x11): checked uint256 arithmetic
  RESERVE_OVERFLOW: 'Overflow', // AMMPair.Overflow: a balance above the 112-bit reserve ceiling
}

/** Mirrors the custom errors of AMMLibrary so the UI can explain why no quote exists. */
export class QuoteError extends Error {
  readonly code: QuoteErrorCode

  constructor(code: QuoteErrorCode, message: string) {
    super(message)
    this.name = 'QuoteError'
    this.code = code
  }
}

/** Solidity 0.8 checked arithmetic: the value an intermediate expression may hold, or the Panic(0x11) revert. */
function checked(value: bigint): bigint {
  if (value > UINT256_MAX) {
    throw new QuoteError(
      'ARITHMETIC_OVERFLOW',
      "Amount too large: the contracts' 256-bit arithmetic would overflow (the router reverts with Panic 0x11)",
    )
  }
  return value
}

/** One hop of a route: reserve of the token sold and reserve of the token bought. */
export interface HopReserves {
  reserveIn: bigint
  reserveOut: bigint
}

/** AMMLibrary.quote: amountA * reserveB / reserveA, rounded down (no fee). */
export function quote(amountA: bigint, reserveA: bigint, reserveB: bigint): bigint {
  if (amountA <= 0n) throw new QuoteError('INSUFFICIENT_AMOUNT', 'Amount must be positive')
  if (reserveA <= 0n || reserveB <= 0n) throw new QuoteError('INSUFFICIENT_LIQUIDITY', 'Pool has no liquidity')
  return checked(amountA * reserveB) / reserveA
}

/** AMMLibrary.getAmountOut: the largest output the pair's k check accepts for an exact input. */
export function getAmountOut(amountIn: bigint, reserveIn: bigint, reserveOut: bigint): bigint {
  if (amountIn <= 0n) throw new QuoteError('INSUFFICIENT_INPUT_AMOUNT', 'Input amount must be positive')
  if (reserveIn <= 0n || reserveOut <= 0n) throw new QuoteError('INSUFFICIENT_LIQUIDITY', 'Pool has no liquidity')
  const amountInWithFee = checked(amountIn * FEE_NUMERATOR)
  const numerator = checked(amountInWithFee * reserveOut)
  const denominator = checked(checked(reserveIn * FEE_DENOMINATOR) + amountInWithFee)
  return numerator / denominator
}

/** AMMLibrary.getAmountIn: the input needed for an exact output (floor + 1, exactly like Uniswap v2). */
export function getAmountIn(amountOut: bigint, reserveIn: bigint, reserveOut: bigint): bigint {
  if (amountOut <= 0n) throw new QuoteError('INSUFFICIENT_OUTPUT_AMOUNT', 'Output amount must be positive')
  if (reserveIn <= 0n || reserveOut <= amountOut) {
    throw new QuoteError('INSUFFICIENT_LIQUIDITY', 'Not enough liquidity for this output')
  }
  const numerator = checked(checked(reserveIn * amountOut) * FEE_DENOMINATOR)
  const denominator = checked((reserveOut - amountOut) * FEE_NUMERATOR)
  return checked(numerator / denominator + 1n)
}

/** Chained getAmountOut: amounts[0] = amountIn, amounts[i + 1] = output of hop i. */
export function getAmountsOut(amountIn: bigint, hops: readonly HopReserves[]): bigint[] {
  if (hops.length === 0) throw new QuoteError('INVALID_PATH', 'A route needs at least one hop')
  const amounts = [amountIn]
  for (const hop of hops) {
    amounts.push(getAmountOut(amounts[amounts.length - 1]!, hop.reserveIn, hop.reserveOut))
  }
  return amounts
}

/** Chained getAmountIn, computed from the last hop backwards: amounts[last] = amountOut. */
export function getAmountsIn(amountOut: bigint, hops: readonly HopReserves[]): bigint[] {
  if (hops.length === 0) throw new QuoteError('INVALID_PATH', 'A route needs at least one hop')
  const amounts: bigint[] = new Array<bigint>(hops.length + 1)
  amounts[hops.length] = amountOut
  for (let i = hops.length - 1; i >= 0; i--) {
    const hop = hops[i]!
    amounts[i] = getAmountIn(amounts[i + 1]!, hop.reserveIn, hop.reserveOut)
  }
  return amounts
}

/**
 * Executing a route also requires every pair that receives an input to stay within its 112-bit reserves:
 * `AMMPair._update` reverts with `Overflow` otherwise, although the router's quote views do not check it. Throws a
 * RESERVE_OVERFLOW QuoteError for the first hop whose input would push its reserve over the ceiling.
 */
export function assertReservesFit(amounts: readonly bigint[], hops: readonly HopReserves[]): void {
  hops.forEach((hop, i) => {
    if (hop.reserveIn + amounts[i]! > UINT112_MAX) {
      throw new QuoteError(
        'RESERVE_OVERFLOW',
        'Amount too large for this pool: its reserves are capped at 2^112 - 1 (the pair would revert with Overflow)',
      )
    }
  })
}

function assertSlippage(slippageBps: bigint): void {
  if (slippageBps < 0n || slippageBps >= BPS) {
    throw new QuoteError('INVALID_SLIPPAGE', 'Slippage must be between 0 and 99.99 %')
  }
}

/** Minimum output for an exact-input swap: amountOut * (1 - slippage), rounded down (never above the quote). */
export function minimumAmountOut(amountOut: bigint, slippageBps: bigint): bigint {
  assertSlippage(slippageBps)
  return (amountOut * (BPS - slippageBps)) / BPS
}

/** Maximum input for an exact-output swap: amountIn * (1 + slippage), rounded up (never below the quote). */
export function maximumAmountIn(amountIn: bigint, slippageBps: bigint): bigint {
  assertSlippage(slippageBps)
  return (amountIn * (BPS + slippageBps) + BPS - 1n) / BPS
}

/**
 * Price impact of a route in basis points, LP fees included: how much less the trade returns than the same input
 * converted at every pool's mid price (reserveOut / reserveIn), i.e. 1 - amountOut / (amountIn * prod(mid)).
 * Rounded down; 0 when the output meets or exceeds the mid-price value.
 */
export function priceImpactBps(amountIn: bigint, amountOut: bigint, hops: readonly HopReserves[]): bigint {
  if (amountIn <= 0n || hops.length === 0) return 0n
  let midNumerator = amountIn
  let midDenominator = 1n
  for (const hop of hops) {
    midNumerator *= hop.reserveOut
    midDenominator *= hop.reserveIn
  }
  // midValue = midNumerator / midDenominator; impact = (midValue - amountOut) / midValue
  const shortfall = midNumerator - amountOut * midDenominator
  if (shortfall <= 0n) return 0n
  return (shortfall * BPS) / midNumerator
}

/** Integer square root, rounded down (the pair's FixedPointMathLib.sqrt). */
export function sqrt(value: bigint): bigint {
  if (value < 0n) throw new RangeError('sqrt of a negative number')
  if (value < 2n) return value
  let x = value
  let y = (x + 1n) / 2n
  while (y < x) {
    x = y
    y = (x + value / x) / 2n
  }
  return x
}

/**
 * LP tokens minted for a deposit (AMMPair.mint, protocol fee off): sqrt(a * b) - MINIMUM_LIQUIDITY for the first
 * deposit, otherwise min(a * supply / reserveA, b * supply / reserveB). Returns 0n when the deposit mints nothing
 * (the pair would revert).
 */
export function liquidityMinted(
  amountA: bigint,
  amountB: bigint,
  reserveA: bigint,
  reserveB: bigint,
  totalSupply: bigint,
): bigint {
  if (totalSupply === 0n) {
    const root = sqrt(amountA * amountB)
    return root > MINIMUM_LIQUIDITY ? root - MINIMUM_LIQUIDITY : 0n
  }
  if (reserveA === 0n || reserveB === 0n) return 0n
  const viaA = (amountA * totalSupply) / reserveA
  const viaB = (amountB * totalSupply) / reserveB
  return viaA < viaB ? viaA : viaB
}

/** Tokens paid out for burning `liquidity` (AMMPair.burn with balances equal to reserves, protocol fee off). */
export function burnAmounts(
  liquidity: bigint,
  reserveA: bigint,
  reserveB: bigint,
  totalSupply: bigint,
): { amountA: bigint; amountB: bigint } {
  if (totalSupply === 0n) return { amountA: 0n, amountB: 0n }
  return { amountA: (liquidity * reserveA) / totalSupply, amountB: (liquidity * reserveB) / totalSupply }
}

/**
 * Router `_addLiquidity`: the deposit actually taken for the desired amounts at the current ratio.
 * First deposit: both desired amounts. Otherwise the side that binds is used in full and the other is quoted.
 */
export function optimalDeposit(
  amountADesired: bigint,
  amountBDesired: bigint,
  reserveA: bigint,
  reserveB: bigint,
): { amountA: bigint; amountB: bigint } {
  if (reserveA === 0n && reserveB === 0n) return { amountA: amountADesired, amountB: amountBDesired }
  const amountBOptimal = quote(amountADesired, reserveA, reserveB)
  if (amountBOptimal <= amountBDesired) return { amountA: amountADesired, amountB: amountBOptimal }
  return { amountA: quote(amountBDesired, reserveB, reserveA), amountB: amountBDesired }
}
