// SPDX-License-Identifier: MIT
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import path from 'node:path'
import type { Abi, Hex } from 'viem'

/** A Foundry build artifact reduced to what deployment and simulation need. */
export interface Artifact {
  readonly abi: Abi
  readonly bytecode: Hex
  readonly deployedBytecode: Hex
}

interface FoundryArtifactJson {
  abi: Abi
  bytecode: { object: Hex }
  deployedBytecode: { object: Hex }
}

/** Directory of `forge build` output. Override with `CONTRACTS_OUT`. */
export function contractsOutDir(): string {
  const fromEnv = process.env['CONTRACTS_OUT']
  if (fromEnv !== undefined && fromEnv !== '') return fromEnv
  const here = path.dirname(fileURLToPath(import.meta.url))
  return path.resolve(here, '../../../contracts/out')
}

/** Loads `<out>/<file>/<contract>.json`, e.g. `loadArtifact('PasskeyAccount.sol', 'PasskeyAccount')`. */
export function loadArtifact(file: string, contract: string): Artifact {
  const location = path.join(contractsOutDir(), file, `${contract}.json`)
  let json: FoundryArtifactJson
  try {
    json = JSON.parse(readFileSync(location, 'utf8')) as FoundryArtifactJson
  } catch (cause) {
    throw new Error(`Missing Foundry artifact ${location}. Run \`forge build\` in contracts/ first.`, { cause })
  }
  return { abi: json.abi, bytecode: json.bytecode.object, deployedBytecode: json.deployedBytecode.object }
}

export const artifacts = {
  entryPoint: () => loadArtifact('EntryPoint.sol', 'EntryPoint'),
  entryPointSimulations: () => loadArtifact('EntryPointSimulations.sol', 'EntryPointSimulations'),
  factory: () => loadArtifact('PasskeyAccountFactory.sol', 'PasskeyAccountFactory'),
  account: () => loadArtifact('PasskeyAccount.sol', 'PasskeyAccount'),
  testUsd: () => loadArtifact('TestUSD.sol', 'TestUSD'),
  paymaster: () => loadArtifact('TokenPaymaster.sol', 'TokenPaymaster'),
} as const
