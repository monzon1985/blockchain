// SPDX-License-Identifier: MIT
'use client'

import { useState } from 'react'
import { useConnect, useConnection, useConnectors, useDisconnect, useSwitchChain } from 'wagmi'

import { useNetworkGuard } from '@/hooks/useNetworkGuard'
import { shortHex } from '@/lib/format'

import { useRuntime } from './RuntimeContext'

/**
 * Custom connect UI (no third-party modal): lists wagmi's connectors, i.e. EIP-6963 / injected browser wallets and,
 * on the local chain, the mock connector backed by anvil's unlocked dev account.
 */
export function ConnectButton() {
  const runtime = useRuntime()
  const { address, status, connector } = useConnection()
  const { wrongNetwork, walletChainId, expectedChainId } = useNetworkGuard()
  const connectors = useConnectors()
  const connect = useConnect()
  const disconnect = useDisconnect()
  const switchChain = useSwitchChain()
  const [open, setOpen] = useState(false)

  if (status === 'connected' && address) {
    return (
      <div className="wallet">
        {wrongNetwork ? (
          <button
            type="button"
            className="danger"
            data-testid="switch-network"
            title={`Your wallet is on chain ${walletChainId}; this deployment is on chain ${expectedChainId}.`}
            onClick={() => switchChain.mutate({ chainId: expectedChainId })}
          >
            Wrong network: switch to Anvil
          </button>
        ) : null}
        <span className="address" data-testid="connected-address" title={address}>
          {shortHex(address)}
        </span>
        <small className="muted">{connector?.name}</small>
        <button type="button" className="secondary" onClick={() => disconnect.mutate({})}>
          Disconnect
        </button>
      </div>
    )
  }

  return (
    <div className="wallet">
      <button type="button" data-testid="connect-open" onClick={() => setOpen((value) => !value)}>
        {status === 'connecting' || status === 'reconnecting' ? 'Connecting…' : 'Connect wallet'}
      </button>
      {open ? (
        <ul className="connectors" role="menu">
          {connectors.map((item) => (
            <li key={item.uid}>
              <button
                type="button"
                role="menuitem"
                data-testid={`connector-${item.type}`}
                onClick={() =>
                  connect.mutate(
                    { connector: item, chainId: runtime.deployment.chainId },
                    { onSuccess: () => setOpen(false) },
                  )
                }
              >
                {item.type === 'mock' ? 'Anvil test account (local only)' : item.name}
              </button>
            </li>
          ))}
          {connect.error ? <li className="error">{connect.error.message.split('\n')[0]}</li> : null}
        </ul>
      ) : null}
    </div>
  )
}
