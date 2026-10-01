// SPDX-License-Identifier: MIT
// End-to-end: real WebAuthn ceremonies in headless Chromium through a CDP virtual authenticator (CTAP2, internal
// transport, resident keys, user verification), against anvil (osaka) + EntryPoint v0.9 + bundler-lite.
import { expect, test, type Page } from '@playwright/test'

function baseUrl(): string {
  const url = process.env['E2E_BASE_URL']
  if (url === undefined) throw new Error('E2E_BASE_URL not set: run through playwright.config.ts')
  return url
}

/** Direct JSON-RPC to the devnet node, to check chain state independently of the wallet UI. */
async function nodeRpc<T>(method: string, params: unknown[] = []): Promise<T> {
  const url = process.env['E2E_RPC_URL']
  if (url === undefined) throw new Error('E2E_RPC_URL not set: run through playwright.config.ts')
  const response = await fetch(url, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }),
  })
  const body = (await response.json()) as { result?: T; error?: { message: string } }
  if (body.error !== undefined) throw new Error(`${method}: ${body.error.message}`)
  return body.result as T
}

async function withVirtualAuthenticator(page: Page): Promise<string> {
  const cdp = await page.context().newCDPSession(page)
  await cdp.send('WebAuthn.enable')
  const { authenticatorId } = await cdp.send('WebAuthn.addVirtualAuthenticator', {
    options: {
      protocol: 'ctap2',
      transport: 'internal',
      hasResidentKey: true,
      hasUserVerification: true,
      isUserVerified: true,
      automaticPresenceSimulation: true,
    },
  })
  return authenticatorId
}

/** Clicks an action button and waits for its activity entry to settle; returns the entry text. */
async function act(page: Page, testId: string, label: string, expected: 'ok' | 'failed' = 'ok'): Promise<string> {
  await page.getByTestId(testId).click()
  const entry = page.getByTestId('activity').locator('li', { hasText: label }).first()
  await expect(entry).toHaveAttribute('data-status', /ok|failed/, { timeout: 120_000 })
  const text = (await entry.textContent()) ?? ''
  expect(await entry.getAttribute('data-status'), text).toBe(expected)
  return text
}

test('passkey account: gasless deploy, ERC-20-paid batch, guardians, veto and timelocked recovery', async ({ page }) => {
  await withVirtualAuthenticator(page)
  await page.goto(baseUrl())

  await act(page, 'create-passkey', 'Create passkey')
  await expect(page.getByTestId('account-status')).toHaveText('counterfactual')

  await act(page, 'faucet-account', 'Faucet: 100 TUSD')
  await expect(page.getByTestId('account-balance')).toHaveText('100 TUSD')

  // First operation: CREATE2 deployment + paymaster approval; the sponsor fronts the gas, the account repays in TUSD.
  await act(page, 'deploy-account', 'Deploy account (guaranteed first op)')
  await expect(page.getByTestId('account-status')).toHaveText('deployed')

  const batch = await act(page, 'send-batch', 'Paymaster batch transfer (gas in TUSD)')
  expect(batch).toContain('success')
  expect(batch).toMatch(/gas paid \d+(\.\d+)? TUSD/)

  await act(page, 'add-guardians', 'Add guardians (2-of-3)')
  await expect(page.getByTestId('guardian-count')).toHaveText('3 (threshold 2)')

  // Lost device scenario: a new passkey, approved by two guardians.
  await act(page, 'create-recovery-passkey', 'Create replacement passkey')
  await act(page, 'guardian-approve-0', 'Guardian 1 approves recovery')
  await expect(page.getByTestId('recovery-status')).toHaveText('none')
  await act(page, 'guardian-approve-1', 'Guardian 2 approves recovery')
  await expect(page.getByTestId('recovery-status')).toContainText('scheduled')

  // The owner (still holding the original passkey) vetoes.
  await act(page, 'veto-recovery', 'Owner veto (cancel recovery)')
  await expect(page.getByTestId('recovery-status')).toHaveText('none')

  // Guardians try again; the 48 h timelock is enforced on chain.
  await act(page, 'guardian-approve-0', 'Guardian 1 approves recovery')
  await act(page, 'guardian-approve-1', 'Guardian 2 approves recovery')
  await expect(page.getByTestId('recovery-status')).toContainText('scheduled')
  const early = await act(page, 'execute-recovery', 'Execute recovery', 'failed')
  expect(early).toMatch(/revert/i)

  await act(page, 'time-travel', 'Fast-forward 48 h (devnet clock)')
  await act(page, 'execute-recovery', 'Execute recovery')
  await expect(page.getByTestId('recovery-status')).toHaveText('none')
  await expect(page.getByTestId('active-passkey')).toHaveText('recovery-2')
  const replacement = await page.getByTestId('passkey-replacement').textContent()
  await expect(page.getByTestId('onchain-passkey')).toHaveText(replacement ?? '')

  // The replacement passkey now controls the same account.
  const afterRecovery = await act(page, 'send-batch', 'Paymaster batch transfer (gas in TUSD)')
  expect(afterRecovery).toContain('success')
})

test('EIP-7702: the classifier refuses a sweeper target, then a gas-less EOA upgrades itself', async ({ page }) => {
  await withVirtualAuthenticator(page)
  await page.goto(baseUrl())

  await act(page, 'create-passkey', 'Create passkey')
  await act(page, 'create-eoa', 'Create demo EOA')
  await expect(page.getByTestId('eoa-status')).toHaveText('plain EOA')

  await act(page, 'check-sweeper', 'Check demo sweeper as delegation target')
  await expect(page.getByTestId('sweeper-verdict')).toHaveText('malicious · refused')

  // The refusal on the real signing path: the upgrade is attempted with the sweeper as delegation target. The policy
  // runs before the EOA key signs, so no authorization exists and nothing, type-4 transaction included, is sent.
  const eoaAddress = (await page.getByTestId('eoa-address').textContent()) ?? ''
  expect(eoaAddress).toMatch(/^0x[0-9a-fA-F]{40}$/)
  const blockBefore = await nodeRpc<string>('eth_blockNumber')
  const refused = await act(page, 'upgrade-eoa-sweeper', 'Upgrade EOA to the demo sweeper (dev check)', 'failed')
  expect(refused).toContain('authorization refused')
  expect(refused).toContain('looks like a sweeper')
  expect(await nodeRpc<string>('eth_getCode', [eoaAddress, 'latest'])).toBe('0x')
  expect(await nodeRpc<string>('eth_getTransactionCount', [eoaAddress, 'latest'])).toBe('0x0')
  expect(await nodeRpc<string>('eth_blockNumber')).toBe(blockBefore)
  await expect(page.getByTestId('eoa-status')).toHaveText('plain EOA')

  await act(page, 'check-target', 'Check delegation target')
  await expect(page.getByTestId('target-verdict')).toHaveText('safe · allowed')

  await act(page, 'faucet-eoa', 'Faucet: 100 TUSD')
  await expect(page.getByTestId('eoa-balance')).toHaveText('100 TUSD')

  const upgrade = await act(page, 'upgrade-eoa', 'Upgrade EOA with EIP-7702')
  expect(upgrade).toContain('success')
  await expect(page.getByTestId('eoa-status')).toHaveText('delegated to PasskeyAccount, initialized')
})
