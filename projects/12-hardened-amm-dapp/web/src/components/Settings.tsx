// SPDX-License-Identifier: MIT
'use client'

import { createContext, useContext, useMemo, useState, type ReactNode } from 'react'

import { formatBps, parseSlippagePercent } from '@/lib/format'

export interface TradeSettings {
  /** Slippage tolerance in basis points (50 = 0.50 %). */
  slippageBps: bigint
  /** Transaction deadline, in minutes from the moment the transaction is built. */
  deadlineMinutes: number
}

interface SettingsApi extends TradeSettings {
  setSlippageBps: (bps: bigint) => void
  setDeadlineMinutes: (minutes: number) => void
}

export const DEFAULT_SETTINGS: TradeSettings = { slippageBps: 50n, deadlineMinutes: 20 }
const SettingsContext = createContext<SettingsApi | null>(null)

export function useSettings(): SettingsApi {
  const api = useContext(SettingsContext)
  if (!api) throw new Error('useSettings must be used inside <SettingsProvider>')
  return api
}

/** Deadline timestamp (seconds) for a transaction built now. */
export function deadlineFromNow(minutes: number): bigint {
  return BigInt(Math.floor(Date.now() / 1000) + minutes * 60)
}

export function SettingsProvider({ children }: { children: ReactNode }) {
  const [slippageBps, setSlippageBps] = useState(DEFAULT_SETTINGS.slippageBps)
  const [deadlineMinutes, setDeadlineMinutes] = useState(DEFAULT_SETTINGS.deadlineMinutes)

  const api = useMemo(
    () => ({ slippageBps, deadlineMinutes, setSlippageBps, setDeadlineMinutes }),
    [slippageBps, deadlineMinutes],
  )
  return <SettingsContext.Provider value={api}>{children}</SettingsContext.Provider>
}

const PRESETS = [10n, 50n, 100n]

/**
 * Slippage and deadline controls. A custom slippage applies once it parses; clearing the field returns to the
 * default preset (never to 0 %, which would make every trade revert on the smallest price move), and picking a
 * preset clears the field.
 */
export function SettingsPanel() {
  const { slippageBps, deadlineMinutes, setSlippageBps, setDeadlineMinutes } = useSettings()
  const [custom, setCustom] = useState('')

  return (
    <details className="settings">
      <summary data-testid="settings-toggle">
        Slippage {formatBps(slippageBps)} · deadline {deadlineMinutes} min
      </summary>
      <div className="settings-body">
        <label>
          Slippage tolerance
          <div className="row">
            {PRESETS.map((bps) => (
              <button
                key={bps.toString()}
                type="button"
                className={bps === slippageBps ? 'chip active' : 'chip'}
                data-testid={`slippage-preset-${bps}`}
                onClick={() => {
                  setSlippageBps(bps)
                  setCustom('')
                }}
              >
                {formatBps(bps)}
              </button>
            ))}
            <input
              data-testid="settings-slippage"
              inputMode="decimal"
              placeholder="custom %"
              value={custom}
              aria-invalid={custom.trim() !== '' && parseSlippagePercent(custom) === null}
              onChange={(event) => {
                const text = event.target.value
                setCustom(text)
                if (text.trim() === '') {
                  setSlippageBps(DEFAULT_SETTINGS.slippageBps)
                  return
                }
                const bps = parseSlippagePercent(text)
                if (bps !== null) setSlippageBps(bps)
              }}
            />
          </div>
        </label>
        <label>
          Deadline (minutes)
          <input
            data-testid="settings-deadline"
            inputMode="numeric"
            value={deadlineMinutes}
            onChange={(event) => {
              const minutes = Number.parseInt(event.target.value, 10)
              if (Number.isSafeInteger(minutes) && minutes > 0 && minutes <= 4320) setDeadlineMinutes(minutes)
            }}
          />
        </label>
      </div>
    </details>
  )
}
