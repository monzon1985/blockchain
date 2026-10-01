// SPDX-License-Identifier: MIT
import { defineConfig } from '@wagmi/cli'
import { foundry, react } from '@wagmi/cli/plugins'

// Typed ABIs and React hooks for the contracts in ../contracts, read from the Foundry build output.
// Regenerate with `npm run wagmi:generate` after `forge build`; CI fails if src/generated.ts is stale.
export default defineConfig({
  out: 'src/generated.ts',
  plugins: [
    foundry({
      project: '../contracts',
      forge: { build: false },
      include: ['AMMFactory.sol/**', 'AMMPair.sol/**', 'AMMRouter.sol/**'],
    }),
    react(),
  ],
})
