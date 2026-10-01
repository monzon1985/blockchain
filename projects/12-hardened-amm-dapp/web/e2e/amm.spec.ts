// SPDX-License-Identifier: MIT
// End-to-end: the production build (`next build && next start`) against a fresh anvil, driven through the UI with
// wagmi's mock connector (anvil's unlocked account #1, so permits are real EIP-712 signatures from anvil).
import { erc20Abi, parseUnits } from 'viem'

import { ammPairAbi, ammRouterAbi } from '../src/generated'

import {
  approveRouter,
  balanceOf,
  env,
  expect,
  expectToast,
  openConnected,
  other,
  rpc,
  sendFrom,
  test,
  token,
  user,
} from './chain'

test('swap: the UI shows the router quote to the wei and settles exactly that amount', async ({ page }) => {
  const { deployment, publicClient } = env()
  const teth = token('TETH')
  const tusd = token('TUSD')
  await openConnected(page)

  await page.getByTestId('swap-amount-in').fill('1.5')
  const quoteCell = page.getByTestId('swap-quote-out')
  await expect(quoteCell).toBeVisible()
  const shown = BigInt((await quoteCell.getAttribute('data-raw'))!)
  const [, routerQuote] = await publicClient.readContract({
    address: deployment.router,
    abi: ammRouterAbi,
    functionName: 'getAmountsOut',
    args: [parseUnits('1.5', 18), [teth.address, tusd.address]],
  })
  expect(shown).toBe(routerQuote)
  await expect(page.getByTestId('swap-route')).toHaveText('TETH → TUSD')

  const submit = page.getByTestId('swap-submit')
  await expect(submit).toHaveText('Approve TETH')
  await submit.click()
  await expectToast(page, 'Approve TETH', 'success')
  await expect(submit).toHaveText('Swap')

  const before = await balanceOf(tusd.address, user())
  await submit.click()
  await expectToast(page, 'Swap TETH → TUSD', 'success')
  expect((await balanceOf(tusd.address, user())) - before).toBe(shown)
})

test('swap: two-hop exact-output route through TETH', async ({ page }) => {
  const { deployment, publicClient } = env()
  const tusd = token('TUSD')
  const tgld = token('TGLD')
  await openConnected(page)
  await page.getByTestId('swap-token-in').selectOption('TUSD')
  await page.getByTestId('swap-token-out').selectOption('TGLD')
  await page.getByTestId('swap-amount-out').fill('0.25')
  await expect(page.getByTestId('swap-route')).toHaveText('TUSD → TETH → TGLD')
  const shownIn = BigInt((await page.getByTestId('swap-quote-in').getAttribute('data-raw'))!)
  const [routerIn] = await publicClient.readContract({
    address: deployment.router,
    abi: ammRouterAbi,
    functionName: 'getAmountsIn',
    args: [parseUnits('0.25', 24), [tusd.address, token('TETH').address, tgld.address]],
  })
  expect(shownIn).toBe(routerIn)

  const submit = page.getByTestId('swap-submit')
  await submit.click() // approve the maximum input (quote + slippage)
  await expectToast(page, 'Approve TUSD', 'success')
  await expect(submit).toHaveText('Swap')
  const before = await balanceOf(tgld.address, user())
  await submit.click()
  await expectToast(page, 'Swap TUSD → TGLD', 'success')
  expect((await balanceOf(tgld.address, user())) - before).toBe(parseUnits('0.25', 24))
})

test('add liquidity: approvals, deposit at the pool ratio, LP minted as estimated', async ({ page }) => {
  const pair = env().deployment.pairs[0]!
  await openConnected(page, '/pool')
  await page.getByTestId('add-pair').selectOption(pair.address)
  await page.getByTestId('add-amount-0').fill('10')
  await expect(page.getByTestId('add-amount-1')).not.toHaveValue('')
  const estimate = BigInt((await page.getByTestId('add-lp-estimate').getAttribute('data-raw'))!)
  expect(estimate).toBeGreaterThan(0n)

  const submit = page.getByTestId('add-submit')
  await expect(submit).toHaveText(`Approve ${pair.token0.symbol}`)
  await submit.click()
  await expectToast(page, `Approve ${pair.token0.symbol}`, 'success')
  await expect(submit).toHaveText(`Approve ${pair.token1.symbol}`)
  await submit.click()
  await expectToast(page, `Approve ${pair.token1.symbol}`, 'success')
  await expect(submit).toHaveText('Add liquidity')
  await submit.click()
  await expectToast(page, `Add ${pair.token0.symbol}/${pair.token1.symbol} liquidity`, 'success')
  expect(await balanceOf(pair.address, user())).toBe(estimate)
})

test('remove liquidity with an EIP-2612 permit: one transaction, no approval', async ({ page }) => {
  const { deployment, publicClient } = env()
  const pair = deployment.pairs[0]!
  // Give the user an LP position directly on-chain.
  await approveRouter(user(), pair.token0.address)
  await approveRouter(user(), pair.token1.address)
  const deadline = BigInt(Math.floor(Date.now() / 1000) + 3600)
  await sendFrom(user(), {
    address: deployment.router,
    abi: ammRouterAbi,
    functionName: 'addLiquidity',
    args: [
      pair.token0.address,
      pair.token1.address,
      parseUnits('1', pair.token0.decimals),
      10n ** 40n,
      0n,
      0n,
      user(),
      deadline,
    ],
  })
  const lp = await balanceOf(pair.address, user())
  expect(lp).toBeGreaterThan(0n)
  const nonceBefore = await publicClient.getTransactionCount({ address: user() })

  await openConnected(page, '/pool')
  await page.getByTestId('remove-pair').selectOption(pair.address)
  await expect(page.getByTestId('lp-balance')).toHaveAttribute('data-raw', lp.toString())
  await page.getByTestId('remove-pct-100').click()
  const submit = page.getByTestId('remove-submit')
  await expect(submit).toBeEnabled() // requires the signed domain to match DOMAIN_SEPARATOR
  await submit.click()
  await expectToast(page, 'Sign LP permit', 'success')
  await expectToast(page, `Remove ${pair.token0.symbol}/${pair.token1.symbol} liquidity`, 'success')

  expect(await balanceOf(pair.address, user())).toBe(0n)
  expect(await publicClient.getTransactionCount({ address: user() })).toBe(nonceBefore + 1) // no approve tx
  const [permitNonce, allowance] = await Promise.all([
    publicClient.readContract({ address: pair.address, abi: ammPairAbi, functionName: 'nonces', args: [user()] }),
    publicClient.readContract({
      address: pair.address,
      abi: erc20Abi,
      functionName: 'allowance',
      args: [user(), deployment.router],
    }),
  ])
  expect(permitNonce).toBe(1n)
  expect(allowance).toBe(0n)
})

test('slippage: a front-run swap reverts on-chain and the toast decodes InsufficientOutputAmount', async ({ page }) => {
  const { deployment } = env()
  const teth = token('TETH')
  const tusd = token('TUSD')
  await approveRouter(user(), teth.address)
  await approveRouter(other(), teth.address)

  await openConnected(page)
  await page.getByTestId('settings-toggle').click()
  await page.getByTestId('settings-slippage').fill('0.1')
  await page.getByTestId('swap-amount-in').fill('5')
  const submit = page.getByTestId('swap-submit')
  await expect(submit).toHaveText('Swap')
  const before = await balanceOf(tusd.address, user())

  // Hold blocks: the user's transaction waits in the mempool...
  await rpc('evm_setAutomine', [false])
  await submit.click()
  const toast = page.getByTestId('toast').filter({ hasText: 'Swap TETH → TUSD' }).last()
  await expect(toast).toContainText('Waiting for the transaction to be mined')

  // ...a larger trade in the same direction with a higher tip is ordered first...
  const deadline = BigInt(Math.floor(Date.now() / 1000) + 3600)
  await sendFrom(
    other(),
    {
      address: deployment.router,
      abi: ammRouterAbi,
      functionName: 'swapExactTokensForTokens',
      args: [parseUnits('50', 18), 0n, [teth.address, tusd.address], other(), deadline],
    },
    { gas: 500_000n, maxPriorityFeePerGas: 50_000_000_000n, maxFeePerGas: 200_000_000_000n, wait: false },
  )
  await rpc('evm_mine')
  await rpc('evm_setAutomine', [true])

  // ...so the user's swap reverts on-chain, and the UI replays it to explain why.
  await expect(toast).toHaveAttribute('data-kind', 'error', { timeout: 60_000 })
  await expect(toast).toHaveAttribute('data-error', 'InsufficientOutputAmount')
  await expect(toast).toContainText('Price moved beyond your slippage tolerance')
  expect(await balanceOf(tusd.address, user())).toBe(before)
})

test('analytics: pool stats are rebuilt from the pair events', async ({ page }) => {
  const { deployment } = env()
  const teth = token('TETH')
  const tusd = token('TUSD')
  await approveRouter(other(), teth.address)
  const deadline = BigInt(Math.floor(Date.now() / 1000) + 3600)
  await sendFrom(other(), {
    address: deployment.router,
    abi: ammRouterAbi,
    functionName: 'swapExactTokensForTokens',
    args: [parseUnits('2', 18), 0n, [teth.address, tusd.address], other(), deadline],
  })
  const pair = deployment.pairs.find((p) => [p.token0.symbol, p.token1.symbol].sort().join() === 'TETH,TUSD')!
  await page.goto('/analytics')
  const card = page.getByTestId(`analytics-${pair.token0.symbol}-${pair.token1.symbol}`)
  await expect(card.getByTestId('analytics-counts')).toHaveText('1 / 1 / 0') // one swap, the seeding mint, no burns
  await expect(card.locator('table.trades tbody tr')).toHaveCount(1)
})
