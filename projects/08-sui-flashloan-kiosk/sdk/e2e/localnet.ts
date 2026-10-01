// SPDX-License-Identifier: MIT
//
// Test harness for the localnet end-to-end suite: boots `sui start` on free
// ports, funds keypairs from its faucet, publishes Move packages and offers a
// few typed helpers on top of the gRPC client.

import { type ChildProcess, execFile, spawn } from 'node:child_process';
import { cp, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { createServer } from 'node:net';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { promisify } from 'node:util';
import { bcs } from '@mysten/sui/bcs';
import type { SuiClientTypes } from '@mysten/sui/client';
import { requestSuiFromFaucetV2 } from '@mysten/sui/faucet';
import { SuiGrpcClient } from '@mysten/sui/grpc';
import { Ed25519Keypair } from '@mysten/sui/keypairs/ed25519';
import { Transaction } from '@mysten/sui/transactions';
import { fromBase58, fromBase64, toHex } from '@mysten/sui/utils';
import { stopChild } from './stop-child.js';

const SUI_BIN = process.env['SUI_BIN'] ?? 'sui';
const run = promisify(execFile);
const sleep = (ms: number): Promise<void> => new Promise((resolve) => setTimeout(resolve, ms));

/** Binds port 0 on the loopback interface and returns the port the OS picked. */
async function freePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const server = createServer();
    server.once('error', reject);
    server.listen(0, '127.0.0.1', () => {
      const address = server.address();
      server.close(() => {
        if (address === null || typeof address === 'string') reject(new Error('no port'));
        else resolve(address.port);
      });
    });
  });
}

/** A running localnet and the clients pointed at it. */
export interface Localnet {
  client: SuiGrpcClient;
  rpcUrl: string;
  faucetUrl: string;
  /** Last lines printed by `sui start`, for failure diagnostics. */
  logTail(): string;
  stop(): Promise<void>;
}

/**
 * Starts `sui start --with-faucet --force-regenesis` on two free ports and
 * waits until both the fullnode and the faucet answer.
 */
export async function startLocalnet(): Promise<Localnet> {
  const rpcPort = await freePort();
  const faucetPort = await freePort();
  const child: ChildProcess = spawn(
    SUI_BIN,
    [
      'start',
      `--with-faucet=127.0.0.1:${faucetPort}`,
      '--force-regenesis',
      '--fullnode-rpc-port',
      String(rpcPort),
    ],
    { stdio: ['ignore', 'pipe', 'pipe'], env: { ...process.env, RUST_LOG: 'error' } },
  );
  const log: string[] = [];
  const keep = (chunk: Buffer): void => {
    log.push(...chunk.toString().split(/\r?\n/));
    if (log.length > 200) log.splice(0, log.length - 200);
  };
  child.stdout?.on('data', keep);
  child.stderr?.on('data', keep);
  // An object, not a `let`: TypeScript cannot see the callback write and would
  // narrow a plain boolean to `false` inside the polling loop below.
  const state = { exited: false };
  child.once('exit', () => (state.exited = true));

  const rpcUrl = `http://127.0.0.1:${rpcPort}`;
  const client = new SuiGrpcClient({ network: 'localnet', baseUrl: rpcUrl });
  const faucetUrl = `http://127.0.0.1:${faucetPort}`;
  const net: Localnet = {
    client,
    rpcUrl,
    faucetUrl,
    logTail: () => log.slice(-40).join('\n'),
    // SIGTERM, then a forced kill by PID if the node is still up after 10 s.
    stop: () => stopChild(child, 10_000),
  };

  const deadline = Date.now() + 240_000;
  for (;;) {
    if (state.exited) throw new Error(`sui start exited early:\n${net.logTail()}`);
    try {
      await client.getChainIdentifier();
      break;
    } catch {
      if (Date.now() > deadline) {
        await net.stop();
        throw new Error(`localnet did not come up:\n${net.logTail()}`);
      }
      await sleep(1_000);
    }
  }
  return net;
}

/** Funds `keypair` (a fresh one by default) from the faucet and waits for the coins. */
export async function fundedKeypair(net: Localnet, keypair = new Ed25519Keypair()): Promise<Ed25519Keypair> {
  const owner = keypair.toSuiAddress();
  for (let attempt = 0; ; attempt++) {
    try {
      const response = await requestSuiFromFaucetV2({ host: net.faucetUrl, recipient: owner });
      if (response.status === 'Success') break;
      throw new Error(JSON.stringify(response.status));
    } catch (error) {
      if (attempt >= 30) throw error;
      await sleep(1_000);
    }
  }
  for (let attempt = 0; attempt < 60; attempt++) {
    const { balance } = await net.client.getBalance({ owner });
    if (BigInt(balance.balance) > 0n) return keypair;
    await sleep(500);
  }
  throw new Error('faucet coins never arrived');
}

/** Include set used for every executed transaction in the suite. */
export const INCLUDE = { effects: true, events: true, objectTypes: true, balanceChanges: true } as const;
export type Executed = SuiClientTypes.Transaction<typeof INCLUDE>;

/** Signs and executes `tx`, waits for the fullnode to index it and returns it. */
export async function execute(net: Localnet, signer: Ed25519Keypair, tx: Transaction): Promise<Executed> {
  const result = await net.client.signAndExecuteTransaction({ transaction: tx, signer, include: INCLUDE });
  await net.client.waitForTransaction({ result });
  return result.$kind === 'Transaction' ? result.Transaction : result.FailedTransaction;
}

/**
 * Executes a transaction that is *expected to fail*, on chain.
 *
 * The SDK normally simulates a transaction while building it and throws on
 * failure, so a doomed PTB would never reach a validator. Here the inputs are
 * resolved through a kind-only build (whose simulation does not reject), and
 * sender, gas price, budget and payment are pinned by hand, so the fully
 * resolved transaction is signed and executed without a pre-flight. The chain
 * records the failure (gas is charged, every other effect is reverted).
 */
export async function executeUnchecked(
  net: Localnet,
  signer: Ed25519Keypair,
  tx: Transaction,
  gasBudget = 50_000_000n,
): Promise<Executed> {
  const sender = signer.toSuiAddress();
  tx.setSender(sender);
  const kind = await tx.build({ client: net.client, onlyTransactionKind: true });
  const forced = Transaction.fromKind(kind);
  forced.setSender(sender);
  forced.setGasBudget(gasBudget);
  forced.setGasPrice(BigInt((await net.client.getReferenceGasPrice()).referenceGasPrice));
  const { objects } = await net.client.listCoins({ owner: sender });
  const richest = objects.reduce((a, b) => (BigInt(a.balance) >= BigInt(b.balance) ? a : b));
  forced.setGasPayment([{ objectId: richest.objectId, version: richest.version, digest: richest.digest }]);
  return execute(net, signer, forced);
}

/** Like `execute`, but throws with the node's error unless the transaction succeeded. */
export async function executeOk(net: Localnet, signer: Ed25519Keypair, tx: Transaction): Promise<Executed> {
  const executed = await execute(net, signer, tx);
  if (!executed.status.success)
    throw new Error(`transaction failed: ${JSON.stringify(executed.status.error)}`);
  return executed;
}

/** Objects created by a transaction, as `{ id, type, owner }`. */
export function created(
  tx: Executed,
): { id: string; type: string; owner: SuiClientTypes.ObjectOwner | null }[] {
  return tx.effects.changedObjects
    .filter((o) => o.idOperation === 'Created')
    .map((o) => ({ id: o.objectId, type: tx.objectTypes[o.objectId] ?? 'package', owner: o.outputOwner }));
}

/** The single created object whose type matches `pattern`. */
export function createdOne(
  tx: Executed,
  pattern: RegExp,
): { id: string; initialSharedVersion: string | undefined } {
  const matches = created(tx).filter((o) => pattern.test(o.type));
  if (matches.length !== 1) throw new Error(`expected one ${pattern} but found ${matches.length}`);
  const [match] = matches as [(typeof matches)[number]];
  return { id: match.id, initialSharedVersion: match.owner?.Shared?.initialSharedVersion };
}

/** Id of the package published by `tx`. */
export function publishedPackage(tx: Executed): string {
  const pkg = tx.effects.changedObjects.find((o) => o.outputState === 'PackageWrite');
  if (pkg === undefined) throw new Error('no package in effects');
  return pkg.objectId;
}

/** Compiles the Move package at `path` and publishes it from `signer`. */
export async function publish(net: Localnet, signer: Ed25519Keypair, path: string): Promise<Executed> {
  const args = ['move', 'build', '--build-env', 'testnet', '--dump-bytecode-as-base64', '--path', path];
  const { stdout } = await run(SUI_BIN, args, {
    maxBuffer: 64 * 1024 * 1024,
  });
  const json = stdout.slice(stdout.indexOf('{'));
  const { modules, dependencies } = JSON.parse(json) as { modules: string[]; dependencies: string[] };
  const tx = new Transaction();
  const upgradeCap = tx.publish({ modules, dependencies });
  tx.transferObjects([upgradeCap], signer.toSuiAddress());
  return executeOk(net, signer, tx);
}

/**
 * Runs read-only Move calls through `simulateTransaction` and returns the BCS
 * return values of the last command.
 */
export async function view(
  net: Localnet,
  sender: string,
  build: (tx: Transaction) => void,
): Promise<Uint8Array[]> {
  const tx = new Transaction();
  tx.setSender(sender);
  build(tx);
  const result = await net.client.simulateTransaction({ transaction: tx, include: { commandResults: true } });
  if (result.$kind !== 'Transaction') {
    throw new Error(`view failed: ${JSON.stringify(result.FailedTransaction.status)}`);
  }
  const last = result.commandResults.at(-1);
  if (last === undefined) throw new Error('view returned nothing');
  return last.returnValues.map((v) => v.bcs);
}

/** Decodes a BCS u64. */
export const u64 = (bytes: Uint8Array | undefined): bigint =>
  BigInt(bcs.u64().parse(bytes ?? new Uint8Array()));
/** Decodes a BCS bool. */
export const bool = (bytes: Uint8Array | undefined): boolean => bcs.bool().parse(bytes ?? new Uint8Array());

/** Net SUI balance change of `address` in `tx` (includes gas). */
export function suiDelta(tx: Executed, address: string): bigint {
  return tx.balanceChanges
    .filter((c) => c.address === address && c.coinType.endsWith('::sui::SUI'))
    .reduce((sum, c) => sum + BigInt(c.amount), 0n);
}

/** Net balance change of `coinType` for `address` in `tx`. */
export function coinDelta(tx: Executed, address: string, coinType: string): bigint {
  return tx.balanceChanges
    .filter((c) => c.address === address && c.coinType === coinType)
    .reduce((sum, c) => sum + BigInt(c.amount), 0n);
}

/** Total gas paid by the sender of `tx`. */
export function gasPaid(tx: Executed): bigint {
  const g = tx.effects.gasUsed;
  return BigInt(g.computationCost) + BigInt(g.storageCost) - BigInt(g.storageRebate);
}

/**
 * A throw-away Sui CLI configuration pointed at the localnet. Its key is also
 * loaded into the SDK, so objects published with the SDK (e.g. the
 * `UpgradeCap`) can later be driven by CLI commands such as `test-upgrade`.
 */
export interface SuiCli {
  dir: string;
  keypair: Ed25519Keypair;
  run(args: string[]): Promise<string>;
  dispose(): Promise<void>;
}

export async function cliForLocalnet(net: Localnet): Promise<SuiCli> {
  const dir = await mkdtemp(join(tmpdir(), 'flash-kiosk-e2e-'));
  const config = join(dir, 'client.yaml');
  const cli = async (args: string[]): Promise<string> => {
    const { stdout } = await run(SUI_BIN, ['client', '--client.config', config, ...args], {
      maxBuffer: 64 * 1024 * 1024,
    });
    return stdout;
  };
  await cli(['-y', 'envs']); // creates the config and one ed25519 key
  await cli(['new-env', '--alias', 'e2e', '--rpc', net.rpcUrl]);
  await cli(['switch', '--env', 'e2e']);
  const keystore = JSON.parse(await readFile(join(dir, 'sui.keystore'), 'utf8')) as string[];
  const raw = fromBase64(keystore[0] ?? '');
  if (raw[0] !== 0 || raw.length !== 33) throw new Error('expected one ed25519 key in the CLI keystore');
  const keypair = Ed25519Keypair.fromSecretKey(raw.slice(1));
  const active = (await cli(['active-address'])).trim();
  if (active !== keypair.toSuiAddress()) throw new Error(`CLI address ${active} != SDK address`);
  return { dir, keypair, run: cli, dispose: () => rm(dir, { recursive: true, force: true }) };
}

/**
 * Upgrades `packageId` with the sources in `sourceDir` through
 * `sui client test-upgrade`, which needs an ephemeral publication file
 * (Pub.<env>.toml) describing the original publication. Returns the id of the
 * new package version.
 */
export async function upgradeWithCli(
  net: Localnet,
  cli: SuiCli,
  params: { sourceDir: string; packageId: string; upgradeCap: string },
): Promise<string> {
  const { chainIdentifier } = await net.client.getChainIdentifier();
  const chainId = toHex(fromBase58(chainIdentifier).slice(0, 4));
  const { stdout: version } = await run(SUI_BIN, ['--version']);
  const toolchain = /sui (\d+\.\d+\.\d+)/.exec(version)?.[1] ?? 'unknown';
  const pubfile = join(cli.dir, 'Pub.e2e.toml');
  await writeFile(
    pubfile,
    [
      'build-env = "testnet"',
      `chain-id = "${chainId}"`,
      '',
      '[[published]]',
      `source = { local = '${params.sourceDir.replaceAll('\\', '/')}' }`,
      `published-at = "${params.packageId}"`,
      `original-id = "${params.packageId}"`,
      'version = 1',
      `toolchain-version = "${toolchain}"`,
      'build-config = { flavor = "sui", edition = "2024" }',
      `upgrade-capability = "${params.upgradeCap}"`,
      '',
    ].join('\n'),
  );
  const stdout = await cli.run([
    'test-upgrade',
    '--build-env',
    'testnet',
    '--pubfile-path',
    pubfile,
    '--upgrade-capability',
    params.upgradeCap,
    '--json',
    params.sourceDir,
  ]);
  const result = JSON.parse(stdout.slice(stdout.indexOf('{'))) as {
    digest: string;
    effects: { status: { status: string } };
    objectChanges: { type: string; packageId?: string }[];
  };
  if (result.effects.status.status !== 'success') throw new Error(`upgrade failed: ${stdout}`);
  await net.client.waitForTransaction({ digest: result.digest });
  const published = result.objectChanges.find((c) => c.type === 'published')?.packageId;
  if (published === undefined) throw new Error('upgrade published no package');
  return published;
}

/**
 * Copies the Move package at `root` into a scratch directory, applying
 * `edit` to one source file (e.g. bumping VERSION for an upgrade).
 */
export async function copyPackage(
  root: string,
  into: string,
  file: string,
  edit: (source: string) => string,
): Promise<string> {
  const target = join(into, 'package-v2');
  for (const entry of ['Move.toml', 'Move.lock', 'sources']) {
    await cp(join(root, entry), join(target, entry), { recursive: true });
  }
  const path = join(target, 'sources', file);
  const before = await readFile(path, 'utf8');
  const after = edit(before);
  if (after === before) throw new Error(`edit did not change ${file}`);
  await writeFile(path, after);
  return target;
}
