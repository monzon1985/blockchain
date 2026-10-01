// SPDX-License-Identifier: MIT
import { defineConfig, devices } from '@playwright/test'

// Ports are never hard-coded: e2e/global-setup.ts starts the devnet (scripts/e2e-chain.mjs) and `next start` on
// OS-assigned ports and exports the base URL as E2E_BASE_URL for the tests.
export default defineConfig({
  testDir: './e2e',
  timeout: 240_000,
  expect: { timeout: 60_000 },
  fullyParallel: false,
  workers: 1,
  retries: 0,
  forbidOnly: process.env['CI'] !== undefined,
  reporter: [['list']],
  globalSetup: './e2e/global-setup.ts',
  use: {
    headless: true,
    trace: 'retain-on-failure',
    actionTimeout: 60_000,
  },
  projects: [{ name: 'chromium', use: { ...devices['Desktop Chrome'] } }],
})
