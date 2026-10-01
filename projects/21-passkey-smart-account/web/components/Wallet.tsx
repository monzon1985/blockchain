// SPDX-License-Identifier: MIT
'use client'

import { useQuery } from '@tanstack/react-query'
import { useCallback, useMemo, useState } from 'react'
import { concat, encodeFunctionData, formatUnits, isAddress, parseUnits, type Address, type Hex } from 'viem'
import { generatePrivateKey, privateKeyToAccount } from 'viem/accounts'
import { usePublicClient } from 'wagmi'

import { useWalletConfig } from '@/app/providers'
import { accountAbi, erc20Abi } from '@/lib/abis'
import { createPasskey, signWithPasskey, toOnchainPasskey, type StoredPasskey } from '@/lib/passkey'
import { checkAuthorizationPolicy, type AuthorizationPolicyResult } from '@/lib/shared'
import {
  counterfactualAddress,
  encodeBatch,
  factoryInit,
  initParams,
  sendUserOperation,
  STUB_EOA_SIGNATURE,
  stubWebAuthnSignature,
  type Call,
  type UserOpReceipt,
} from '@/lib/userop'

interface LogEntry {
  readonly id: number
  readonly label: string
  readonly status: 'pending' | 'ok' | 'failed'
  readonly detail: string
}

interface EoaView {
  usd: bigint
  code: Hex
  initialized: boolean
}

interface AccountView {
  deployed: boolean
  usd: bigint
  guardians: readonly Address[]
  threshold: number
  pendingExecutableAt: number
  onchainKeyQx: Hex
}

const DEMO_RECIPIENTS: readonly Address[] = [
  '0x000000000000000000000000000000000000a11c',
  '0x0000000000000000000000000000000000000b0b',
]

function short(value: string, keep = 6): string {
  return value.length <= 2 * keep + 2 ? value : `${value.slice(0, keep + 2)}…${value.slice(-keep)}`
}

function tusd(amount: bigint): string {
  return `${formatUnits(amount, 6)} TUSD`
}

async function post(path: string, body: unknown): Promise<unknown> {
  const response = await fetch(path, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
  })
  if (!response.ok) throw new Error(`${path}: ${await response.text()}`)
  return response.json()
}

export function Wallet() {
  const cfg = useWalletConfig()
  const client = usePublicClient()
  const [keys, setKeys] = useState<StoredPasskey[]>([])
  const [activeKey, setActiveKey] = useState(0)
  const [account, setAccount] = useState<Address | null>(null)
  const [log, setLog] = useState<LogEntry[]>([])
  const [busy, setBusy] = useState(false)
  const [amounts, setAmounts] = useState<string[]>(['1.5', '2'])
  const [recipients, setRecipients] = useState<string[]>([...DEMO_RECIPIENTS])
  const [eoaKey, setEoaKey] = useState<Hex | null>(null)
  const [targetCheck, setTargetCheck] = useState<AuthorizationPolicyResult | null>(null)
  const [sweeperCheck, setSweeperCheck] = useState<AuthorizationPolicyResult | null>(null)

  const eoa = useMemo(() => (eoaKey === null ? null : privateKeyToAccount(eoaKey)), [eoaKey])
  const primary = keys[0]
  const replacement = keys[1]
  const currentKey = keys[activeKey]

  const addLog = useCallback((label: string, status: LogEntry['status'], detail = ''): number => {
    const id = Date.now() + Math.random()
    setLog((l) => [{ id, label, status, detail }, ...l])
    return id
  }, [])

  const updateLog = useCallback((id: number, status: LogEntry['status'], detail: string) => {
    setLog((l) => l.map((e) => (e.id === id ? { ...e, status, detail } : e)))
  }, [])

  // On-chain view of the smart account and the demo EOA, refetched after every action.
  const chainView = useQuery({
    queryKey: ['wallet-view', account, eoa?.address, cfg.testUsd],
    enabled: client !== undefined,
    queryFn: async (): Promise<{ view: AccountView | null; eoaView: EoaView | null }> => {
      if (client === undefined) return { view: null, eoaView: null }
      let view: AccountView | null = null
      if (account !== null) {
        const code = await client.getCode({ address: account })
        const deployed = code !== undefined && code !== '0x'
        const usd = await client.readContract({ address: cfg.testUsd, abi: erc20Abi, functionName: 'balanceOf', args: [account] })
        view = { deployed, usd, guardians: [], threshold: 0, pendingExecutableAt: 0, onchainKeyQx: '0x' }
        if (deployed) {
          const pending = await client.readContract({ address: account, abi: accountAbi, functionName: 'pendingRecovery' })
          view = {
            deployed,
            usd,
            guardians: await client.readContract({ address: account, abi: accountAbi, functionName: 'guardians' }),
            threshold: await client.readContract({ address: account, abi: accountAbi, functionName: 'guardianThreshold' }),
            pendingExecutableAt: Number(pending.executableAt),
            onchainKeyQx: (await client.readContract({ address: account, abi: accountAbi, functionName: 'passkey' })).qx,
          }
        }
      }
      let eoaView: EoaView | null = null
      if (eoa !== null) {
        const code = (await client.getCode({ address: eoa.address })) ?? '0x'
        const usd = await client.readContract({ address: cfg.testUsd, abi: erc20Abi, functionName: 'balanceOf', args: [eoa.address] })
        const initialized =
          code.startsWith('0xef0100') &&
          (await client.readContract({ address: eoa.address, abi: accountAbi, functionName: 'initialized' }))
        eoaView = { usd, code, initialized }
      }
      return { view, eoaView }
    },
  })
  const view = chainView.data?.view ?? null
  const eoaView = chainView.data?.eoaView ?? null
  const { refetch } = chainView
  const refresh = useCallback(async () => {
    await refetch()
  }, [refetch])

  /** Runs one action, recording it in the activity log with the user operation outcome. */
  const run = useCallback(
    async (label: string, action: (stage: (s: string) => void) => Promise<string>) => {
      setBusy(true)
      const id = addLog(label, 'pending', 'starting')
      try {
        const detail = await action((s) => updateLog(id, 'pending', s))
        updateLog(id, 'ok', detail)
      } catch (error) {
        updateLog(id, 'failed', error instanceof Error ? error.message : String(error))
      } finally {
        setBusy(false)
        await refresh()
      }
    },
    [addLog, updateLog, refresh],
  )

  const describe = (r: UserOpReceipt): string =>
    `${r.success ? 'success' : 'reverted'} · userOp ${short(r.userOpHash)} · tx ${short(r.receipt.transactionHash)}`

  const passkeySigner = (key: StoredPasskey) => ({
    stubSignature: stubWebAuthnSignature(window.location.origin, key.rpId),
    sign: (hash: Hex) => signWithPasskey(key, hash),
  })

  // ------------------------------------------------------------------------------------------------ actions

  const onCreatePasskey = () =>
    run('Create passkey', async () => {
      const key = await createPasskey(`owner-${keys.length + 1}`)
      const next = [...keys, key]
      setKeys(next)
      if (next.length === 1 && client !== undefined) setAccount(await counterfactualAddress(client, cfg, toOnchainPasskey(key)))
      return `P-256 key ${short(key.qx)} for rp id "${key.rpId}"`
    })

  const onFaucet = (to: Address) =>
    run('Faucet: 100 TUSD', async () => {
      await post('/api/dev/faucet', { to })
      return `minted to ${short(to)}`
    })

  const onDeploy = () =>
    run('Deploy account (guaranteed first op)', async (stage) => {
      if (client === undefined || account === null || primary === undefined) throw new Error('create a passkey first')
      const receipt = await sendUserOperation({
        client,
        cfg,
        sender: account,
        factory: factoryInit(cfg, toOnchainPasskey(primary)),
        callData: encodeBatch([
          { to: cfg.testUsd, data: encodeFunctionData({ abi: erc20Abi, functionName: 'approve', args: [cfg.paymaster, 2n ** 256n - 1n] }) },
        ]),
        paymasterMode: 'guaranteed',
        ...passkeySigner(primary),
        onStage: stage,
      })
      return describe(receipt)
    })

  const onSendBatch = () =>
    run('Paymaster batch transfer (gas in TUSD)', async (stage) => {
      if (client === undefined || account === null || currentKey === undefined) throw new Error('no account')
      const calls: Call[] = recipients.map((to, i) => {
        if (!isAddress(to, { strict: false })) throw new Error(`invalid recipient ${to}`)
        return {
          to: cfg.testUsd,
          data: encodeFunctionData({ abi: erc20Abi, functionName: 'transfer', args: [to, parseUnits(amounts[i] ?? '0', 6)] }),
        }
      })
      const before = view?.usd ?? 0n
      const receipt = await sendUserOperation({
        client,
        cfg,
        sender: account,
        callData: encodeBatch(calls),
        paymasterMode: 'user',
        ...passkeySigner(currentKey),
        onStage: stage,
      })
      const after = await client.readContract({ address: cfg.testUsd, abi: erc20Abi, functionName: 'balanceOf', args: [account] })
      const sent = amounts.reduce((acc, a) => acc + parseUnits(a, 6), 0n)
      return `${describe(receipt)} · gas paid ${tusd(before - after - sent)}`
    })

  const onAddGuardians = () =>
    run('Add guardians (2-of-3)', async (stage) => {
      if (client === undefined || account === null || currentKey === undefined) throw new Error('no account')
      const calls: Call[] = [
        ...cfg.guardians.map((g) => ({ to: account, data: encodeFunctionData({ abi: accountAbi, functionName: 'addGuardian', args: [g] }) })),
        { to: account, data: encodeFunctionData({ abi: accountAbi, functionName: 'setGuardianThreshold', args: [2] }) },
      ]
      const receipt = await sendUserOperation({
        client,
        cfg,
        sender: account,
        callData: encodeBatch(calls),
        paymasterMode: 'user',
        ...passkeySigner(currentKey),
        onStage: stage,
      })
      return describe(receipt)
    })

  const onCreateReplacement = () =>
    run('Create replacement passkey', async () => {
      const key = await createPasskey(`recovery-${keys.length + 1}`)
      setKeys((k) => [...k.slice(0, 1), key])
      return `replacement key ${short(key.qx)}`
    })

  const onGuardianApprove = (index: number) =>
    run(`Guardian ${index + 1} approves recovery`, async () => {
      if (account === null || replacement === undefined) throw new Error('create a replacement passkey first')
      await post('/api/dev/guardian', { guardianIndex: index, account, newPasskey: toOnchainPasskey(replacement) })
      return `guardian ${short(cfg.guardians[index] ?? '')} approved`
    })

  const onVeto = () =>
    run('Owner veto (cancel recovery)', async (stage) => {
      if (client === undefined || account === null || currentKey === undefined) throw new Error('no account')
      const receipt = await sendUserOperation({
        client,
        cfg,
        sender: account,
        callData: encodeFunctionData({ abi: accountAbi, functionName: 'cancelRecovery' }),
        paymasterMode: 'user',
        ...passkeySigner(currentKey),
        onStage: stage,
      })
      return describe(receipt)
    })

  const onTimeTravel = () =>
    run('Fast-forward 48 h (devnet clock)', async () => {
      await post('/api/dev/time', { seconds: 48 * 3600 + 60 })
      return 'clock advanced'
    })

  const onExecuteRecovery = () =>
    run('Execute recovery', async () => {
      if (account === null) throw new Error('no account')
      await post('/api/dev/execute-recovery', { account })
      setActiveKey(1)
      return 'replacement passkey installed'
    })

  const onCreateEoa = () =>
    run('Create demo EOA', async () => {
      const key = generatePrivateKey()
      setEoaKey(key)
      return `EOA ${short(privateKeyToAccount(key).address)} (key kept in memory only)`
    })

  const checkTarget = async (address: Address): Promise<AuthorizationPolicyResult> => {
    if (client === undefined) throw new Error('no client')
    const code = (await client.getCode({ address })) ?? '0x'
    // The local EntryPoint is compiled from source (non-canonical address): tell the classifier it is the trusted
    // caller, so EntryPoint-guarded execution counts as owner-controlled.
    return checkAuthorizationPolicy(
      { chainId: cfg.chainId, address, nonce: 0 },
      { currentChainId: cfg.chainId, targetCode: code, trustedCallers: [cfg.entryPoint] },
    )
  }

  const onCheckTarget = () =>
    run('Check delegation target', async () => {
      const result = await checkTarget(cfg.accountImplementation)
      setTargetCheck(result)
      return `PasskeyAccount: ${result.classification.verdict}`
    })

  const onCheckSweeper = () =>
    run('Check demo sweeper as delegation target', async () => {
      if (cfg.demoSweeper === undefined) throw new Error('no demo sweeper on this devnet')
      const result = await checkTarget(cfg.demoSweeper)
      setSweeperCheck(result)
      return result.allowed ? 'allowed' : `refused: ${result.reasons.join('; ')}`
    })

  /**
   * Delegates the demo EOA to `target`. The signing policy runs on the target's code before the EOA key signs
   * anything; a refused target never gets an authorization, so no type-4 transaction can be sent.
   */
  const upgradeEoa = (label: string, target: Address) =>
    run(label, async (stage) => {
      if (client === undefined || eoa === null || primary === undefined) throw new Error('create a passkey and an EOA first')
      const nonce = await client.getTransactionCount({ address: eoa.address })
      const policy = await checkTarget(target)
      setTargetCheck(policy)
      if (!policy.allowed) throw new Error(`authorization refused: ${policy.reasons.join('; ')}`)
      const authorization = await eoa.signAuthorization({ contractAddress: target, chainId: cfg.chainId, nonce })
      const receipt = await sendUserOperation({
        client,
        cfg,
        sender: eoa.address,
        factory: { factory: '0x7702', factoryData: '0x' },
        authorization,
        callData: encodeBatch([
          { to: eoa.address, data: encodeFunctionData({ abi: accountAbi, functionName: 'initialize', args: [initParams(toOnchainPasskey(primary))] }) },
          { to: cfg.testUsd, data: encodeFunctionData({ abi: erc20Abi, functionName: 'approve', args: [cfg.paymaster, 2n ** 256n - 1n] }) },
        ]),
        paymasterMode: 'guaranteed',
        stubSignature: STUB_EOA_SIGNATURE,
        // The first operation is signed by the EOA key itself (SignerEIP7702); later ones by the passkey.
        sign: async (hash) => concat(['0x01', await eoa.sign({ hash })]),
        onStage: stage,
      })
      return describe(receipt)
    })

  const onUpgradeEoa = () => upgradeEoa('Upgrade EOA with EIP-7702', cfg.accountImplementation)

  // Dev tools only: tries to delegate to the devnet's sweeper, to show the policy refusing on the real signing path.
  const onUpgradeEoaToSweeper = () => {
    if (cfg.demoSweeper !== undefined) void upgradeEoa('Upgrade EOA to the demo sweeper (dev check)', cfg.demoSweeper)
  }

  // ------------------------------------------------------------------------------------------------ view

  const pending = view !== null && view.pendingExecutableAt > 0
  return (
    <>
      <section className="card">
        <h2>1 · Passkey</h2>
        <div className="kv">
          <span className="muted">Owner passkey</span>
          <span className="mono" data-testid="passkey-primary">{primary === undefined ? '—' : short(primary.qx, 10)}</span>
          <span className="muted">Replacement</span>
          <span className="mono" data-testid="passkey-replacement">{replacement === undefined ? '—' : short(replacement.qx, 10)}</span>
          <span className="muted">Signing with</span>
          <span data-testid="active-passkey">{currentKey === undefined ? '—' : currentKey.label}</span>
        </div>
        <div className="row">
          <button data-testid="create-passkey" disabled={busy || primary !== undefined} onClick={onCreatePasskey}>
            Create passkey
          </button>
        </div>
      </section>

      <section className="card">
        <h2>2 · Smart account (ERC-4337, CREATE2 factory)</h2>
        <div className="kv">
          <span className="muted">Address</span>
          <span className="mono" data-testid="account-address">{account ?? '—'}</span>
          <span className="muted">Status</span>
          <span data-testid="account-status">{view === null ? '—' : view.deployed ? 'deployed' : 'counterfactual'}</span>
          <span className="muted">Balance</span>
          <span data-testid="account-balance">{view === null ? '—' : tusd(view.usd)}</span>
        </div>
        <div className="row">
          <button className="secondary" data-testid="faucet-account" disabled={busy || account === null} onClick={() => account !== null && onFaucet(account)}>
            Faucet 100 TUSD
          </button>
          <button data-testid="deploy-account" disabled={busy || account === null || view?.deployed === true} onClick={onDeploy}>
            Deploy (gasless first op)
          </button>
        </div>
      </section>

      <section className="card">
        <h2>3 · ERC-20-paid batch (paymaster, gas paid in TestUSD)</h2>
        {recipients.map((to, i) => (
          <div className="row" key={i}>
            <input aria-label={`recipient ${i + 1}`} value={to} size={44} onChange={(e) => setRecipients((r) => r.map((v, j) => (j === i ? e.target.value : v)))} />
            <input aria-label={`amount ${i + 1}`} value={amounts[i]} size={6} onChange={(e) => setAmounts((a) => a.map((v, j) => (j === i ? e.target.value : v)))} />
          </div>
        ))}
        <button data-testid="send-batch" disabled={busy || view?.deployed !== true} onClick={onSendBatch}>
          Send batch
        </button>
      </section>

      <section className="card">
        <h2>4 · Guardians and recovery</h2>
        <div className="kv">
          <span className="muted">Guardians</span>
          <span data-testid="guardian-count">{view === null ? '—' : `${view.guardians.length} (threshold ${view.threshold})`}</span>
          <span className="muted">Recovery</span>
          <span data-testid="recovery-status">
            {pending ? `scheduled, executable at ${new Date((view?.pendingExecutableAt ?? 0) * 1000).toISOString()}` : 'none'}
          </span>
          <span className="muted">On-chain passkey</span>
          <span className="mono" data-testid="onchain-passkey">{view?.onchainKeyQx === undefined ? '—' : short(view.onchainKeyQx, 10)}</span>
        </div>
        <div className="row">
          <button data-testid="add-guardians" disabled={busy || view?.deployed !== true || (view?.guardians.length ?? 0) > 0} onClick={onAddGuardians}>
            Add 3 guardians (2-of-3)
          </button>
          <button className="secondary" data-testid="create-recovery-passkey" disabled={busy || primary === undefined} onClick={onCreateReplacement}>
            New passkey for recovery
          </button>
        </div>
        <div className="row">
          {cfg.guardians.map((g, i) => (
            <button key={g} className="secondary" data-testid={`guardian-approve-${i}`} disabled={busy || replacement === undefined || pending} onClick={() => onGuardianApprove(i)}>
              Guardian {i + 1} approves
            </button>
          ))}
        </div>
        <div className="row">
          <button className="secondary" data-testid="veto-recovery" disabled={busy || !pending} onClick={onVeto}>
            Owner veto
          </button>
          <button className="secondary" data-testid="time-travel" disabled={busy || !pending} onClick={onTimeTravel}>
            Fast-forward 48 h
          </button>
          <button data-testid="execute-recovery" disabled={busy || !pending} onClick={onExecuteRecovery}>
            Execute recovery
          </button>
        </div>
      </section>

      <section className="card">
        <h2>5 · Upgrade an EOA (EIP-7702)</h2>
        <div className="kv">
          <span className="muted">EOA</span>
          <span className="mono" data-testid="eoa-address">{eoa?.address ?? '—'}</span>
          <span className="muted">Code</span>
          <span className="mono" data-testid="eoa-status">
            {eoaView === null ? '—' : eoaView.code === '0x' ? 'plain EOA' : eoaView.initialized ? 'delegated to PasskeyAccount, initialized' : short(eoaView.code)}
          </span>
          <span className="muted">Balance</span>
          <span data-testid="eoa-balance">{eoaView === null ? '—' : tusd(eoaView.usd)}</span>
          <span className="muted">Target check</span>
          <span data-testid="target-verdict">{targetCheck === null ? '—' : `${targetCheck.classification.verdict}${targetCheck.allowed ? ' · allowed' : ' · refused'}`}</span>
          <span className="muted">Demo sweeper</span>
          <span data-testid="sweeper-verdict">
            {sweeperCheck === null ? '—' : `${sweeperCheck.classification.verdict} · ${sweeperCheck.allowed ? 'allowed' : 'refused'}`}
          </span>
        </div>
        <div className="row">
          <button className="secondary" data-testid="create-eoa" disabled={busy || eoa !== null} onClick={onCreateEoa}>
            Create demo EOA
          </button>
          <button className="secondary" data-testid="faucet-eoa" disabled={busy || eoa === null} onClick={() => eoa !== null && onFaucet(eoa.address)}>
            Faucet 100 TUSD
          </button>
          <button className="secondary" data-testid="check-target" disabled={busy} onClick={onCheckTarget}>
            Check target
          </button>
          <button className="secondary" data-testid="check-sweeper" disabled={busy || cfg.demoSweeper === undefined} onClick={onCheckSweeper}>
            Check demo sweeper
          </button>
          <button data-testid="upgrade-eoa" disabled={busy || eoa === null || primary === undefined || eoaView?.initialized === true} onClick={onUpgradeEoa}>
            Upgrade EOA
          </button>
          {cfg.devTools && cfg.demoSweeper !== undefined && (
            <button className="secondary" data-testid="upgrade-eoa-sweeper" disabled={busy || eoa === null || primary === undefined} onClick={onUpgradeEoaToSweeper}>
              Try delegating to the demo sweeper
            </button>
          )}
        </div>
      </section>

      <section className="card wide">
        <h2>Activity</h2>
        <ul className="log" data-testid="activity">
          {log.map((e) => (
            <li key={e.id} data-status={e.status}>
              <span className={`badge ${e.status === 'ok' ? 'ok' : e.status === 'failed' ? 'bad' : 'warn'}`}>{e.status}</span>{' '}
              <strong>{e.label}</strong> <span className="muted">{e.detail}</span>
            </li>
          ))}
        </ul>
      </section>
    </>
  )
}
