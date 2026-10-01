// SPDX-License-Identifier: MIT
// Infrastructure roles that are not the solver: the permissioned header relayer (trusted input of the proof-based
// modes) and the mock mailbox's relayer (trusted input of mode 1). Each has a `tick()` like the solver.
import {
  type Address,
  BaseError,
  ContractFunctionRevertedError,
  type Hex,
  encodeFunctionData,
  keccak256,
} from "viem";

import { headerStoreAbi, mockMailboxAbi } from "./abi.ts";
import type { ChainClients, Wallet } from "./chains.ts";
import { type RpcBlock, encodeVerifiedHeader } from "./header.ts";
import type { Logger } from "./log.ts";
import type { SolverStore } from "./store.ts";
import { sendAndWait } from "./tx.ts";

/** Chains, key and HeaderStore the header relayer works with. */
export interface HeaderRelayerDeps {
  origin: ChainClients;
  dest: ChainClients;
  /** Origin-chain wallet holding the header relayer role. */
  wallet: Wallet;
  headerStore: Address;
  log: Logger;
}

/** Relays the latest destination header to the origin HeaderStore whenever the destination advances. */
export class HeaderRelayer {
  private lastRelayed = -1n;
  private readonly deps: HeaderRelayerDeps;

  constructor(deps: HeaderRelayerDeps) {
    this.deps = deps;
  }

  /** Relays the latest destination header if it is new. Returns its number, or undefined if nothing was sent. */
  async tick(): Promise<bigint | undefined> {
    const { origin, dest, wallet, headerStore, log } = this.deps;
    const latest = await dest.public.getBlockNumber();
    if (latest <= this.lastRelayed) return undefined;
    const block = (await dest.public.request({
      method: "eth_getBlockByNumber",
      params: [`0x${latest.toString(16)}`, false],
    })) as unknown as RpcBlock;
    const rlp = encodeVerifiedHeader(block);
    const chainId = BigInt(dest.chain.id);
    const stored = await origin.public.readContract({
      address: headerStore,
      abi: headerStoreAbi,
      functionName: "header",
      args: [chainId, latest],
    });
    if (stored.blockHash === block.hash) {
      this.lastRelayed = latest;
      return undefined;
    }
    await sendAndWait(origin, wallet, {
      to: headerStore,
      data: encodeFunctionData({ abi: headerStoreAbi, functionName: "submitHeader", args: [chainId, rlp] }),
    });
    this.lastRelayed = latest;
    log.info("relayed header", { chainId, block: latest, hash: block.hash });
    return latest;
  }
}

/** Chains, key, mailboxes and cursor store the mailbox relayer works with. */
export interface MailboxRelayerDeps {
  origin: ChainClients;
  dest: ChainClients;
  /** Origin-chain wallet holding the mailbox relayer role. */
  wallet: Wallet;
  destMailbox: Address;
  originMailbox: Address;
  /** Keeps the `dispatch` cursor (the first destination block not fully handled yet). */
  store: SolverStore;
  log: Logger;
}

/**
 * Delivers every destination Dispatch addressed to the origin chain (the mock messaging layer). The cursor only
 * moves past a message once it was delivered or the origin chain itself rejected it (a revert, such as the order no
 * longer being open, which no retry can change). A delivery that failed for any other reason (RPC timeout, nonce
 * race, node restart) keeps the cursor at its block, so the message is retried on the next tick.
 */
export class MailboxRelayer {
  private readonly deps: MailboxRelayerDeps;

  constructor(deps: MailboxRelayerDeps) {
    this.deps = deps;
  }

  /** Delivers what is pending. Returns the ids of the messages delivered by this tick. */
  async tick(): Promise<Hex[]> {
    const { origin, dest, wallet, destMailbox, originMailbox, store, log } = this.deps;
    const latest = await dest.public.getBlockNumber();
    const from = BigInt(store.cursor("dispatch") ?? 0);
    if (from > latest) return [];
    const events = await dest.public.getContractEvents({
      address: destMailbox,
      abi: mockMailboxAbi,
      eventName: "Dispatch",
      args: { destinationDomain: BigInt(origin.chain.id) },
      fromBlock: from,
      toBlock: latest,
    });
    const delivered: Hex[] = [];
    let retryFrom: bigint | undefined;
    for (const event of events) {
      const message = event.args.message;
      if (message === undefined) continue;
      const id = keccak256(message);
      const done = await origin.public.readContract({
        address: originMailbox,
        abi: mockMailboxAbi,
        functionName: "delivered",
        args: [id],
      });
      if (done) continue;
      try {
        await sendAndWait(origin, wallet, {
          to: originMailbox,
          data: encodeFunctionData({ abi: mockMailboxAbi, functionName: "process", args: [message] }),
        });
        delivered.push(id);
        log.info("delivered message", { messageId: id });
      } catch (error) {
        if (await this.rejectedByOrigin(message)) {
          log.warn("message rejected by the origin chain; skipped", { messageId: id, error });
        } else {
          log.warn("message delivery failed; will retry", { messageId: id, error });
          retryFrom ??= event.blockNumber;
        }
      }
    }
    store.setCursor("dispatch", Number(retryFrom ?? latest + 1n));
    return delivered;
  }

  /**
   * True when delivering `message` reverts on the origin chain right now (a contract-level rejection, permanent for
   * this protocol: orders never reopen and routes are write-once). False when it would succeed, or when the check
   * itself failed for a non-contract reason, both of which mean "retry".
   */
  private async rejectedByOrigin(message: Hex): Promise<boolean> {
    const { origin, wallet, originMailbox } = this.deps;
    try {
      await origin.public.simulateContract({
        account: wallet.account,
        address: originMailbox,
        abi: mockMailboxAbi,
        functionName: "process",
        args: [message],
      });
      return false;
    } catch (error) {
      return error instanceof BaseError && error.walk((e) => e instanceof ContractFunctionRevertedError) !== null;
    }
  }
}
