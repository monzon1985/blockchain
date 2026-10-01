// SPDX-License-Identifier: MIT
import { getAddress, getCreate2Address, isAddress, isHex, keccak256, encodePacked, type Address, type Hex } from 'viem'

import type { Deployment, PairInfo, TokenInfo } from './types'

/** Sorts two token addresses exactly like AMMLibrary.sortTokens. */
export function sortTokens(a: Address, b: Address): [Address, Address] {
  return BigInt(a) < BigInt(b) ? [a, b] : [b, a]
}

/** CREATE2 address of the pair for two tokens (AMMLibrary.pairFor). */
export function pairFor(factory: Address, initCodeHash: Hex, a: Address, b: Address): Address {
  const [token0, token1] = sortTokens(a, b)
  return getCreate2Address({
    from: factory,
    salt: keccak256(encodePacked(['address', 'address'], [token0, token1])),
    bytecodeHash: initCodeHash,
  })
}

function fail(message: string): never {
  throw new Error(`Invalid deployment manifest: ${message}`)
}

function asAddress(value: unknown, field: string): Address {
  if (typeof value !== 'string' || !isAddress(value)) fail(`${field} is not an address`)
  return getAddress(value)
}

function asNumber(value: unknown, field: string): number {
  if (typeof value !== 'number' || !Number.isSafeInteger(value) || value < 0) fail(`${field} is not a number`)
  return value
}

/**
 * Validates the raw JSON written by DeployLocal.s.sol and resolves pairs to token objects. Every pair address is
 * re-derived with CREATE2 from the factory and init-code hash, so a tampered manifest cannot point the UI at a
 * contract that is not a pair of this factory.
 */
export function parseDeployment(raw: unknown): Deployment {
  if (typeof raw !== 'object' || raw === null) fail('not an object')
  const json = raw as Record<string, unknown>
  const factory = asAddress(json['factory'], 'factory')
  const router = asAddress(json['router'], 'router')
  const pairInitCodeHash = json['pairInitCodeHash']
  if (typeof pairInitCodeHash !== 'string' || !isHex(pairInitCodeHash) || pairInitCodeHash.length !== 66) {
    fail('pairInitCodeHash is not a 32-byte hex string')
  }

  const rawTokens = json['tokens']
  if (typeof rawTokens !== 'object' || rawTokens === null) fail('tokens missing')
  const tokens: TokenInfo[] = Object.entries(rawTokens as Record<string, Record<string, unknown>>).map(
    ([key, token]) => {
      const decimals = asNumber(token['decimals'], `tokens.${key}.decimals`)
      if (decimals > 36) fail(`tokens.${key}.decimals out of range`)
      const symbol = token['symbol']
      const name = token['name']
      if (typeof symbol !== 'string' || typeof name !== 'string') fail(`tokens.${key} metadata missing`)
      return { address: asAddress(token['address'], `tokens.${key}.address`), symbol, name, decimals }
    },
  )
  const bySymbol = new Map(tokens.map((token) => [token.symbol, token]))

  const rawPairs = json['pairs']
  if (typeof rawPairs !== 'object' || rawPairs === null) fail('pairs missing')
  const pairs: PairInfo[] = Object.entries(rawPairs as Record<string, unknown>).map(([key, value]) => {
    const [symbolA, symbolB] = key.split('-')
    const a = symbolA ? bySymbol.get(symbolA) : undefined
    const b = symbolB ? bySymbol.get(symbolB) : undefined
    if (!a || !b) fail(`pairs.${key} references unknown tokens`)
    const address = asAddress(value, `pairs.${key}`)
    if (pairFor(factory, pairInitCodeHash, a.address, b.address) !== address) {
      fail(`pairs.${key} is not the CREATE2 address of ${symbolA}/${symbolB}`)
    }
    const [token0] = sortTokens(a.address, b.address)
    return token0 === a.address ? { address, token0: a, token1: b } : { address, token0: b, token1: a }
  })

  return {
    chainId: asNumber(json['chainId'], 'chainId'),
    startBlock: asNumber(json['startBlock'], 'startBlock'),
    factory,
    router,
    pairInitCodeHash,
    tokens,
    pairs,
  }
}
