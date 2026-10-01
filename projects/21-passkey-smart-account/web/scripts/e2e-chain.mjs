// SPDX-License-Identifier: MIT
// Local devnet for the wallet: anvil (osaka, so the EIP-7951 P-256 precompile exists) on a random port, EntryPoint
// v0.9 + PasskeyAccountFactory + TestUSD + TokenPaymaster, a demo sweeper for the 7702 target check, and
// bundler-lite on a random port. Prints one `E2E_CHAIN_READY {json}` line, then runs until terminated.
//
// Requires `forge build` in ../contracts (artifacts) and `npm ci` in ../bundler (viem for the shared modules).
import { BundlerLite } from '../../bundler/src/bundler.ts'
import { startAnvil } from '../../bundler/src/devnet/anvil.ts'
import { artifacts, loadArtifact } from '../../bundler/src/devnet/artifacts.ts'
import { clientsFor, deployLocalStack } from '../../bundler/src/devnet/deploy.ts'
import { startBundlerServer } from '../../bundler/src/server.ts'

const anvil = await startAnvil()
let server

async function shutdown(code) {
  try {
    await server?.close()
  } finally {
    await anvil.stop()
    process.exit(code)
  }
}
process.on('SIGINT', () => void shutdown(0))
process.on('SIGTERM', () => void shutdown(0))

try {
  const deployment = await deployLocalStack(anvil.rpcUrl)
  const { publicClient, walletClient } = clientsFor(anvil.rpcUrl)

  // A known-bad delegation target, deployed only so the wallet can show its pre-signing check refusing it.
  const sweeper = loadArtifact('ClassifierCorpus.sol', 'SweeperReceiveForward')
  const hash = await walletClient.deployContract({
    abi: sweeper.abi,
    bytecode: sweeper.bytecode,
    account: deployment.admin,
    chain: walletClient.chain,
  })
  const receipt = await publicClient.waitForTransactionReceipt({ hash })

  const bundler = new BundlerLite({
    publicClient,
    walletClient,
    bundlerAccount: deployment.bundler,
    entryPoint: deployment.entryPoint,
    simulationsCode: artifacts.entryPointSimulations().deployedBytecode,
  })
  server = await startBundlerServer(bundler, 0)

  const info = {
    rpcUrl: anvil.rpcUrl,
    bundlerUrl: server.url,
    deployment: { ...deployment, demoSweeper: receipt.contractAddress },
  }
  process.stdout.write(`E2E_CHAIN_READY ${JSON.stringify(info)}\n`)
} catch (error) {
  process.stderr.write(`e2e-chain failed: ${error instanceof Error ? error.stack : String(error)}\n`)
  await shutdown(1)
}
