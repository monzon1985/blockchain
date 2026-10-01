// SPDX-License-Identifier: MIT
'use client'

import { useMemo, useState } from 'react'
import { domainSeparator, erc20Abi, parseSignature, type Address } from 'viem'
import { useConnection, useSignTypedData } from 'wagmi'

import { ammRouterAbi, useReadAmmPairBalanceOf, useReadAmmPairDomainSeparator, useReadAmmPairNonces } from '@/generated'
import { useNetworkGuard } from '@/hooks/useNetworkGuard'
import { usePools, type PoolState } from '@/hooks/usePools'
import { useTokenState } from '@/hooks/useTokenState'
import { useTransaction } from '@/hooks/useTransaction'
import { decodeError } from '@/lib/errors'
import { formatAmount, parseAmount } from '@/lib/format'
import { burnAmounts, liquidityMinted, minimumAmountOut, quote, QuoteError } from '@/lib/quote'
import type { PairInfo } from '@/lib/types'

import { useRuntime } from './RuntimeContext'
import { SettingsPanel, deadlineFromNow, useSettings } from './Settings'
import { useToasts } from './Toasts'

/** EIP-712 domain of every LP token (Solady ERC20: name, version "1", chain id, pair address). */
export const LP_TOKEN_NAME = 'Hardened AMM LP'

const PERMIT_TYPES = {
  Permit: [
    { name: 'owner', type: 'address' },
    { name: 'spender', type: 'address' },
    { name: 'value', type: 'uint256' },
    { name: 'nonce', type: 'uint256' },
    { name: 'deadline', type: 'uint256' },
  ],
} as const

function PairSelect(props: {
  testId: string
  pairs: readonly PairInfo[]
  value: PairInfo
  onChange: (p: PairInfo) => void
}) {
  return (
    <select
      data-testid={props.testId}
      value={props.value.address}
      onChange={(event) => {
        const pair = props.pairs.find((item) => item.address === event.target.value)
        if (pair) props.onChange(pair)
      }}
    >
      {props.pairs.map((pair) => (
        <option key={pair.address} value={pair.address}>
          {pair.token0.symbol} / {pair.token1.symbol}
        </option>
      ))}
    </select>
  )
}

function poolOf(pools: ReadonlyMap<Address, PoolState>, pair: PairInfo): PoolState {
  return pools.get(pair.address) ?? { pair, reserve0: 0n, reserve1: 0n, totalSupply: 0n }
}

export function AddLiquidityCard() {
  const { deployment } = useRuntime()
  const { address } = useConnection()
  const settings = useSettings()
  const { pools } = usePools()
  const tokenState = useTokenState()
  const { execute, busy } = useTransaction()
  const { wrongNetwork } = useNetworkGuard()
  const [pair, setPair] = useState<PairInfo>(deployment.pairs[0]!)
  // The last edited side drives the other one at the pool ratio; an empty pool takes both amounts as typed.
  const [inputs, setInputs] = useState<{ values: [string, string]; last: 0 | 1 }>({ values: ['', ''], last: 0 })

  const pool = poolOf(pools, pair)
  const tokens = [pair.token0, pair.token1] as const
  const emptyPool = pool.reserve0 === 0n && pool.reserve1 === 0n

  const plan = useMemo(() => {
    const side = inputs.last
    const other = (1 - side) as 0 | 1
    const sideToken = side === 0 ? pair.token0 : pair.token1
    const otherToken = side === 0 ? pair.token1 : pair.token0
    const typedAmount = parseAmount(inputs.values[side], sideToken.decimals)
    if (typedAmount === null || typedAmount === 0n) return null
    const reserveSide = side === 0 ? pool.reserve0 : pool.reserve1
    const reserveOther = side === 0 ? pool.reserve1 : pool.reserve0
    try {
      const otherAmount =
        reserveSide === 0n && reserveOther === 0n
          ? parseAmount(inputs.values[other], otherToken.decimals)
          : quote(typedAmount, reserveSide, reserveOther)
      if (otherAmount === null) return null
      const amounts: [bigint, bigint] = side === 0 ? [typedAmount, otherAmount] : [otherAmount, typedAmount]
      const liquidity = liquidityMinted(amounts[0], amounts[1], pool.reserve0, pool.reserve1, pool.totalSupply)
      return { amounts, liquidity }
    } catch (error) {
      if (error instanceof QuoteError) return null
      throw error
    }
  }, [inputs, pair, pool.reserve0, pool.reserve1, pool.totalSupply])

  const needsApproval = plan
    ? tokens.map((token, i) => (tokenState.get(token.address)?.allowance ?? 0n) < plan.amounts[i]!)
    : [false, false]
  const insufficient = plan
    ? tokens.find((token, i) => (tokenState.get(token.address)?.balance ?? 0n) < plan.amounts[i]!)
    : undefined

  async function onSubmit() {
    if (!plan || !address) return
    const approveIndex = needsApproval.findIndex(Boolean)
    if (approveIndex >= 0) {
      const token = tokens[approveIndex as 0 | 1]
      await execute(`Approve ${token.symbol}`, {
        address: token.address,
        abi: erc20Abi,
        functionName: 'approve',
        args: [deployment.router, plan.amounts[approveIndex]!],
      })
      return
    }
    const receipt = await execute(`Add ${pair.token0.symbol}/${pair.token1.symbol} liquidity`, {
      address: deployment.router,
      abi: ammRouterAbi,
      functionName: 'addLiquidity',
      args: [
        pair.token0.address,
        pair.token1.address,
        plan.amounts[0],
        plan.amounts[1],
        minimumAmountOut(plan.amounts[0], settings.slippageBps),
        minimumAmountOut(plan.amounts[1], settings.slippageBps),
        address,
        deadlineFromNow(settings.deadlineMinutes),
      ],
    })
    if (receipt) setInputs({ values: ['', ''], last: 0 })
  }

  const label = !address
    ? 'Connect a wallet'
    : wrongNetwork
      ? 'Switch your wallet to Anvil'
      : !plan
        ? 'Enter an amount'
        : insufficient
          ? `Insufficient ${insufficient.symbol} balance`
          : needsApproval[0]
            ? `Approve ${tokens[0].symbol}`
            : needsApproval[1]
              ? `Approve ${tokens[1].symbol}`
              : 'Add liquidity'

  return (
    <section className="card" aria-labelledby="add-title">
      <div className="card-head">
        <h2 id="add-title">Add liquidity</h2>
        <SettingsPanel />
      </div>
      <PairSelect
        testId="add-pair"
        pairs={deployment.pairs}
        value={pair}
        onChange={(p) => {
          setPair(p)
          setInputs({ values: ['', ''], last: 0 })
        }}
      />
      {emptyPool ? <p className="muted">Empty pool: your first deposit sets the price.</p> : null}
      {tokens.map((token, i) => (
        <div className="field" key={token.address}>
          <div className="field-top">
            <span>{token.symbol}</span>
            <span className="muted">
              Balance {formatAmount(tokenState.get(token.address)?.balance ?? 0n, token.decimals)}
            </span>
          </div>
          <input
            data-testid={`add-amount-${i}`}
            inputMode="decimal"
            placeholder="0.0"
            value={
              inputs.last === i || emptyPool
                ? inputs.values[i]
                : plan
                  ? formatAmount(plan.amounts[i]!, token.decimals, token.decimals).replaceAll(',', '')
                  : ''
            }
            onChange={(event) => {
              const values: [string, string] = [...inputs.values]
              values[i] = event.target.value
              setInputs({ values, last: i as 0 | 1 })
            }}
          />
        </div>
      ))}
      {plan ? (
        <dl className="details">
          <dt>LP tokens (estimate)</dt>
          <dd data-testid="add-lp-estimate" data-raw={plan.liquidity.toString()}>
            {formatAmount(plan.liquidity, 18)}
          </dd>
          <dt>Share of pool</dt>
          <dd>
            {pool.totalSupply > 0n
              ? `${formatAmount((plan.liquidity * 10n ** 6n) / (pool.totalSupply + plan.liquidity), 4, 4)} %`
              : '100 %'}
          </dd>
        </dl>
      ) : null}
      <button
        type="button"
        className="primary wide"
        data-testid="add-submit"
        disabled={!address || wrongNetwork || !plan || !!insufficient || busy || plan.liquidity === 0n}
        onClick={() => void onSubmit()}
      >
        {label}
      </button>
    </section>
  )
}

export function RemoveLiquidityCard() {
  const { deployment } = useRuntime()
  const { address } = useConnection()
  const { wrongNetwork, expectedChainId } = useNetworkGuard()
  const settings = useSettings()
  const { pools } = usePools()
  const toasts = useToasts()
  const { execute, busy } = useTransaction()
  const { mutateAsync: signTypedData } = useSignTypedData()
  const [pair, setPair] = useState<PairInfo>(deployment.pairs[0]!)
  const [percent, setPercent] = useState(100)

  const pool = poolOf(pools, pair)
  const account = address ?? '0x0000000000000000000000000000000000000000'
  const { data: lpBalance = 0n } = useReadAmmPairBalanceOf({
    address: pair.address,
    args: [account],
    query: { enabled: !!address },
  })
  const { data: nonce } = useReadAmmPairNonces({
    address: pair.address,
    args: [account],
    query: { enabled: !!address },
  })
  const { data: onChainDomain } = useReadAmmPairDomainSeparator({ address: pair.address })

  // The deployment's chain, never the wallet's: a permit is only valid on the chain whose pair verifies it.
  const domain = {
    name: LP_TOKEN_NAME,
    version: '1',
    chainId: expectedChainId,
    verifyingContract: pair.address,
  } as const
  // Refuse to sign unless the domain we are about to sign matches the pair's own DOMAIN_SEPARATOR.
  const domainVerified = onChainDomain !== undefined && domainSeparator({ domain }) === onChainDomain

  const liquidity = (lpBalance * BigInt(percent)) / 100n
  const { amountA: amount0, amountB: amount1 } = burnAmounts(liquidity, pool.reserve0, pool.reserve1, pool.totalSupply)

  async function onSubmit() {
    // signTypedData cannot assert the wallet's chain the way a write does, so refuse to sign on another network.
    if (!address || wrongNetwork || liquidity === 0n || nonce === undefined) return
    const deadline = deadlineFromNow(settings.deadlineMinutes)
    let signature
    const id = toasts.push({
      kind: 'pending',
      title: 'Sign LP permit',
      message: 'Sign the EIP-2612 permit in your wallet…',
    })
    try {
      signature = await signTypedData({
        domain,
        types: PERMIT_TYPES,
        primaryType: 'Permit',
        message: { owner: address, spender: deployment.router, value: liquidity, nonce, deadline },
      })
      toasts.update(id, { kind: 'success', message: 'Permit signed (no approval transaction needed)' })
    } catch (error) {
      const decoded = decodeError(error)
      toasts.update(id, {
        kind: 'error',
        title: 'Permit not signed',
        message: decoded.message,
        errorName: decoded.name,
      })
      return
    }
    const { r, s, v, yParity } = parseSignature(signature)
    await execute(`Remove ${pair.token0.symbol}/${pair.token1.symbol} liquidity`, {
      address: deployment.router,
      abi: ammRouterAbi,
      functionName: 'removeLiquidityWithPermit',
      args: [
        pair.token0.address,
        pair.token1.address,
        liquidity,
        minimumAmountOut(amount0, settings.slippageBps),
        minimumAmountOut(amount1, settings.slippageBps),
        address,
        deadline,
        false,
        Number(v ?? BigInt(yParity + 27)),
        r,
        s,
      ],
    })
  }

  return (
    <section className="card" aria-labelledby="remove-title">
      <div className="card-head">
        <h2 id="remove-title">Remove liquidity</h2>
        <SettingsPanel />
      </div>
      <PairSelect testId="remove-pair" pairs={deployment.pairs} value={pair} onChange={setPair} />
      <p className="muted">
        LP balance{' '}
        <span data-testid="lp-balance" data-raw={lpBalance.toString()}>
          {formatAmount(lpBalance, 18)}
        </span>
        {domainVerified ? (
          <span className="badge" title="DOMAIN_SEPARATOR matches the signed domain">
            EIP-712 domain verified
          </span>
        ) : null}
      </p>
      <div className="row">
        {[25, 50, 75, 100].map((value) => (
          <button
            key={value}
            type="button"
            data-testid={`remove-pct-${value}`}
            className={percent === value ? 'chip active' : 'chip'}
            onClick={() => setPercent(value)}
          >
            {value} %
          </button>
        ))}
      </div>
      <dl className="details">
        <dt>You receive (estimate)</dt>
        <dd data-testid="remove-estimate">
          {formatAmount(amount0, pair.token0.decimals)} {pair.token0.symbol} +{' '}
          {formatAmount(amount1, pair.token1.decimals)} {pair.token1.symbol}
        </dd>
      </dl>
      <button
        type="button"
        className="primary wide"
        data-testid="remove-submit"
        disabled={!address || wrongNetwork || liquidity === 0n || busy || !domainVerified}
        onClick={() => void onSubmit()}
      >
        {!address
          ? 'Connect a wallet'
          : wrongNetwork
            ? 'Switch your wallet to Anvil'
            : liquidity === 0n
              ? 'No liquidity to remove'
              : 'Sign permit & remove'}
      </button>
    </section>
  )
}
