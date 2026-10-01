// SPDX-License-Identifier: MIT
// Why the dApp never sends a transaction with the bare gas estimate (src/lib/gas.ts). An estimate is computed against
// the latest block; the transaction runs in the next one. The first trade of a block also writes the pair's TWAP
// accumulators (AMMPair._update only accrues when the timestamp moved), so an estimate taken in the block of the
// previous trade is short by those writes. Blocks are mined by hand here so the timing is deterministic.
import { erc20Abi, maxUint256, type Hex } from 'viem'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'

import { ANVIL_ACCOUNTS } from '../scripts/lib/chain.mjs'
import { ammPairAbi, ammRouterAbi } from '@/generated'
import { GAS_MARGIN_BPS, withGasMargin } from '@/lib/gas'

import { revert, snapshot, testChain } from './helpers/chain'

const { deployment, publicClient, wallet } = testChain()
const trader = ANVIL_ACCOUNTS[3]!
const traderWallet = wallet(trader)
const teth = deployment.tokens.find((t) => t.symbol === 'TETH')!
const tusd = deployment.tokens.find((t) => t.symbol === 'TUSD')!
const pair = deployment.pairs.find((p) => [p.token0.address, p.token1.address].includes(tusd.address))!

const rpc = (method: string, params: unknown[] = []) => publicClient.request({ method, params } as never)

/** Mines exactly one block at `timestamp` with whatever is pending. */
async function mineAt(timestamp: bigint) {
  await rpc('evm_setNextBlockTimestamp', [Number(timestamp)])
  await rpc('evm_mine')
}

function swap(gas?: bigint) {
  const deadline = BigInt(Math.floor(Date.now() / 1000) + 3600)
  return {
    address: deployment.router,
    abi: ammRouterAbi,
    functionName: 'swapExactTokensForTokens',
    args: [10n ** 17n, 0n, [teth.address, tusd.address], trader, deadline],
    ...(gas === undefined ? {} : { gas }),
  } as const
}

/**
 * Trade 1 is mined at T, so the pair's TWAP timestamp is T. Trade 2 is estimated against that block (elapsed time 0:
 * no accumulator writes in the estimate), sent with `gasFor(estimate)` and mined at T + 1, where it must accrue.
 */
async function secondTradeOfTheNextBlock(gasFor: (estimate: bigint) => bigint) {
  const t = (await publicClient.getBlock()).timestamp + 1n
  await traderWallet.writeContract(swap())
  await mineAt(t)
  const [, , twapTimestamp] = await publicClient.readContract({
    address: pair.address,
    abi: ammPairAbi,
    functionName: 'getReserves',
  })
  expect(BigInt(twapTimestamp)).toBe(t)

  const estimate = await publicClient.estimateContractGas({ ...swap(), account: trader, blockTag: 'latest' })
  const hash = await traderWallet.writeContract(swap(gasFor(estimate)))
  await mineAt(t + 1n)
  const receipt = await publicClient.waitForTransactionReceipt({ hash })
  return { estimate, receipt }
}

interface Frame {
  to: string
  error?: string
  calls?: Frame[]
}

/** Addresses of every call frame that failed with out-of-gas, depth first. */
function outOfGasFrames(frame: Frame): string[] {
  const own = frame.error && /out of gas/i.test(frame.error) ? [frame.to.toLowerCase()] : []
  return [...own, ...(frame.calls ?? []).flatMap(outOfGasFrames)]
}

let baseline: Hex

beforeAll(async () => {
  baseline = await snapshot(publicClient)
  await publicClient.waitForTransactionReceipt({
    hash: await traderWallet.writeContract({
      address: teth.address,
      abi: erc20Abi,
      functionName: 'approve',
      args: [deployment.router, maxUint256],
    }),
  })
  await rpc('evm_setAutomine', [false])
})

afterAll(async () => {
  await rpc('evm_setAutomine', [true])
  await revert(publicClient, baseline)
})

describe('gas margin', () => {
  it('withGasMargin adds exactly 20 %, rounded down', () => {
    expect(GAS_MARGIN_BPS).toBe(2_000n)
    expect(withGasMargin(100_000n)).toBe(120_000n)
    expect(withGasMargin(81_329n)).toBe(97_594n)
    expect(withGasMargin(0n)).toBe(0n)
  })

  it('the bare estimate runs out of gas on the first trade of a new block', async () => {
    const { estimate, receipt } = await secondTradeOfTheNextBlock((estimate) => estimate)
    expect(receipt.status).toBe('reverted')
    // The call trace shows why: the pair's swap frame ran out of gas (the router then reverted).
    const trace = (await rpc('debug_traceTransaction', [receipt.transactionHash, { tracer: 'callTracer' }])) as Frame
    expect(outOfGasFrames(trace)).toEqual([pair.address.toLowerCase()])
    expect(receipt.gasUsed).toBeLessThanOrEqual(estimate)
  })

  it('the same transaction with withGasMargin succeeds', async () => {
    const { estimate, receipt } = await secondTradeOfTheNextBlock(withGasMargin)
    expect(receipt.status).toBe('success')
    expect(receipt.gasUsed).toBeGreaterThan(estimate) // the TWAP writes the estimate did not see
    expect(receipt.gasUsed).toBeLessThanOrEqual(withGasMargin(estimate))
  })
})
