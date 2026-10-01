// SPDX-License-Identifier: MIT
import { execFileSync } from 'node:child_process'

import { defineConfig, devices } from '@playwright/test'

// Ports are never hard-coded. The config is evaluated by the runner and again by every worker, so the port is chosen
// once (asking the OS for a free one) and handed to the workers and the webServer through the environment.
if (!process.env['E2E_PORT']) {
  process.env['E2E_PORT'] = execFileSync(process.execPath, [
    '-e',
    "const s=require('net').createServer();s.listen(0,'127.0.0.1',()=>{process.stdout.write(String(s.address().port));s.close()})",
  ]).toString()
}
const baseURL = `http://127.0.0.1:${process.env['E2E_PORT']}`

export default defineConfig({
  testDir: './e2e',
  // One shared chain: specs reset it to a baseline snapshot, so they run serially in one worker.
  workers: 1,
  fullyParallel: false,
  retries: 0,
  timeout: 120_000,
  expect: { timeout: 30_000 },
  forbidOnly: !!process.env['CI'],
  reporter: [['list']],
  use: {
    baseURL,
    headless: true,
    trace: 'retain-on-failure',
    actionTimeout: 30_000,
  },
  // scripts/e2e-chain.mjs: fresh anvil on a free port -> forge deploy -> `next build` (skipped with E2E_SKIP_BUILD=1,
  // which reuses an existing production build) -> `next start` on E2E_PORT.
  webServer: {
    command: 'node scripts/e2e-chain.mjs',
    url: `${baseURL}/api/health`,
    timeout: 900_000,
    reuseExistingServer: false,
    stdout: 'pipe',
    stderr: 'pipe',
    env: { E2E_PORT: process.env['E2E_PORT'], E2E_SKIP_BUILD: process.env['E2E_SKIP_BUILD'] ?? '' },
  },
  projects: [{ name: 'chromium', use: { ...devices['Desktop Chrome'] } }],
})
