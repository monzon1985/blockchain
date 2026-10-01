// @vitest-environment jsdom
// SPDX-License-Identifier: MIT
// The slippage settings panel: a cleared custom field must never become a 0 % tolerance.
import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, describe, expect, it } from 'vitest'

import { DEFAULT_SETTINGS, SettingsPanel, SettingsProvider, useSettings } from '@/components/Settings'

function SlippageProbe() {
  const { slippageBps } = useSettings()
  return <output data-testid="slippage-bps">{slippageBps.toString()}</output>
}

function setup() {
  render(
    <SettingsProvider>
      <SettingsPanel />
      <SlippageProbe />
    </SettingsProvider>,
  )
  const input = screen.getByTestId('settings-slippage') as HTMLInputElement
  const bps = () => screen.getByTestId('slippage-bps').textContent
  const type = (value: string) => fireEvent.change(input, { target: { value } })
  return { input, bps, type }
}

afterEach(() => cleanup())

describe('SettingsPanel: custom slippage', () => {
  it('applies a typed percentage and returns to the default preset when the field is cleared', () => {
    const { bps, type } = setup()
    expect(bps()).toBe(DEFAULT_SETTINGS.slippageBps.toString())
    type('2')
    expect(bps()).toBe('200')
    type('') // Number('') === 0 used to set a zero-tolerance slippage here
    expect(bps()).toBe(DEFAULT_SETTINGS.slippageBps.toString())
    type('1.5')
    expect(bps()).toBe('150')
    type('   ')
    expect(bps()).toBe(DEFAULT_SETTINGS.slippageBps.toString())
  })

  it('accepts an explicit 0 and ignores input it cannot parse', () => {
    const { input, bps, type } = setup()
    type('0')
    expect(bps()).toBe('0')
    for (const invalid of ['60', '0x10', '1e1', '-1', '0.125']) {
      type(invalid)
      expect(bps()).toBe('0') // unchanged
      expect(input.getAttribute('aria-invalid')).toBe('true')
    }
    type('0.3')
    expect(bps()).toBe('30')
    expect(input.getAttribute('aria-invalid')).toBe('false')
  })

  it('a preset chip applies its value and clears the custom field', () => {
    const { input, bps, type } = setup()
    type('3')
    expect(bps()).toBe('300')
    fireEvent.click(screen.getByTestId('slippage-preset-100'))
    expect(bps()).toBe('100')
    expect(input.value).toBe('')
  })
})
