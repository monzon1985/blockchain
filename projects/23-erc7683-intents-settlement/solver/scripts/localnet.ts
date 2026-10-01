// SPDX-License-Identifier: MIT
// Two local anvil chains (origin 1001, destination 1002) with the full system deployed from the Foundry artifacts.
// Used by the e2e suite and by capture-proofs. Every key is generated at runtime; nothing secret is stored.
import { type ChildProcess, spawn } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import {
  type Abi,
  type Address,
  type Hex,
  createTestClient,
  encodeFunctionData,
  http,
  parseEther,
  toFunctionSelector,
} from "viem";
import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";

import { type ChainClients, type Wallet, clientsFor, walletFor } from "../src/chains.ts";
import type { Deployment } from "../src/config.ts";
import { sendAndWait } from "../src/tx.ts";

const here = dirname(fileURLToPath(import.meta.url));
const OUT = join(here, "..", "..", "out");

export const ORIGIN_CHAIN_ID = 1001;
export const DEST_CHAIN_ID = 1002;
export const HEADER_RELAYER_ROLE = 1n;
export const MAILBOX_RELAYER_ROLE = 2n;

export interface Anvil {
  process: ChildProcess;
  rpcUrl: string;
  chainId: number;
}

/** Starts anvil on an OS-assigned port (--port 0) and resolves once it prints the port it bound. */
export function startAnvil(chainId: number): Promise<Anvil> {
  return new Promise((resolve, reject) => {
    const child = spawn("anvil", ["--port", "0", "--chain-id", String(chainId)], {
      stdio: ["ignore", "pipe", "pipe"],
    });
    let output = "";
    const timer = setTimeout(() => {
      child.kill();
      reject(new Error(`anvil ${chainId} did not start: ${output}`));
    }, 30_000);
    child.stdout.on("data", (chunk: Buffer) => {
      output += chunk.toString();
      const match = /Listening on ([\d.]+):(\d+)/.exec(output);
      if (match !== null) {
        clearTimeout(timer);
        resolve({ process: child, rpcUrl: `http://${match[1] ?? "127.0.0.1"}:${match[2] ?? ""}`, chainId });
      }
    });
    child.on("error", (error) => {
      clearTimeout(timer);
      reject(error);
    });
  });
}

/** Stops an anvil we started, by its PID only. */
export function stopAnvil(anvil: Anvil): void {
  if (anvil.process.exitCode === null) anvil.process.kill();
}

interface Artifact {
  abi: Abi;
  bytecode: { object: Hex };
}

export function artifact(file: string, contract: string): Artifact {
  return JSON.parse(readFileSync(join(OUT, file, `${contract}.json`), "utf8")) as Artifact;
}

export interface Actor {
  key: Hex;
  address: Address;
}

export function newActor(): Actor {
  const key = generatePrivateKey();
  return { key, address: privateKeyToAccount(key).address };
}

export interface Localnet {
  originAnvil: Anvil;
  destAnvil: Anvil;
  origin: ChainClients;
  dest: ChainClients;
  deployment: Deployment;
  adapter: Address;
  inputToken: Address;
  outputToken: Address;
  admin: Actor;
  relayer: Actor;
  refundGrace: bigint;
  challengeWindow: bigint;
  bond: bigint;
  stop: () => void;
}

export interface LocalnetOptions {
  refundGrace?: bigint;
  challengeWindow?: bigint;
  bond?: bigint;
}

async function deploy(clients: ChainClients, wallet: Wallet, file: string, contract: string, args: unknown[] = []) {
  const { abi, bytecode } = artifact(file, contract);
  const hash = await wallet.deployContract({ abi, bytecode: bytecode.object, args });
  const receipt = await clients.public.waitForTransactionReceipt({ hash });
  if (receipt.contractAddress === null || receipt.contractAddress === undefined) {
    throw new Error(`deployment of ${contract} failed`);
  }
  return receipt.contractAddress;
}

async function call(clients: ChainClients, wallet: Wallet, to: Address, abi: Abi, functionName: string, args: unknown[]) {
  await sendAndWait(clients, wallet, { to, data: encodeFunctionData({ abi, functionName, args }) });
}

/** Funds `addresses` with 1000 ETH on both chains (anvil_setBalance). */
export async function fund(net: Pick<Localnet, "originAnvil" | "destAnvil">, addresses: Address[]): Promise<void> {
  for (const anvil of [net.originAnvil, net.destAnvil]) {
    const test = createTestClient({ mode: "anvil", transport: http(anvil.rpcUrl) });
    for (const address of addresses) await test.setBalance({ address, value: parseEther("1000") });
  }
}

/** Moves both chains' clocks forward by `seconds` and mines a block on each. */
export async function advanceTime(net: Pick<Localnet, "originAnvil" | "destAnvil">, seconds: bigint): Promise<void> {
  for (const anvil of [net.originAnvil, net.destAnvil]) {
    const test = createTestClient({ mode: "anvil", transport: http(anvil.rpcUrl) });
    await test.increaseTime({ seconds: Number(seconds) });
    await test.mine({ blocks: 1 });
  }
}

/** Mines one block on the destination chain (so a header newer than some timestamp exists). */
export async function mineDest(net: Pick<Localnet, "destAnvil">, afterSeconds = 1n): Promise<void> {
  const test = createTestClient({ mode: "anvil", transport: http(net.destAnvil.rpcUrl) });
  await test.increaseTime({ seconds: Number(afterSeconds) });
  await test.mine({ blocks: 1 });
}

export async function startLocalnet(options: LocalnetOptions = {}): Promise<Localnet> {
  const refundGrace = options.refundGrace ?? 600n;
  const challengeWindow = options.challengeWindow ?? 300n;
  const bond = options.bond ?? parseEther("50");
  const [originAnvil, destAnvil] = await Promise.all([startAnvil(ORIGIN_CHAIN_ID), startAnvil(DEST_CHAIN_ID)]);
  const stop = (): void => {
    stopAnvil(originAnvil);
    stopAnvil(destAnvil);
  };
  try {
    const origin = clientsFor(ORIGIN_CHAIN_ID, originAnvil.rpcUrl);
    const dest = clientsFor(DEST_CHAIN_ID, destAnvil.rpcUrl);
    const admin = newActor();
    const relayer = newActor();
    await fund({ originAnvil, destAnvil }, [admin.address, relayer.address]);
    const ow = walletFor(origin, admin.key);
    const dw = walletFor(dest, admin.key);

    // Destination chain.
    const destManager = await deploy(dest, dw, "AccessManager.sol", "AccessManager", [admin.address]);
    const destinationSettler = await deploy(dest, dw, "DestinationSettler.sol", "DestinationSettler");
    const destMailbox = await deploy(dest, dw, "MockMailbox.sol", "MockMailbox", [destManager]);
    const reporter = await deploy(dest, dw, "MailboxFillReporter.sol", "MailboxFillReporter", [
      destinationSettler,
      destMailbox,
      destManager,
    ]);
    const outputToken = await deploy(dest, dw, "TestTokens.sol", "MockERC20", ["Output", "OUT"]);

    // Origin chain.
    const originManager = await deploy(origin, ow, "AccessManager.sol", "AccessManager", [admin.address]);
    const permit2 = await deploy(origin, ow, "Permit2.sol", "Permit2");
    const originSettler = await deploy(origin, ow, "OriginSettler.sol", "OriginSettler", [
      permit2,
      refundGrace,
      originManager,
    ]);
    const originMailbox = await deploy(origin, ow, "MockMailbox.sol", "MockMailbox", [originManager]);
    const mailboxModule = await deploy(origin, ow, "MailboxSettlementModule.sol", "MailboxSettlementModule", [
      originSettler,
      originMailbox,
      originManager,
    ]);
    const headerStore = await deploy(origin, ow, "HeaderStore.sol", "HeaderStore", [originManager]);
    const bondToken = await deploy(origin, ow, "TestTokens.sol", "MockERC20", ["Bond", "BOND"]);
    const optimisticModule = await deploy(origin, ow, "OptimisticSettlementModule.sol", "OptimisticSettlementModule", [
      originSettler,
      headerStore,
      bondToken,
      bond,
      challengeWindow,
      originManager,
    ]);
    const proofModule = await deploy(origin, ow, "StorageProofSettlementModule.sol", "StorageProofSettlementModule", [
      originSettler,
      headerStore,
      originManager,
    ]);
    const inputToken = await deploy(origin, ow, "TestTokens.sol", "MockERC20", ["Input", "IN"]);
    const adapter = await deploy(origin, ow, "ERC7683ResolverAdapter.sol", "ERC7683ResolverAdapter", [
      originSettler,
      mailboxModule,
      optimisticModule,
      proofModule,
      300n,
      60n,
    ]);

    // Wiring: roles, routes, registries.
    const manager = artifact("AccessManager.sol", "AccessManager").abi;
    const submitHeader = toFunctionSelector("submitHeader(uint256,bytes)");
    const process_ = toFunctionSelector("process(bytes)");
    await call(origin, ow, originManager, manager, "setTargetFunctionRole", [headerStore, [submitHeader], HEADER_RELAYER_ROLE]);
    await call(origin, ow, originManager, manager, "grantRole", [HEADER_RELAYER_ROLE, relayer.address, 0]);
    await call(origin, ow, originManager, manager, "setTargetFunctionRole", [originMailbox, [process_], MAILBOX_RELAYER_ROLE]);
    await call(origin, ow, originManager, manager, "grantRole", [MAILBOX_RELAYER_ROLE, relayer.address, 0]);
    const mm = artifact("MailboxSettlementModule.sol", "MailboxSettlementModule").abi;
    await call(origin, ow, mailboxModule, mm, "setRoute", [BigInt(DEST_CHAIN_ID), reporter, destinationSettler]);
    const reg = artifact("OptimisticSettlementModule.sol", "OptimisticSettlementModule").abi;
    await call(origin, ow, optimisticModule, reg, "setDestinationSettler", [BigInt(DEST_CHAIN_ID), destinationSettler]);
    await call(origin, ow, proofModule, reg, "setDestinationSettler", [BigInt(DEST_CHAIN_ID), destinationSettler]);
    const os = artifact("OriginSettler.sol", "OriginSettler").abi;
    for (const module of [mailboxModule, optimisticModule, proofModule]) {
      await call(origin, ow, originSettler, os, "setSettlementModule", [module, true]);
    }
    const rep = artifact("MailboxFillReporter.sol", "MailboxFillReporter").abi;
    await call(dest, dw, reporter, rep, "setOriginModule", [BigInt(ORIGIN_CHAIN_ID), mailboxModule]);

    const deployment: Deployment = {
      origin: {
        chainId: ORIGIN_CHAIN_ID,
        rpcUrl: originAnvil.rpcUrl,
        originSettler,
        permit2,
        headerStore,
        mailbox: originMailbox,
        mailboxModule,
        optimisticModule,
        proofModule,
        bondToken,
      },
      destination: {
        chainId: DEST_CHAIN_ID,
        rpcUrl: destAnvil.rpcUrl,
        destinationSettler,
        mailbox: destMailbox,
        reporter,
      },
    };
    return {
      originAnvil,
      destAnvil,
      origin,
      dest,
      deployment,
      adapter,
      inputToken,
      outputToken,
      admin,
      relayer,
      refundGrace,
      challengeWindow,
      bond,
      stop,
    };
  } catch (error) {
    stop();
    throw error;
  }
}
