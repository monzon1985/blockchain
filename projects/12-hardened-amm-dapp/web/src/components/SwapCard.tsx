// SPDX-License-Identifier: MIT
'use client'

import { useMemo, useState } from 'react'
import { erc20Abi } from 'viem'
import { useConnection } from 'wagmi'

import { ammRouterAbi } from '@/generated'
import { useNetworkGuard } from '@/hooks/useNetworkGuard'
import { useSwapQuote, type SwapMode } from '@/hooks/useSwapQuote'
import { useTokenState } from '@/hooks/useTokenState'
import { useTransaction } from '@/hooks/useTransaction'
import { formatAmount, formatBps, parseAmount } from '@/lib/format'
import type { TokenInfo } from '@/lib/types'

import { useRuntime } from './RuntimeContext'
import { SettingsPanel, deadlineFromNow, useSettings } from './Settings'

function TokenSelect(props: {
  testId: string
  tokens: readonly TokenInfo[]
  value: TokenInfo | undefined
  onChange: (token: TokenInfo) => void
}) {
  return (
    <select
      data-testid={props.testId}
      value={props.value?.symbol ?? ''}
      onChange={(event) => {
        const token = props.tokens.find((item) => item.symbol === event.target.value)
        if (token) props.onChange(token)
      }}
    >
      {props.tokens.map((token) => (
        <option key={token.address} value={token.symbol}>
          {token.symbol}
        </option>
      ))}
    </select>
  )
}

export function SwapCard() {
  const { deployment } = useRuntime()
  const { address } = useConnection()
  const settings = useSettings()
  const tokenState = useTokenState()
  const { execute, busy } = useTransaction()
  const { wrongNetwork } = useNetworkGuard()

  const [tokenIn, setTokenIn] = useState<TokenInfo | undefined>(deployment.tokens.find((t) => t.symbol === 'TETH'))
  const [tokenOut, setTokenOut] = useState<TokenInfo | undefined>(deployment.tokens.find((t) => t.symbol === 'TUSD'))
  const [mode, setMode] = useState<SwapMode>('exactIn')
  const [typed, setTyped] = useState('')

  const typedToken = mode === 'exactIn' ? tokenIn : tokenOut
  const amount = typedToken ? parseAmount(typed, typedToken.decimals) : null
  const result = useSwapQuote({ tokenIn, tokenOut, mode, amount, slippageBps: settings.slippageBps })
  const quote = result.status === 'ok' ? result.quote : undefined

  const inState = tokenIn ? tokenState.get(tokenIn.address) : undefined
  const outState = tokenOut ? tokenState.get(tokenOut.address) : undefined
  const spend = quote ? (mode === 'exactIn' ? quote.amountIn : quote.maximumIn) : 0n

  const displayIn =
    mode === 'exactIn' ? typed : quote && tokenIn ? formatAmount(quote.amountIn, tokenIn.decimals, 8) : ''
  const displayOut =
    mode === 'exactOut' ? typed : quote && tokenOut ? formatAmount(quote.amountOut, tokenOut.decimals, 8) : ''

  const action = useMemo(() => {
    if (!address) return { label: 'Connect a wallet to swap', disabled: true, kind: 'none' as const }
    if (wrongNetwork) return { label: 'Switch your wallet to Anvil', disabled: true, kind: 'none' as const }
    if (!quote)
      return {
        label: result.status === 'no-route' ? 'No route' : 'Enter an amount',
        disabled: true,
        kind: 'none' as const,
      }
    if (!inState || inState.balance < spend) {
      return { label: `Insufficient ${tokenIn?.symbol} balance`, disabled: true, kind: 'none' as const }
    }
    if (inState.allowance < spend)
      return { label: `Approve ${tokenIn?.symbol}`, disabled: busy, kind: 'approve' as const }
    return { label: 'Swap', disabled: busy, kind: 'swap' as const }
  }, [address, wrongNetwork, quote, result.status, inState, spend, tokenIn, busy])

  async function onSubmit() {
    if (!quote || !tokenIn || !tokenOut || !address) return
    const ctx = { tokenIn, tokenOut }
    if (action.kind === 'approve') {
      await execute(
        `Approve ${tokenIn.symbol}`,
        { address: tokenIn.address, abi: erc20Abi, functionName: 'approve', args: [deployment.router, spend] },
        ctx,
      )
      return
    }
    const path = quote.route.path.map((token) => token.address)
    const deadline = deadlineFromNow(settings.deadlineMinutes)
    const receipt =
      quote.mode === 'exactIn'
        ? await execute(
            `Swap ${tokenIn.symbol} → ${tokenOut.symbol}`,
            {
              address: deployment.router,
              abi: ammRouterAbi,
              functionName: 'swapExactTokensForTokens',
              args: [quote.amountIn, quote.minimumOut, path, address, deadline],
            },
            ctx,
          )
        : await execute(
            `Swap ${tokenIn.symbol} → ${tokenOut.symbol}`,
            {
              address: deployment.router,
              abi: ammRouterAbi,
              functionName: 'swapTokensForExactTokens',
              args: [quote.amountOut, quote.maximumIn, path, address, deadline],
            },
            ctx,
          )
    if (receipt) setTyped('')
  }

  return (
    <section className="card" aria-labelledby="swap-title">
      <div className="card-head">
        <h1 id="swap-title">Swap</h1>
        <SettingsPanel />
      </div>

      <div className="field">
        <div className="field-top">
          <span>You pay</span>
          {tokenIn && inState ? (
            <span className="muted" data-testid="balance-in">
              Balance {formatAmount(inState.balance, tokenIn.decimals)}
            </span>
          ) : null}
        </div>
        <div className="field-row">
          <input
            data-testid="swap-amount-in"
            inputMode="decimal"
            placeholder="0.0"
            value={displayIn}
            onChange={(event) => {
              setMode('exactIn')
              setTyped(event.target.value)
            }}
          />
          <TokenSelect
            testId="swap-token-in"
            tokens={deployment.tokens}
            value={tokenIn}
            onChange={(token) => {
              if (token.address === tokenOut?.address) setTokenOut(tokenIn)
              setTokenIn(token)
            }}
          />
        </div>
      </div>

      <button
        type="button"
        className="flip"
        aria-label="Reverse direction"
        onClick={() => {
          setTokenIn(tokenOut)
          setTokenOut(tokenIn)
          setMode(mode === 'exactIn' ? 'exactOut' : 'exactIn')
        }}
      >
        ↓↑
      </button>

      <div className="field">
        <div className="field-top">
          <span>You receive</span>
          {tokenOut && outState ? (
            <span className="muted">Balance {formatAmount(outState.balance, tokenOut.decimals)}</span>
          ) : null}
        </div>
        <div className="field-row">
          <input
            data-testid="swap-amount-out"
            inputMode="decimal"
            placeholder="0.0"
            value={displayOut}
            onChange={(event) => {
              setMode('exactOut')
              setTyped(event.target.value)
            }}
          />
          <TokenSelect
            testId="swap-token-out"
            tokens={deployment.tokens}
            value={tokenOut}
            onChange={(token) => {
              if (token.address === tokenIn?.address) setTokenIn(tokenOut)
              setTokenOut(token)
            }}
          />
        </div>
      </div>

      {quote && tokenIn && tokenOut ? (
        <dl className="details" data-testid="swap-details">
          <dt>Route</dt>
          <dd data-testid="swap-route">{quote.route.path.map((token) => token.symbol).join(' → ')}</dd>
          {quote.mode === 'exactIn' ? (
            <>
              <dt>Expected output</dt>
              <dd data-testid="swap-quote-out" data-raw={quote.amountOut.toString()}>
                {formatAmount(quote.amountOut, tokenOut.decimals, 8)} {tokenOut.symbol}
              </dd>
              <dt>Minimum received ({formatBps(settings.slippageBps)} slippage)</dt>
              <dd data-testid="swap-min-out" data-raw={quote.minimumOut.toString()}>
                {formatAmount(quote.minimumOut, tokenOut.decimals, 8)} {tokenOut.symbol}
              </dd>
            </>
          ) : (
            <>
              <dt>Expected input</dt>
              <dd data-testid="swap-quote-in" data-raw={quote.amountIn.toString()}>
                {formatAmount(quote.amountIn, tokenIn.decimals, 8)} {tokenIn.symbol}
              </dd>
              <dt>Maximum sold ({formatBps(settings.slippageBps)} slippage)</dt>
              <dd data-testid="swap-max-in" data-raw={quote.maximumIn.toString()}>
                {formatAmount(quote.maximumIn, tokenIn.decimals, 8)} {tokenIn.symbol}
              </dd>
            </>
          )}
          <dt>Price impact (incl. 0.30 % LP fee per hop)</dt>
          <dd data-testid="swap-price-impact" className={quote.priceImpactBps > 500n ? 'warn' : undefined}>
            {formatBps(quote.priceImpactBps)}
          </dd>
        </dl>
      ) : result.status === 'error' ? (
        <p className="error" data-testid="swap-quote-error">
          {result.message}
        </p>
      ) : null}

      <button
        type="button"
        className="primary wide"
        data-testid="swap-submit"
        disabled={action.disabled}
        onClick={() => void onSubmit()}
      >
        {action.label}
      </button>
    </section>
  )
}
