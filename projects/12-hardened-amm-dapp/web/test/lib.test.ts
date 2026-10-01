// SPDX-License-Identifier: MIT
import {
  BaseError,
  ChainMismatchError,
  ContractFunctionRevertedError,
  UserRejectedRequestError,
  encodeErrorResult,
  getAddress,
  zeroAddress,
  type Address,
} from 'viem'
import { ConnectorChainMismatchError } from 'wagmi'
import { describe, expect, it } from 'vitest'

import { ammPairAbi, ammRouterAbi } from '@/generated'
import { aggregatePoolEvents, type PoolEvent } from '@/lib/analytics'
import { WRONG_NETWORK_MESSAGE, ammErrorsAbi, decodeError, decodeRevertData, describeError } from '@/lib/errors'
import {
  MAX_SLIPPAGE_BPS,
  displayPrice,
  formatAmount,
  formatBps,
  parseAmount,
  parseSlippagePercent,
  shortHex,
} from '@/lib/format'
import { pairFor, parseDeployment, sortTokens } from '@/lib/manifest'
import { findRoute, routeHops } from '@/lib/route'
import { localChain } from '@/lib/wagmi'

const TUSD = getAddress('0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0')
const TETH = getAddress('0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9')
const TGLD = getAddress('0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9')
const FACTORY = getAddress('0x5FbDB2315678afecb367f032d93F642f64180aa3')
const HASH = '0x6c3b29826cb00df099e118efdc8133aee28c50d7f12f5ab955591eac8ad8e4f0'

function manifest(overrides: Record<string, unknown> = {}) {
  return {
    chainId: 31337,
    startBlock: 0,
    factory: FACTORY,
    router: '0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512',
    pairInitCodeHash: HASH,
    tokens: {
      TUSD: { address: TUSD, symbol: 'TUSD', name: 'Test Dollar', decimals: 6 },
      TETH: { address: TETH, symbol: 'TETH', name: 'Test Ether', decimals: 18 },
      TGLD: { address: TGLD, symbol: 'TGLD', name: 'Test Gold', decimals: 24 },
    },
    pairs: { 'TETH-TUSD': pairFor(FACTORY, HASH, TETH, TUSD), 'TGLD-TETH': pairFor(FACTORY, HASH, TGLD, TETH) },
    ...overrides,
  }
}

describe('format', () => {
  it('parses user input strictly', () => {
    expect(parseAmount('1.5', 6)).toBe(1_500_000n)
    expect(parseAmount('.5', 18)).toBe(5n * 10n ** 17n)
    expect(parseAmount('1.0000001', 6)).toBeNull() // more decimals than the token has
    expect(parseAmount('1e3', 18)).toBeNull()
    expect(parseAmount('-1', 18)).toBeNull()
    expect(parseAmount('', 18)).toBeNull()
    expect(parseAmount('.', 18)).toBeNull()
  })

  it('parses a custom slippage: an empty field is "no value", never 0 %', () => {
    expect(parseSlippagePercent('0.5')).toBe(50n)
    expect(parseSlippagePercent('.5')).toBe(50n)
    expect(parseSlippagePercent(' 2 ')).toBe(200n)
    expect(parseSlippagePercent('49.99')).toBe(MAX_SLIPPAGE_BPS - 1n)
    expect(parseSlippagePercent('0')).toBe(0n) // an explicit zero is a deliberate choice
    expect(parseSlippagePercent('')).toBeNull() // Number('') === 0: the bug this parser replaces
    expect(parseSlippagePercent('   ')).toBeNull()
    expect(parseSlippagePercent('50')).toBeNull()
    expect(parseSlippagePercent('0.125')).toBeNull() // finer than a basis point
    expect(parseSlippagePercent('1e1')).toBeNull()
    expect(parseSlippagePercent('0x10')).toBeNull()
    expect(parseSlippagePercent('-1')).toBeNull()
  })

  it('formats without rounding up', () => {
    expect(formatAmount(1_234_567_891n, 6)).toBe('1,234.567891')
    expect(formatAmount(1_999_999n, 6, 2)).toBe('1.99')
    expect(formatAmount(10n ** 24n, 24)).toBe('1')
    expect(formatBps(50n)).toBe('0.50%')
    expect(formatBps(-1234n)).toBe('-12.34%')
    expect(shortHex('0x1234567890abcdef1234567890abcdef12345678')).toBe('0x1234…5678')
  })

  it('computes decimal-adjusted display prices', () => {
    // 500 TETH (18) : 1,500,000 TUSD (6) -> 1 TETH = 3000 TUSD
    expect(displayPrice(500n * 10n ** 18n, 1_500_000n * 10n ** 6n, 18, 6)).toBe(3000)
    expect(displayPrice(0n, 1n, 18, 18)).toBe(0)
  })
})

describe('manifest', () => {
  it('parses and sorts pairs like the contracts', () => {
    const deployment = parseDeployment(manifest())
    expect(deployment.tokens).toHaveLength(3)
    const pair = deployment.pairs.find((p) => p.token0.symbol === 'TUSD' || p.token1.symbol === 'TUSD')!
    const [token0] = sortTokens(TETH, TUSD)
    expect(pair.token0.address).toBe(token0)
  })

  it('rejects a pair address that is not the CREATE2 address for its tokens', () => {
    const tampered = manifest({ pairs: { 'TETH-TUSD': '0x000000000000000000000000000000000000dEaD' } })
    expect(() => parseDeployment(tampered)).toThrow(/not the CREATE2 address/)
  })

  it('rejects malformed manifests', () => {
    expect(() => parseDeployment(null)).toThrow(/not an object/)
    expect(() => parseDeployment(manifest({ factory: 'nope' }))).toThrow(/factory/)
    expect(() => parseDeployment(manifest({ pairInitCodeHash: '0x12' }))).toThrow(/pairInitCodeHash/)
    expect(() => parseDeployment(manifest({ pairs: { 'TETH-XXX': zeroAddress } }))).toThrow(/unknown tokens/)
  })
})

describe('route', () => {
  const deployment = parseDeployment(manifest())
  const token = (symbol: string) => deployment.tokens.find((t) => t.symbol === symbol)!

  it('finds direct and two-hop routes', () => {
    expect(findRoute(token('TETH'), token('TUSD'), deployment.pairs)!.path.map((t) => t.symbol)).toEqual([
      'TETH',
      'TUSD',
    ])
    expect(findRoute(token('TUSD'), token('TGLD'), deployment.pairs)!.path.map((t) => t.symbol)).toEqual([
      'TUSD',
      'TETH',
      'TGLD',
    ])
    expect(findRoute(token('TUSD'), token('TUSD'), deployment.pairs)).toBeNull()
    expect(findRoute(token('TUSD'), token('TGLD'), deployment.pairs, 1)).toBeNull()
  })

  it('orients reserves along the route', () => {
    const route = findRoute(token('TUSD'), token('TGLD'), deployment.pairs)!
    const reserves = new Map<Address, readonly [bigint, bigint]>(
      route.pairs.map((pair, i) => [pair.address, [BigInt(i + 1), BigInt(i + 10)]] as const),
    )
    const hops = routeHops(route, reserves)!
    route.pairs.forEach((pair, i) => {
      const sellsToken0 = pair.token0.address === route.path[i]!.address
      expect(hops[i]).toEqual(
        sellsToken0
          ? { reserveIn: BigInt(i + 1), reserveOut: BigInt(i + 10) }
          : { reserveIn: BigInt(i + 10), reserveOut: BigInt(i + 1) },
      )
    })
    expect(routeHops(route, new Map())).toBeNull()
  })
})

describe('custom error decoding', () => {
  it('covers the errors of router, pair (incl. Solady ERC-20) and factory without duplicates', () => {
    const names = ammErrorsAbi.map((e) => e.name)
    for (const name of [
      'InsufficientOutputAmount',
      'K',
      'Expired',
      'PermitFailed',
      'InsufficientAllowance',
      'PairExists',
    ]) {
      expect(names).toContain(name)
    }
    const signatures = ammErrorsAbi.map((e) => `${e.name}(${e.inputs.map((i) => i.type).join(',')})`)
    expect(new Set(signatures).size).toBe(signatures.length)
  })

  it('decodes raw revert data into an actionable message', () => {
    const data = encodeErrorResult({ abi: ammRouterAbi, errorName: 'InsufficientOutputAmount', args: [990n, 1000n] })
    const decoded = decodeRevertData(data, { tokenOut: { symbol: 'TUSD', decimals: 0 } })!
    expect(decoded.name).toBe('InsufficientOutputAmount')
    expect(decoded.args).toEqual([990n, 1000n])
    expect(decoded.message).toMatch(/slippage tolerance.*990 TUSD.*1,000 TUSD/)
    const k = decodeRevertData(encodeErrorResult({ abi: ammPairAbi, errorName: 'K', args: [1n, 2n] }))!
    expect(k.message).toMatch(/constant-product/)
    expect(decodeRevertData('0xdeadbeef')).toBeNull()
  })

  it('walks viem error chains, including errors bubbled from the pair through the router', () => {
    // A pair error surfaced while calling the router: not in the router ABI, decoded from the raw data.
    const raw = encodeErrorResult({ abi: ammPairAbi, errorName: 'K', args: [1n, 2n] })
    const reverted = new ContractFunctionRevertedError({
      abi: ammRouterAbi,
      data: raw,
      functionName: 'swapExactTokensForTokens',
    })
    const wrapped = new BaseError('call failed', { cause: reverted })
    expect(decodeError(wrapped).name).toBe('K')

    const rejected = new BaseError('wallet', { cause: new UserRejectedRequestError(new Error('no')) })
    expect(decodeError(rejected).name).toBe('UserRejected')
    expect(decodeError(new Error('plain')).message).toBe('plain')
    expect(describeError('SomethingNew', [1n])).toBe('SomethingNew(1)')
  })

  it('explains an arithmetic-overflow panic', () => {
    expect(describeError('Panic', [0x11n])).toMatch(/too large.*256-bit/)
    expect(describeError('Panic', [0x12n])).toBe('The contract panicked (code 18).')
  })

  it('reports a wallet on the wrong network, from viem and from wagmi', () => {
    const viemError = new ChainMismatchError({ chain: localChain('http://127.0.0.1:1'), currentChainId: 1 })
    expect(decodeError(viemError)).toEqual({ name: 'WrongNetwork', args: [], message: WRONG_NETWORK_MESSAGE })
    const wrapped = new BaseError('Transaction failed', { cause: viemError })
    expect(decodeError(wrapped).name).toBe('WrongNetwork')
    const wagmiError = new ConnectorChainMismatchError({ connectionChainId: 31337, connectorChainId: 1 })
    expect(decodeError(wagmiError).name).toBe('WrongNetwork')
  })

  it('has a message for every protocol error', () => {
    for (const error of ammErrorsAbi) {
      const args = error.inputs.map(() => 1n)
      expect(describeError(error.name, args)).not.toBe(`${error.name}(${args.join(', ')})`)
    }
  })
})

describe('pool analytics', () => {
  const base = { transactionHash: '0x01' as const }
  it('aggregates swaps, liquidity events and the price series in chain order', () => {
    const events: PoolEvent[] = [
      { kind: 'sync', blockNumber: 2n, logIndex: 1, ...base, reserve0: 100n, reserve1: 400n },
      { kind: 'mint', blockNumber: 1n, logIndex: 0, ...base, amount0: 100n, amount1: 200n },
      { kind: 'sync', blockNumber: 1n, logIndex: 1, ...base, reserve0: 100n, reserve1: 200n },
      {
        kind: 'swap',
        blockNumber: 2n,
        logIndex: 0,
        ...base,
        amount0In: 0n,
        amount1In: 1000n,
        amount0Out: 5n,
        amount1Out: 0n,
      },
      {
        kind: 'swap',
        blockNumber: 3n,
        logIndex: 0,
        ...base,
        amount0In: 2000n,
        amount1In: 0n,
        amount0Out: 0n,
        amount1Out: 7n,
      },
      { kind: 'sync', blockNumber: 3n, logIndex: 1, ...base, reserve0: 90n, reserve1: 300n },
      { kind: 'sync', blockNumber: 3n, logIndex: 2, ...base, reserve0: 80n, reserve1: 350n },
      { kind: 'burn', blockNumber: 4n, logIndex: 0, ...base, amount0: 10n, amount1: 20n },
    ]
    const stats = aggregatePoolEvents(events)
    expect([stats.swaps, stats.mints, stats.burns]).toEqual([2, 1, 1])
    expect([stats.volume0, stats.volume1]).toEqual([2000n, 1000n])
    expect([stats.fees0, stats.fees1]).toEqual([6n, 3n])
    expect([stats.netDeposits0, stats.netDeposits1]).toEqual([90n, 180n])
    expect([stats.reserve0, stats.reserve1]).toEqual([80n, 350n])
    expect(stats.priceHistory.map((p) => p.blockNumber)).toEqual([1n, 2n, 3n]) // one point per block
    expect(stats.priceHistory[2]!.price1e18).toBe((350n * 10n ** 18n) / 80n) // last Sync of the block wins
    expect(stats.recentSwaps.map((s) => s.blockNumber)).toEqual([3n, 2n]) // newest first
  })
})
