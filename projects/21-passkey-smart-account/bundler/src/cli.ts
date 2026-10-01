// SPDX-License-Identifier: MIT
// bundler-lite command line entry point:
//   node src/cli.ts --rpc http://127.0.0.1:8545 --entry-point 0x... --bundler 0x... [--port 0]
// The bundler account must be unlocked on the node (anvil dev accounts are). No private key is read.
import { parseArgs } from 'node:util'
import { getAddress } from 'viem'

import { BundlerLite } from './bundler.ts'
import { artifacts } from './devnet/artifacts.ts'
import { clientsFor } from './devnet/deploy.ts'
import { startBundlerServer } from './server.ts'

const { values } = parseArgs({
  options: {
    rpc: { type: 'string' },
    'entry-point': { type: 'string' },
    bundler: { type: 'string' },
    port: { type: 'string', default: '0' },
    'chain-id': { type: 'string', default: '31337' },
  },
})

if (values.rpc === undefined || values['entry-point'] === undefined || values.bundler === undefined) {
  process.stderr.write('usage: node src/cli.ts --rpc <url> --entry-point <address> --bundler <unlocked address> [--port 0]\n')
  process.exit(2)
}

const { publicClient, walletClient } = clientsFor(values.rpc, Number(values['chain-id']))
const bundler = new BundlerLite({
  publicClient,
  walletClient,
  bundlerAccount: getAddress(values.bundler),
  entryPoint: getAddress(values['entry-point']),
  simulationsCode: artifacts.entryPointSimulations().deployedBytecode,
})
const server = await startBundlerServer(bundler, Number(values.port))
process.stdout.write(`bundler-lite listening on ${server.url}\n`)

const shutdown = (): void => {
  void server.close().finally(() => process.exit(0))
}
process.on('SIGINT', shutdown)
process.on('SIGTERM', shutdown)
