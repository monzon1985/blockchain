// SPDX-License-Identifier: MIT
// Differential test: the TypeScript quote library (what the UI shows) against the deployed router on anvil (what
// the chain executes). Seeded, so every run explores the same routes and sizes.
import { erc20Abi, maxUint256, parseAbi, type Address, type Hex } from 'viem'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'

import { ANVIL_ACCOUNTS } from '../scripts/lib/chain.mjs'
import { ammFactoryAbi, ammPairAbi, ammRouterAbi } from '@/generated'
import { decodeError } from '@/lib/errors'
import { withGasMargin } from '@/lib/gas'
import { pairFor } from '@/lib/manifest'
import {
  QuoteError,
  SOLIDITY_ERROR,
  UINT112_MAX,
  UINT256_MAX,
  assertReservesFit,
  burnAmounts,
  getAmountsIn,
  getAmountsOut,
  liquidityMinted,
  optimalDeposit,
} from '@/lib/quote'
import { findRoute, routeHops, type PairReserves, type Route } from '@/lib/route'

import { prng, revert, snapshot, testChain } from './helpers/chain'

const { deployment, publicClient, wallet } = testChain()
const trader = ANVIL_ACCOUNTS[3]!
const traderWallet = wallet(trader)
const router = deployment.router

const token = (symbol: string) => deployment.tokens.find((t) => t.symbol === symbol)!
/** The demo tokens (test/mocks/MockERC20.sol) have an open faucet mint. */
const faucetAbi = parseAbi(['function mint(address to, uint256 amount)'])

const routes: Route[] = deployment.tokens.flatMap((a) =>
  deployment.tokens.filter((b) => b.address !== a.address).map((b) => findRoute(a, b, deployment.pairs)!),
)

async function reservesMap(): Promise<Map<Address, PairReserves>> {
  const entries = await Promise.all(
    deployment.pairs.map(async (pair) => {
      const [r0, r1] = await publicClient.readContract({
        address: pair.address,
        abi: ammPairAbi,
        functionName: 'getReserves',
      })
      return [pair.address, [r0, r1] as const] as const
    }),
  )
  return new Map(entries)
}

type WriteParameters = Parameters<typeof traderWallet.writeContract>[0]

/** Sends like the dApp does: estimate, add the same gas margin, send, and require success. */
async function write(parameters: Omit<WriteParameters, 'account' | 'chain'>) {
  const gas = withGasMargin(await publicClient.estimateContractGas({ ...parameters, account: trader } as never))
  return send(traderWallet.writeContract({ ...parameters, gas } as WriteParameters))
}

async function send(pending: Promise<Hex>) {
  const hash = await pending
  const receipt = await publicClient.waitForTransactionReceipt({ hash })
  if (receipt.status !== 'success') {
    // Replay on the parent block to report the custom error instead of a bare "reverted".
    const tx = await publicClient.getTransaction({ hash })
    const reason = await publicClient
      .call({ account: tx.from, to: tx.to!, data: tx.input, gas: tx.gas, blockNumber: receipt.blockNumber - 1n })
      .then(
        () => 'no revert when replayed on the parent block',
        (error: unknown) => decodeError(error).name,
      )
    throw new Error(`transaction reverted (${reason}); gas used ${receipt.gasUsed} of ${tx.gas}`)
  }
  return receipt
}

const balanceOf = (token: Address, owner: Address) =>
  publicClient.readContract({ address: token, abi: erc20Abi, functionName: 'balanceOf', args: [owner] })

/** Runs a router read; returns the decoded error name instead of throwing. */
async function tryRead<T>(read: () => Promise<T>): Promise<{ ok: true; value: T } | { ok: false; error: string }> {
  try {
    return { ok: true, value: await read() }
  } catch (error) {
    return { ok: false, error: decodeError(error).name }
  }
}

function tryQuote(fn: () => bigint[]): { ok: true; value: bigint[] } | { ok: false; error: string } {
  try {
    return { ok: true, value: fn() }
  } catch (error) {
    if (error instanceof QuoteError) return { ok: false, error: SOLIDITY_ERROR[error.code] }
    throw error
  }
}

let baseline: Hex

beforeAll(async () => {
  baseline = await snapshot(publicClient)
  for (const token of deployment.tokens) {
    await write({ address: token.address, abi: erc20Abi, functionName: 'approve', args: [router, maxUint256] })
  }
  for (const pair of deployment.pairs) {
    await write({ address: pair.address, abi: ammPairAbi, functionName: 'approve', args: [router, maxUint256] })
  }
})

afterAll(async () => {
  await revert(publicClient, baseline)
})

describe('manifest matches the chain', () => {
  it('pairs are the factory pairs and the CREATE2 addresses the router derives', async () => {
    const hash = await publicClient.readContract({
      address: router,
      abi: ammRouterAbi,
      functionName: 'pairInitCodeHash',
    })
    expect(hash).toBe(deployment.pairInitCodeHash)
    for (const pair of deployment.pairs) {
      const onchain = await publicClient.readContract({
        address: deployment.factory,
        abi: ammFactoryAbi,
        functionName: 'getPair',
        args: [pair.token0.address, pair.token1.address],
      })
      expect(onchain).toBe(pair.address)
      expect(pairFor(deployment.factory, hash, pair.token1.address, pair.token0.address)).toBe(pair.address)
    }
  })
})

describe('TS quote library vs the deployed router', () => {
  it('getAmountsOut: identical amounts, or the same custom error, for 300 seeded routes and sizes', async () => {
    const rand = prng(0x12a33)
    const reserves = await reservesMap()
    let matched = 0
    for (let i = 0; i < 300; i++) {
      const route = routes[rand.int(routes.length)]!
      const hops = routeHops(route, reserves)!
      const amountIn = rand.logUniform(hops[0]!.reserveIn * 10n)
      const path = route.path.map((token) => token.address)
      const expected = tryQuote(() => getAmountsOut(amountIn, hops))
      const onchain = await tryRead(() =>
        publicClient.readContract({
          address: router,
          abi: ammRouterAbi,
          functionName: 'getAmountsOut',
          args: [amountIn, path],
        }),
      )
      expect(onchain).toEqual(expected)
      if (expected.ok) matched++
    }
    expect(matched).toBeGreaterThan(200) // the campaign is not dominated by reverting inputs
  })

  it('getAmountsIn: identical amounts, or the same custom error, for 300 seeded routes and sizes', async () => {
    const rand = prng(0xbeef)
    const reserves = await reservesMap()
    let matched = 0
    for (let i = 0; i < 300; i++) {
      const route = routes[rand.int(routes.length)]!
      const hops = routeHops(route, reserves)!
      const amountOut = rand.logUniform(hops[hops.length - 1]!.reserveOut * 2n)
      const path = route.path.map((token) => token.address)
      const expected = tryQuote(() => getAmountsIn(amountOut, hops))
      const onchain = await tryRead(() =>
        publicClient.readContract({
          address: router,
          abi: ammRouterAbi,
          functionName: 'getAmountsIn',
          args: [amountOut, path],
        }),
      )
      expect(onchain).toEqual(expected)
      if (expected.ok) matched++
    }
    expect(matched).toBeGreaterThan(100)
  })

  it('getAmountsOut up to 2^256 - 1: the library overflows exactly where the router panics', async () => {
    const rand = prng(0x0f10)
    const reserves = await reservesMap()
    let matched = 0
    let overflowed = 0
    for (let i = 0; i < 150; i++) {
      const route = routes[rand.int(routes.length)]!
      const hops = routeHops(route, reserves)!
      const amountIn = rand.logUniform(UINT256_MAX) // every magnitude from 1 wei to the uint256 maximum
      const path = route.path.map((t) => t.address)
      const expected = tryQuote(() => getAmountsOut(amountIn, hops))
      const onchain = await tryRead(() =>
        publicClient.readContract({
          address: router,
          abi: ammRouterAbi,
          functionName: 'getAmountsOut',
          args: [amountIn, path],
        }),
      )
      expect(onchain).toEqual(expected)
      if (expected.ok) matched++
      else if (expected.error === 'Panic') overflowed++
    }
    // Both regimes are exercised, not just one of them.
    expect(matched).toBeGreaterThan(50)
    expect(overflowed).toBeGreaterThan(25)
  })

  it('5e47 TETH into the TGLD pool is an overflow for both the library and the router, not a quote', async () => {
    const amountIn = 5n * 10n ** 47n
    const route = findRoute(token('TETH'), token('TGLD'), deployment.pairs)!
    const hops = routeHops(route, await reservesMap())!
    expect(tryQuote(() => getAmountsOut(amountIn, hops))).toEqual({ ok: false, error: 'Panic' })
    const onchain = await publicClient
      .readContract({
        address: router,
        abi: ammRouterAbi,
        functionName: 'getAmountsOut',
        args: [amountIn, route.path.map((t) => t.address)],
      })
      .then(
        () => null,
        (error: unknown) => decodeError(error),
      )
    expect(onchain).toMatchObject({ name: 'Panic', args: [0x11n] })
  })

  it('executes 30 seeded swaps: the quote is honoured to the wei and one wei past it reverts', async () => {
    const rand = prng(0x5a17)
    let executed = 0
    for (let i = 0; i < 30; i++) {
      const reserves = await reservesMap()
      const route = routes[rand.int(routes.length)]!
      const hops = routeHops(route, reserves)!
      const path = route.path.map((token) => token.address)
      const tokenIn = route.path[0]!.address
      const tokenOut = route.path[route.path.length - 1]!.address
      const deadline = BigInt(Math.floor(Date.now() / 1000) + 3600)
      const balanceIn = await balanceOf(tokenIn, trader)
      const beforeIn = balanceIn
      const beforeOut = await balanceOf(tokenOut, trader)

      if (rand.next() < 0.5) {
        // Exact input, sized up to 1/4 of the trader's balance.
        const amountIn = rand.logUniform(balanceIn / 4n)
        const quoted = tryQuote(() => getAmountsOut(amountIn, hops))
        if (!quoted.ok) continue // dust that quotes zero on a hop: covered by the getAmountsOut campaign above
        const out = quoted.value[quoted.value.length - 1]!
        if (out === 0n) continue
        const tooMuch = await tryRead(() =>
          publicClient.simulateContract({
            account: trader,
            address: router,
            abi: ammRouterAbi,
            functionName: 'swapExactTokensForTokens',
            args: [amountIn, out + 1n, path, trader, deadline],
          }),
        )
        expect(tooMuch).toEqual({ ok: false, error: 'InsufficientOutputAmount' })
        await write({
          address: router,
          abi: ammRouterAbi,
          functionName: 'swapExactTokensForTokens',
          args: [amountIn, out, path, trader, deadline],
        })
        expect((await balanceOf(tokenOut, trader)) - beforeOut).toBe(out)
        expect(beforeIn - (await balanceOf(tokenIn, trader))).toBe(amountIn)
      } else {
        // Exact output, up to 10 % of the last pool's output reserve.
        const amountOut = rand.logUniform(hops[hops.length - 1]!.reserveOut / 10n)
        const quoted = tryQuote(() => getAmountsIn(amountOut, hops))
        if (!quoted.ok) continue
        const amountIn = quoted.value[0]!
        if (amountIn > balanceIn) continue
        const tooLittle = await tryRead(() =>
          publicClient.simulateContract({
            account: trader,
            address: router,
            abi: ammRouterAbi,
            functionName: 'swapTokensForExactTokens',
            args: [amountOut, amountIn - 1n, path, trader, deadline],
          }),
        )
        expect(tooLittle).toEqual({ ok: false, error: 'ExcessiveInputAmount' })
        await write({
          address: router,
          abi: ammRouterAbi,
          functionName: 'swapTokensForExactTokens',
          args: [amountOut, amountIn, path, trader, deadline],
        })
        expect((await balanceOf(tokenOut, trader)) - beforeOut).toBe(amountOut)
        expect(beforeIn - (await balanceOf(tokenIn, trader))).toBe(amountIn)
      }
      executed++
    }
    expect(executed).toBeGreaterThan(20)
  })

  it('liquidity estimates equal what the pair mints and pays out', async () => {
    const rand = prng(0x11)
    for (let i = 0; i < 10; i++) {
      const pair = deployment.pairs[rand.int(deployment.pairs.length)]!
      const [r0, r1] = (await reservesMap()).get(pair.address)!
      const supply = await publicClient.readContract({
        address: pair.address,
        abi: ammPairAbi,
        functionName: 'totalSupply',
      })
      const desired0 = rand.logUniform((await balanceOf(pair.token0.address, trader)) / 4n)
      const desired1 = rand.logUniform((await balanceOf(pair.token1.address, trader)) / 4n)
      const { amountA, amountB } = optimalDeposit(desired0, desired1, r0, r1)
      const expectedLp = liquidityMinted(amountA, amountB, r0, r1, supply)
      const lpBefore = await balanceOf(pair.address, trader)
      const deadline = BigInt(Math.floor(Date.now() / 1000) + 3600)
      if (expectedLp === 0n) {
        const result = await tryRead(() =>
          publicClient.simulateContract({
            account: trader,
            address: router,
            abi: ammRouterAbi,
            functionName: 'addLiquidity',
            args: [pair.token0.address, pair.token1.address, desired0, desired1, 0n, 0n, trader, deadline],
          }),
        )
        expect(result.ok ? 'ok' : result.error).toMatch(/InsufficientLiquidityMinted|InsufficientAmount/)
        continue
      }
      const add = await tryRead(() =>
        publicClient.simulateContract({
          account: trader,
          address: router,
          abi: ammRouterAbi,
          functionName: 'addLiquidity',
          args: [pair.token0.address, pair.token1.address, desired0, desired1, amountA, amountB, trader, deadline],
        }),
      )
      expect(add.ok ? 'ok' : add.error).toBe('ok')
      if (!add.ok) return
      await write(add.value.request as never)
      const minted = (await balanceOf(pair.address, trader)) - lpBefore
      expect(minted).toBe(expectedLp)

      const [s0, s1] = (await reservesMap()).get(pair.address)!
      const supplyAfter = await publicClient.readContract({
        address: pair.address,
        abi: ammPairAbi,
        functionName: 'totalSupply',
      })
      const expectedOut = burnAmounts(minted, s0, s1, supplyAfter)
      const before0 = await balanceOf(pair.token0.address, trader)
      const before1 = await balanceOf(pair.token1.address, trader)
      await write({
        address: router,
        abi: ammRouterAbi,
        functionName: 'removeLiquidity',
        args: [
          pair.token0.address,
          pair.token1.address,
          minted,
          expectedOut.amountA,
          expectedOut.amountB,
          trader,
          deadline,
        ],
      })
      expect((await balanceOf(pair.token0.address, trader)) - before0).toBe(expectedOut.amountA)
      expect((await balanceOf(pair.token1.address, trader)) - before1).toBe(expectedOut.amountB)
    }
  })
})

describe('the 112-bit reserve ceiling', () => {
  it('an input that would push the pair past 2^112 - 1 is flagged by the library and reverts with Overflow', async () => {
    const id = await snapshot(publicClient)
    try {
      const route = findRoute(token('TETH'), token('TUSD'), deployment.pairs)!
      const path = route.path.map((t) => t.address)
      const hops = routeHops(route, await reservesMap())!
      const atCeiling = UINT112_MAX - hops[0]!.reserveIn
      await write({ address: path[0]!, abi: faucetAbi, functionName: 'mint', args: [trader, atCeiling + 1n] })
      const deadline = BigInt(Math.floor(Date.now() / 1000) + 3600)
      for (const [amountIn, fits] of [
        [atCeiling, true],
        [atCeiling + 1n, false],
      ] as const) {
        // The router's quote views do not check the ceiling: both sizes quote, identically on both sides.
        const amounts = getAmountsOut(amountIn, hops)
        const quoted = await publicClient.readContract({
          address: router,
          abi: ammRouterAbi,
          functionName: 'getAmountsOut',
          args: [amountIn, path],
        })
        expect([...quoted]).toEqual(amounts)
        // Execution does: the library flags exactly the inputs the pair rejects.
        const flagged = tryQuote(() => {
          assertReservesFit(amounts, hops)
          return amounts
        })
        const executed = await tryRead(() =>
          publicClient.simulateContract({
            account: trader,
            address: router,
            abi: ammRouterAbi,
            functionName: 'swapExactTokensForTokens',
            args: [amountIn, 0n, path, trader, deadline],
          }),
        )
        expect(flagged.ok).toBe(fits)
        expect(executed.ok).toBe(fits)
        if (!fits) {
          expect(flagged).toEqual({ ok: false, error: 'Overflow' })
          expect(executed).toEqual({ ok: false, error: 'Overflow' })
        }
      }
    } finally {
      await revert(publicClient, id)
    }
  })
})
