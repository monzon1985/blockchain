// SPDX-License-Identifier: MIT
// A fake JSON-RPC node for unit tests of the off-chain actors. Real viem clients (public and wallet) talk to it
// through a `custom` transport, so the Solver, relayers and watchtower run unchanged; only the node is simulated.
// It keeps per-account nonces, a queue for future nonces, automines one block per executable transaction, and
// simulates the few protocol contracts the actors touch with small handlers. Faults can be injected: a black-hole
// mempool, broadcast failures, proof failures.
import {
  type Abi,
  type Address,
  type Chain,
  type Hex,
  createPublicClient,
  createWalletClient,
  custom,
  decodeFunctionData,
  defineChain,
  encodeAbiParameters,
  encodeEventTopics,
  encodeFunctionResult,
  keccak256,
  numberToHex,
  pad,
  parseTransaction,
  recoverTransactionAddress,
  toHex,
  zeroAddress,
  zeroHash,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";

import type { ChainClients, Wallet } from "../src/chains.ts";

/** Thrown by a contract handler: the call reverts with `data`. */
export class Revert extends Error {
  readonly data: Hex;
  constructor(data: Hex, reason = "reverted") {
    super(reason);
    this.data = data;
  }
}

/** A JSON-RPC error as a node returns it (viem reads `code`, `message` and `data`). */
export class RpcFault extends Error {
  readonly code: number;
  readonly data: Hex | undefined;
  constructor(code: number, message: string, data?: Hex) {
    super(message);
    this.code = code;
    this.data = data;
  }
}

/** A simulated contract: an ABI and a function dispatcher. Mutations are rolled back for eth_call. */
export interface FakeContract {
  abi: Abi;
  call(ctx: CallContext, functionName: string, args: readonly unknown[]): unknown;
  /** Deep copy of the contract's state (for eth_call / eth_estimateGas rollbacks). */
  snapshot(): unknown;
  restore(state: unknown): void;
}

/** What a handler sees about the call being executed. */
export interface CallContext {
  node: FakeNode;
  from: Address;
  /** Emits an event from `address` (only kept if the transaction succeeds). */
  emit(address: Address, abi: Abi, eventName: string, args: Record<string, unknown>): void;
}

interface RpcLog {
  address: Address;
  topics: Hex[];
  data: Hex;
  blockNumber: bigint;
  transactionHash: Hex;
  logIndex: number;
}

interface Receipt {
  hash: Hex;
  from: Address;
  to: Address | null;
  blockNumber: bigint;
  status: "0x1" | "0x0";
  logs: RpcLog[];
}

interface PooledTx {
  hash: Hex;
  raw: Hex;
  from: Address;
  nonce: number;
  to: Address | null;
  data: Hex;
}

type RpcRequest = { method: string; params?: unknown };

/** One simulated chain. */
export class FakeNode {
  readonly chainId: number;
  readonly chain: Chain;
  /** Timestamp of the latest block. */
  time: bigint;
  blockNumber = 0n;
  /** Seconds between two mined blocks. */
  blockTime = 1n;
  readonly contracts = new Map<string, FakeContract>();
  /** Accept every transaction but drop it silently (a mempool that loses transactions): nothing is mined. */
  blackHole = false;
  /** Number of upcoming eth_sendRawTransaction calls that fail with a connection error. */
  failBroadcasts = 0;
  /** Makes eth_sendRawTransaction fail with a connection error for the raw transactions it returns true for. */
  failWhen: (raw: Hex) => boolean = () => false;
  /** Called by eth_getProof; throw to make the proof unavailable (for example a pruned block). */
  proofHook: (address: Address, blockNumber: bigint) => void = () => undefined;
  /** Every raw transaction the node received, in order (including rejected and re-sent ones). */
  readonly received: Hex[] = [];

  private readonly nonces = new Map<string, number>();
  private readonly receipts = new Map<Hex, Receipt>();
  private readonly known = new Set<Hex>();
  private readonly queued = new Map<string, PooledTx[]>();
  private readonly logs: RpcLog[] = [];
  private readonly blockTimes = new Map<bigint, bigint>();

  constructor(chainId: number, genesisTime = 1_750_000_000n) {
    this.chainId = chainId;
    this.time = genesisTime;
    this.blockTimes.set(0n, genesisTime);
    this.chain = defineChain({
      id: chainId,
      name: `fake-${chainId.toString()}`,
      nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
      rpcUrls: { default: { http: ["http://fake.invalid"] } },
    });
  }

  /** Public client of this chain. */
  clients(): ChainClients {
    return {
      chain: this.chain,
      public: createPublicClient({
        chain: this.chain,
        transport: custom({ request: (r: RpcRequest) => this.request(r) }, { retryCount: 0 }),
        pollingInterval: 1,
        cacheTime: 0,
      }),
    };
  }

  /** Wallet client of `key` on this chain. */
  wallet(key: Hex): Wallet {
    return createWalletClient({
      account: privateKeyToAccount(key),
      chain: this.chain,
      transport: custom({ request: (r: RpcRequest) => this.request(r) }, { retryCount: 0 }),
    });
  }

  /** Registers a simulated contract at `address`. */
  deploy(address: Address, contract: FakeContract): void {
    this.contracts.set(address.toLowerCase(), contract);
  }

  /** Mines one empty block `seconds` after the previous one. */
  advance(seconds: bigint): void {
    this.time += seconds;
    this.mineBlock();
  }

  /** Next nonce of `address` as the chain sees it (mined transactions only). */
  nonceOf(address: Address): number {
    return this.nonces.get(address.toLowerCase()) ?? 0;
  }

  /** Receipt status of `hash`, if mined. */
  statusOf(hash: Hex): "success" | "reverted" | undefined {
    const receipt = this.receipts.get(hash);
    if (receipt === undefined) return undefined;
    return receipt.status === "0x1" ? "success" : "reverted";
  }

  /** Runs `body` as a direct state change outside any transaction (test setup), keeping its events. */
  setup(body: (ctx: CallContext) => void): void {
    const logs: RpcLog[] = [];
    this.mineBlock();
    body(this.context(zeroAddress, logs, zeroHash));
    this.logs.push(...logs);
  }

  // ----------------------------------------------------------------------------------------------------------------
  // JSON-RPC
  // ----------------------------------------------------------------------------------------------------------------

  async request({ method, params }: RpcRequest): Promise<unknown> {
    await Promise.resolve();
    const p = (params ?? []) as unknown[];
    switch (method) {
      case "eth_chainId":
        return numberToHex(this.chainId);
      case "eth_blockNumber":
        return numberToHex(this.blockNumber);
      case "eth_gasPrice":
      case "eth_maxPriorityFeePerGas":
        return "0x1";
      case "eth_getBlockByNumber":
        return this.block(p[0] as string);
      case "eth_getTransactionCount": {
        const address = (p[0] as string).toLowerCase();
        const mined = this.nonces.get(address) ?? 0;
        if (p[1] !== "pending") return numberToHex(mined);
        const queued = this.queued.get(address) ?? [];
        let pending = mined;
        while (queued.some((q) => q.nonce === pending)) pending++;
        return numberToHex(pending);
      }
      case "eth_estimateGas":
        this.dryRun(p[0] as { from?: Address; to: Address; data: Hex });
        return "0x30d40";
      case "eth_call":
        return this.dryRun(p[0] as { from?: Address; to: Address; data: Hex });
      case "eth_sendRawTransaction":
        return this.sendRaw(p[0] as Hex);
      case "eth_getTransactionReceipt":
        return this.formatReceipt(this.receipts.get(p[0] as Hex));
      case "eth_getTransactionByHash":
        return null;
      case "eth_getLogs":
        return this.getLogs(p[0] as { address?: string | string[]; topics?: (Hex | Hex[] | null)[]; fromBlock?: string; toBlock?: string });
      case "eth_getProof":
        return this.proof(p[0] as Address, p[1] as Hex[], p[2] as string);
      default:
        throw new RpcFault(-32601, `method ${method} not supported by the fake node`);
    }
  }

  private block(tag: string) {
    const number = tag === "latest" || tag === "pending" ? this.blockNumber : BigInt(tag);
    if (number > this.blockNumber) return null;
    return {
      number: numberToHex(number),
      hash: keccak256(toHex(`block-${this.chainId.toString()}-${number.toString()}`)),
      parentHash: zeroHash,
      timestamp: numberToHex(this.blockTimes.get(number) ?? this.time),
      baseFeePerGas: "0x1",
      gasLimit: "0x1c9c380",
      gasUsed: "0x0",
      miner: zeroAddress,
      extraData: "0x",
      difficulty: "0x0",
      logsBloom: `0x${"0".repeat(512)}`,
      transactions: [],
      uncles: [],
      nonce: "0x0000000000000000",
      mixHash: zeroHash,
      sha3Uncles: zeroHash,
      stateRoot: zeroHash,
      receiptsRoot: zeroHash,
      transactionsRoot: zeroHash,
      size: "0x0",
    };
  }

  private context(from: Address, logs: RpcLog[], hash: Hex): CallContext {
    return {
      node: this,
      from,
      emit: (address, abi, eventName, args) => {
        const topics = encodeEventTopics({ abi, eventName, args }) as Hex[];
        const event = abi.find((item) => item.type === "event" && item.name === eventName);
        if (event?.type !== "event") throw new Error(`no event ${eventName}`);
        const unindexed = event.inputs.filter((input) => input.indexed !== true);
        const data = encodeAbiParameters(unindexed, unindexed.map((input) => args[input.name ?? ""]));
        logs.push({ address, topics, data, blockNumber: this.blockNumber, transactionHash: hash, logIndex: logs.length });
      },
    };
  }

  private execute(from: Address, to: Address, data: Hex, logs: RpcLog[], hash: Hex): Hex {
    const contract = this.contracts.get(to.toLowerCase());
    if (contract === undefined) return "0x";
    const { functionName, args } = decodeFunctionData({ abi: contract.abi, data });
    const result = contract.call(this.context(from, logs, hash), functionName, args ?? []);
    return encodeFunctionResult({ abi: contract.abi, functionName, result });
  }

  private dryRun(call: { from?: Address; to: Address; data: Hex }): Hex {
    const saved = [...this.contracts.entries()].map(([address, c]) => [address, c.snapshot()] as const);
    try {
      return this.execute(call.from ?? zeroAddress, call.to, call.data, [], zeroHash);
    } catch (error) {
      if (error instanceof Revert) throw new RpcFault(3, "execution reverted", error.data);
      throw error;
    } finally {
      for (const [address, state] of saved) this.contracts.get(address)?.restore(state);
    }
  }

  private async sendRaw(raw: Hex): Promise<Hex> {
    this.received.push(raw);
    if (this.failBroadcasts > 0 || this.failWhen(raw)) {
      if (this.failBroadcasts > 0) this.failBroadcasts--;
      throw new RpcFault(-32000, "connection reset by peer");
    }
    const hash = keccak256(raw);
    if (this.known.has(hash)) throw new RpcFault(-32000, "already known");
    const tx = parseTransaction(raw);
    const from = (await recoverTransactionAddress({ serializedTransaction: raw as never })).toLowerCase() as Address;
    const nonce = tx.nonce ?? 0;
    const next = this.nonces.get(from) ?? 0;
    if (nonce < next) throw new RpcFault(-32000, "nonce too low");
    if (this.blackHole) return hash;
    this.known.add(hash);
    const pooled: PooledTx = { hash, raw, from, nonce, to: tx.to ?? null, data: tx.data ?? "0x" };
    const queue = this.queued.get(from) ?? [];
    queue.push(pooled);
    this.queued.set(from, queue);
    this.drain(from);
    return hash;
  }

  /** Mines every queued transaction of `from` whose nonce is next, in order. */
  private drain(from: Address): void {
    const queue = this.queued.get(from) ?? [];
    for (;;) {
      const next = this.nonces.get(from) ?? 0;
      const index = queue.findIndex((q) => q.nonce === next);
      if (index === -1) break;
      const [tx] = queue.splice(index, 1);
      if (tx === undefined) break;
      // Another queued transaction with the same nonce can never be mined now.
      for (const stale of queue.filter((q) => q.nonce === next)) queue.splice(queue.indexOf(stale), 1);
      this.nonces.set(from, next + 1);
      this.mineBlock();
      const logs: RpcLog[] = [];
      let status: "0x1" | "0x0" = "0x1";
      if (tx.to !== null) {
        const saved = [...this.contracts.entries()].map(([address, c]) => [address, c.snapshot()] as const);
        try {
          this.execute(tx.from, tx.to, tx.data, logs, tx.hash);
        } catch (error) {
          if (!(error instanceof Revert)) throw error;
          status = "0x0";
          logs.length = 0;
          for (const [address, state] of saved) this.contracts.get(address)?.restore(state);
        }
      }
      this.logs.push(...logs);
      this.receipts.set(tx.hash, { hash: tx.hash, from: tx.from, to: tx.to, blockNumber: this.blockNumber, status, logs });
    }
  }

  private mineBlock(): void {
    this.blockNumber++;
    this.time += this.blockTime;
    this.blockTimes.set(this.blockNumber, this.time);
  }

  private formatReceipt(receipt: Receipt | undefined) {
    if (receipt === undefined) return null;
    const blockHash = keccak256(toHex(`block-${this.chainId.toString()}-${receipt.blockNumber.toString()}`));
    return {
      transactionHash: receipt.hash,
      transactionIndex: "0x0",
      blockHash,
      blockNumber: numberToHex(receipt.blockNumber),
      from: receipt.from,
      to: receipt.to,
      cumulativeGasUsed: "0x5208",
      gasUsed: "0x5208",
      effectiveGasPrice: "0x1",
      contractAddress: null,
      logs: receipt.logs.map((log) => this.formatLog(log, blockHash)),
      logsBloom: `0x${"0".repeat(512)}`,
      status: receipt.status,
      type: "0x2",
    };
  }

  private formatLog(log: RpcLog, blockHash?: Hex) {
    return {
      address: log.address,
      topics: log.topics,
      data: log.data,
      blockNumber: numberToHex(log.blockNumber),
      blockHash: blockHash ?? keccak256(toHex(`block-${this.chainId.toString()}-${log.blockNumber.toString()}`)),
      transactionHash: log.transactionHash,
      transactionIndex: "0x0",
      logIndex: numberToHex(log.logIndex),
      removed: false,
    };
  }

  private getLogs(filter: {
    address?: string | string[];
    topics?: (Hex | Hex[] | null)[];
    fromBlock?: string;
    toBlock?: string;
  }) {
    const from = filter.fromBlock === undefined || filter.fromBlock === "earliest" ? 0n : BigInt(filter.fromBlock);
    const to =
      filter.toBlock === undefined || filter.toBlock === "latest" || filter.toBlock === "pending"
        ? this.blockNumber
        : BigInt(filter.toBlock);
    const addresses =
      filter.address === undefined
        ? undefined
        : (Array.isArray(filter.address) ? filter.address : [filter.address]).map((a) => a.toLowerCase());
    return this.logs
      .filter((log) => log.blockNumber >= from && log.blockNumber <= to)
      .filter((log) => addresses === undefined || addresses.includes(log.address.toLowerCase()))
      .filter((log) =>
        (filter.topics ?? []).every((topic, i) => {
          if (topic === null) return true;
          const wanted = Array.isArray(topic) ? topic : [topic];
          return wanted.some((t) => t.toLowerCase() === log.topics[i]?.toLowerCase());
        }),
      )
      .map((log) => this.formatLog(log));
  }

  private proof(address: Address, keys: Hex[], tag: string) {
    const number = tag === "latest" ? this.blockNumber : BigInt(tag);
    this.proofHook(address, number);
    // Not a real Merkle proof: the fake contracts do not verify it, they only care which block it is for.
    return {
      address,
      accountProof: [pad(numberToHex(number))],
      balance: "0x0",
      codeHash: zeroHash,
      nonce: "0x0",
      storageHash: zeroHash,
      storageProof: keys.map((key) => ({ key, value: "0x0", proof: [pad(numberToHex(number))] })),
    };
  }
}

/** A fake contract backed by a plain state object, with handlers per function name. */
export function fakeContract<S>(
  abi: Abi,
  initial: S,
  handlers: Record<string, (state: S, ctx: CallContext, args: readonly unknown[]) => unknown>,
): FakeContract & { state: S } {
  const contract = {
    abi,
    state: initial,
    call(ctx: CallContext, functionName: string, args: readonly unknown[]): unknown {
      const handler = handlers[functionName];
      if (handler === undefined) throw new Error(`fake: ${functionName} not implemented`);
      return handler(contract.state, ctx, args);
    },
    snapshot(): unknown {
      return structuredClone(contract.state);
    },
    restore(state: unknown): void {
      contract.state = state as S;
    },
  };
  return contract;
}
