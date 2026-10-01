// @vitest-environment jsdom
// SPDX-License-Identifier: MIT
// The dApp's React hooks, rendered inside the real providers (wagmi + TanStack Query + toasts) against anvil.
import { act, cleanup, fireEvent, render, renderHook, waitFor } from '@testing-library/react'
import type { ReactNode } from 'react'
import { erc20Abi, parseUnits, type Hex } from 'viem'
import { useChainId, useConnect, useConnection, useConnectors } from 'wagmi'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'

import { Providers } from '@/app/providers'
import { ConnectButton } from '@/components/ConnectButton'
import { AddLiquidityCard, RemoveLiquidityCard } from '@/components/LiquidityCards'
import { SwapCard } from '@/components/SwapCard'
import { ammPairAbi, ammRouterAbi } from '@/generated'
import { usePools } from '@/hooks/usePools'
import { useSwapQuote } from '@/hooks/useSwapQuote'
import { useTransaction } from '@/hooks/useTransaction'
import { WRONG_NETWORK_MESSAGE } from '@/lib/errors'

import { revert, snapshot, testChain } from './helpers/chain'

const { deployment, publicClient, runtime } = testChain()
const token = (symbol: string) => deployment.tokens.find((t) => t.symbol === symbol)!
const wrapper = ({ children }: { children: ReactNode }) => <Providers runtime={runtime}>{children}</Providers>

let baseline: Hex
beforeAll(async () => {
  baseline = await snapshot(publicClient)
})
afterAll(async () => {
  await revert(publicClient, baseline)
})

describe('usePools', () => {
  it('returns the on-chain reserves and LP supply of every pair', async () => {
    const { result } = renderHook(() => usePools(), { wrapper })
    await waitFor(() => expect(result.current.pools.size).toBe(deployment.pairs.length))
    for (const pair of deployment.pairs) {
      const [r0, r1] = await publicClient.readContract({
        address: pair.address,
        abi: ammPairAbi,
        functionName: 'getReserves',
      })
      const supply = await publicClient.readContract({
        address: pair.address,
        abi: ammPairAbi,
        functionName: 'totalSupply',
      })
      expect(result.current.pools.get(pair.address)).toMatchObject({ reserve0: r0, reserve1: r1, totalSupply: supply })
    }
  })
})

describe('useSwapQuote', () => {
  it('quotes a two-hop exact-in trade exactly like router.getAmountsOut', async () => {
    const amount = parseUnits('2500', 6)
    const { result } = renderHook(
      () =>
        useSwapQuote({ tokenIn: token('TUSD'), tokenOut: token('TGLD'), mode: 'exactIn', amount, slippageBps: 50n }),
      { wrapper },
    )
    await waitFor(() => expect(result.current.status).toBe('ok'))
    if (result.current.status !== 'ok') throw new Error('unreachable')
    const { quote } = result.current
    expect(quote.route.path.map((t) => t.symbol)).toEqual(['TUSD', 'TETH', 'TGLD'])
    const onchain = await publicClient.readContract({
      address: deployment.router,
      abi: ammRouterAbi,
      functionName: 'getAmountsOut',
      args: [amount, quote.route.path.map((t) => t.address)],
    })
    expect(quote.amounts).toEqual([...onchain])
    expect(quote.minimumOut).toBe((quote.amountOut * 9_950n) / 10_000n)
  })

  it('quotes an exact-out trade exactly like router.getAmountsIn', async () => {
    const amount = parseUnits('1', 18)
    const { result } = renderHook(
      () =>
        useSwapQuote({ tokenIn: token('TUSD'), tokenOut: token('TETH'), mode: 'exactOut', amount, slippageBps: 100n }),
      { wrapper },
    )
    await waitFor(() => expect(result.current.status).toBe('ok'))
    if (result.current.status !== 'ok') throw new Error('unreachable')
    const onchain = await publicClient.readContract({
      address: deployment.router,
      abi: ammRouterAbi,
      functionName: 'getAmountsIn',
      args: [amount, [token('TUSD').address, token('TETH').address]],
    })
    expect(result.current.quote.amounts).toEqual([...onchain])
  })

  it('reports quote errors instead of throwing', async () => {
    const { result } = renderHook(
      () =>
        useSwapQuote({
          tokenIn: token('TUSD'),
          tokenOut: token('TETH'),
          mode: 'exactOut',
          amount: parseUnits('1000000', 18), // more than the whole pool
          slippageBps: 50n,
        }),
      { wrapper },
    )
    await waitFor(() => expect(result.current.status).toBe('error'))
  })
})

describe('useTransaction (mock connector -> anvil)', () => {
  it('simulates, sends and confirms; a slippage violation is caught before signing and decoded', async () => {
    const { result } = renderHook(
      () => ({ connect: useConnect(), connectors: useConnectors(), connection: useConnection(), tx: useTransaction() }),
      { wrapper },
    )
    const mock = result.current.connectors.find((c) => c.type === 'mock')!
    await act(async () => {
      await result.current.connect.mutateAsync({ connector: mock, chainId: deployment.chainId })
    })
    await waitFor(() => expect(result.current.connection.status).toBe('connected'))
    const user = result.current.connection.address!

    const teth = token('TETH')
    const tusd = token('TUSD')
    const amountIn = parseUnits('1', 18)
    const path = [teth.address, tusd.address]
    const deadline = BigInt(Math.floor(Date.now() / 1000) + 600)
    const [, expectedOut] = await publicClient.readContract({
      address: deployment.router,
      abi: ammRouterAbi,
      functionName: 'getAmountsOut',
      args: [amountIn, path],
    })

    let receipt: Awaited<ReturnType<typeof result.current.tx.execute>> = null
    await act(async () => {
      receipt = await result.current.tx.execute('Approve', {
        address: teth.address,
        abi: erc20Abi,
        functionName: 'approve',
        args: [deployment.router, amountIn],
      })
    })
    expect(receipt).not.toBeNull()

    // Minimum one wei above the quote: the simulation must catch it, nothing is sent.
    const nonceBefore = await publicClient.getTransactionCount({ address: user })
    await act(async () => {
      receipt = await result.current.tx.execute('Swap', {
        address: deployment.router,
        abi: ammRouterAbi,
        functionName: 'swapExactTokensForTokens',
        args: [amountIn, expectedOut! + 1n, path, user, deadline],
      })
    })
    expect(receipt).toBeNull()
    expect(await publicClient.getTransactionCount({ address: user })).toBe(nonceBefore)
    const errorToast = document.querySelector('[data-testid="toast"][data-kind="error"]')
    expect(errorToast?.getAttribute('data-error')).toBe('InsufficientOutputAmount')
    expect(errorToast?.textContent).toMatch(/slippage tolerance/)

    const before = await publicClient.readContract({
      address: tusd.address,
      abi: erc20Abi,
      functionName: 'balanceOf',
      args: [user],
    })
    await act(async () => {
      receipt = await result.current.tx.execute('Swap', {
        address: deployment.router,
        abi: ammRouterAbi,
        functionName: 'swapExactTokensForTokens',
        args: [amountIn, expectedOut!, path, user, deadline],
      })
    })
    expect(receipt).not.toBeNull()
    const after = await publicClient.readContract({
      address: tusd.address,
      abi: erc20Abi,
      functionName: 'balanceOf',
      args: [user],
    })
    expect(after - before).toBe(expectedOut)
  })
})

describe('wallet on another network (a chain this dApp does not configure)', () => {
  /** Latest hook values of the harness below, refreshed on every render. */
  const api = {} as {
    connect: ReturnType<typeof useConnect>
    connectors: ReturnType<typeof useConnectors>
    connection: Pick<ReturnType<typeof useConnection>, 'address' | 'chainId' | 'status'>
    configChainId: number
    tx: ReturnType<typeof useTransaction>
  }

  function Harness() {
    api.connect = useConnect()
    api.connectors = useConnectors()
    // useConnection() only re-renders for the fields read during render, so read the ones the test inspects.
    const { address, chainId, status } = useConnection()
    api.connection = { address, chainId, status }
    api.configChainId = useChainId()
    api.tx = useTransaction()
    return (
      <>
        <ConnectButton />
        <SwapCard />
        <AddLiquidityCard />
        <RemoveLiquidityCard />
      </>
    )
  }

  /** The wallet itself switches chain, as a user does in MetaMask (the mock connector emits chainChanged). */
  async function walletSwitchesTo(chainId: number) {
    const mock = api.connectors.find((c) => c.type === 'mock')!
    const provider = (await mock.getProvider()) as {
      request: (args: { method: string; params: unknown[] }) => Promise<unknown>
    }
    await act(async () => {
      await provider.request({
        method: 'wallet_switchEthereumChain',
        params: [{ chainId: `0x${chainId.toString(16)}` }],
      })
    })
    await waitFor(() => expect(api.connection.chainId).toBe(chainId))
  }

  it('blocks every write and signature, refuses to send, and offers the switch back', async () => {
    const view = render(<Harness />, { wrapper })
    const byTestId = (id: string) => view.container.querySelector(`[data-testid="${id}"]`)
    const mock = api.connectors.find((c) => c.type === 'mock')!
    await act(async () => {
      await api.connect.mutateAsync({ connector: mock, chainId: deployment.chainId })
    })
    await waitFor(() => expect(api.connection.status).toBe('connected'))
    const user = api.connection.address!
    expect(byTestId('switch-network')).toBeNull()

    await walletSwitchesTo(1)
    // The trap: wagmi's useChainId() only follows configured chains and still reports the local chain.
    expect(api.configChainId).toBe(deployment.chainId)
    await waitFor(() => expect(byTestId('switch-network')).not.toBeNull())
    for (const id of ['swap-submit', 'add-submit', 'remove-submit']) {
      const button = byTestId(id) as HTMLButtonElement
      expect(button.disabled).toBe(true)
      expect(button.textContent).toBe('Switch your wallet to Anvil')
    }

    // Even called directly, the write is pinned to the deployment chain: refused before anything is signed or sent.
    const nonceBefore = await publicClient.getTransactionCount({ address: user })
    let receipt: Awaited<ReturnType<typeof api.tx.execute>> = null
    await act(async () => {
      receipt = await api.tx.execute('Approve', {
        address: token('TETH').address,
        abi: erc20Abi,
        functionName: 'approve',
        args: [deployment.router, 1n],
      })
    })
    expect(receipt).toBeNull()
    expect(await publicClient.getTransactionCount({ address: user })).toBe(nonceBefore)
    const toast = view.container.querySelector('[data-testid="toast"][data-kind="error"]')
    expect(toast?.getAttribute('data-error')).toBe('WrongNetwork')
    expect(toast?.textContent).toContain(WRONG_NETWORK_MESSAGE)

    // The switch button brings the wallet back, and writes work again.
    fireEvent.click(byTestId('switch-network')!)
    await waitFor(() => expect(api.connection.chainId).toBe(deployment.chainId))
    await waitFor(() => expect(byTestId('switch-network')).toBeNull())
    await act(async () => {
      receipt = await api.tx.execute('Approve', {
        address: token('TETH').address,
        abi: erc20Abi,
        functionName: 'approve',
        args: [deployment.router, 1n],
      })
    })
    expect(receipt).not.toBeNull()
    expect(await publicClient.getTransactionCount({ address: user })).toBe(nonceBefore + 1)
    cleanup()
  })
})
