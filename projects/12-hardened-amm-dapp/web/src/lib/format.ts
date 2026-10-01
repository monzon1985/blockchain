// SPDX-License-Identifier: MIT
import { formatUnits, parseUnits } from 'viem'

/** Parses a user-typed decimal string into base units; null for anything that is not a valid amount. */
export function parseAmount(input: string, decimals: number): bigint | null {
  const value = input.trim()
  if (!/^\d*\.?\d*$/.test(value) || value === '' || value === '.') return null
  const [, fraction = ''] = value.split('.')
  if (fraction.length > decimals) return null
  try {
    return parseUnits(value, decimals)
  } catch {
    return null
  }
}

/** Highest slippage tolerance the settings accept, in basis points (exclusive): 50 %. */
export const MAX_SLIPPAGE_BPS = 5_000n

/**
 * Parses a custom slippage tolerance typed as a percentage ("0.5" -> 50 bps) with at most two decimals.
 * Returns null for anything that is not a number in [0, 50) %, including an empty or whitespace-only field, so that
 * clearing the field can never be mistaken for a typed "0".
 */
export function parseSlippagePercent(input: string): bigint | null {
  const bps = parseAmount(input, 2)
  return bps !== null && bps < MAX_SLIPPAGE_BPS ? bps : null
}

/** Formats base units for display, trimming to `maxFraction` fractional digits (rounded down, never up). */
export function formatAmount(raw: bigint, decimals: number, maxFraction = 6): string {
  const text = formatUnits(raw, decimals)
  const [whole = '0', fraction = ''] = text.split('.')
  const trimmed = fraction.slice(0, maxFraction).replace(/0+$/, '')
  const grouped = whole.replace(/\B(?=(\d{3})+(?!\d))/g, ',')
  return trimmed ? `${grouped}.${trimmed}` : grouped
}

/** Formats basis points as a percentage with two decimals (50n -> "0.50%"). */
export function formatBps(bps: bigint): string {
  const sign = bps < 0n ? '-' : ''
  const abs = bps < 0n ? -bps : bps
  return `${sign}${abs / 100n}.${(abs % 100n).toString().padStart(2, '0')}%`
}

/** Shortens an address or hash for display (0x1234…abcd). */
export function shortHex(value: string, chars = 4): string {
  return value.length <= 2 + chars * 2 ? value : `${value.slice(0, 2 + chars)}…${value.slice(-chars)}`
}

/**
 * Price of one unit of the base token in units of the quote token, as a float for display and charts only.
 * Computed with 18 extra digits of fixed-point precision before the conversion to a JavaScript number.
 */
export function displayPrice(
  reserveBase: bigint,
  reserveQuote: bigint,
  decimalsBase: number,
  decimalsQuote: number,
): number {
  if (reserveBase === 0n) return 0
  const scaled =
    (reserveQuote * 10n ** BigInt(decimalsBase) * 10n ** 18n) / (reserveBase * 10n ** BigInt(decimalsQuote))
  return Number(scaled) / 1e18
}
