// SPDX-License-Identifier: MIT
// The solver: discovers orders on the origin chain, prices them, fills on the destination chain and gets repaid
// through the order's settlement mode. Every step is a transition of the journaled state machine in store.ts, and
// every transaction goes through the journal (journal.ts); `tick()` is idempotent, so the process can be killed at
// any instruction and restarted.
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";

import { type Address, type Hex, encodeFunctionData, erc20Abi, maxUint256, zeroAddress } from "viem";

import {
  destinationSettlerAbi,
  mailboxFillReporterAbi,
  optimisticSettlementModuleAbi,
  originSettlerAbi,
  storageProofSettlementModuleAbi,
} from "./abi.ts";
import type { ChainClients, Wallet } from "./chains.ts";
import { chainTime } from "./chains.ts";
import { DEFAULT_MAILBOX_RECHECK_SEC, type SolverConfig, modeOf } from "./config.ts";
import { JournaledSender } from "./journal.ts";
import type { Logger } from "./log.ts";
import {
  type GaslessCrossChainOrder,
  type Intent,
  decodeOriginData,
  encodeOriginData,
  gaslessIntent,
  orderIdOf,
} from "./orders.ts";
import { type SettlementMode, quote } from "./pricing.ts";
import { fillRecordProof, findStoredHeader } from "./proofs.ts";
import type { OrderRow, SettleKind, SolverStore } from "./store.ts";
import { type Call, broadcast, receiptOf } from "./tx.ts";

/** Points at which a test can make the process die, to exercise recovery (see e2e/crash-solver.ts). */
export const CHECKPOINTS = ["after-fill-persist", "after-fill-broadcast"] as const;

/** A crash-injection point. */
export type Checkpoint = (typeof CHECKPOINTS)[number];

/** Everything the solver needs: config, both chains, one wallet per chain (same key), the journal and a logger. */
export interface SolverDeps {
  config: SolverConfig;
  origin: ChainClients;
  dest: ChainClients;
  originWallet: Wallet;
  destWallet: Wallet;
  store: SolverStore;
  log: Logger;
  /** Fault injection for the crash-recovery e2e, wired only by e2e/crash-solver.ts; src/main.ts never sets it. */
  onCheckpoint?: (point: Checkpoint) => void;
}

/** OriginSettler escrow status (OrderStatus enum). */
export const EscrowStatus = { None: 0, Open: 1, Repaid: 2, Refunded: 3 } as const;

/** A signed gasless order as dropped in the feed directory (bigints as decimal strings). */
export interface FeedEntry {
  order: Omit<GaslessCrossChainOrder, "nonce" | "originChainId"> & { nonce: string; originChainId: string };
  signature: Hex;
}

/**
 * The solver bot. Call `tick()` in a loop: it first re-sends every journaled transaction that is not mined yet (in
 * nonce order, before anything new is signed), then opens profitable gasless orders from the feed, records new Open
 * events, and advances every active order by one step of its state machine.
 */
export class Solver {
  private refundGrace: bigint | undefined;
  private readonly me: Address;
  private readonly deps: SolverDeps;
  private readonly sender: JournaledSender;

  constructor(deps: SolverDeps) {
    this.deps = deps;
    this.me = deps.destWallet.account.address;
    this.sender = new JournaledSender(deps.store, deps.log);
  }

  /** One pass over everything. Safe to call again after any failure or crash. */
  async tick(): Promise<void> {
    const { origin, dest, originWallet, destWallet } = this.deps;
    await this.sender.flush(origin, originWallet);
    await this.sender.flush(dest, destWallet);
    await this.ingestFeed();
    await this.discover();
    for (const order of this.deps.store.active()) {
      try {
        await this.step(order);
      } catch (error) {
        this.deps.log.warn("step failed; will retry", { orderId: order.orderId, state: order.state, error });
      }
    }
  }

  // ----------------------------------------------------------------------------------------------------------------
  // Discovery
  // ----------------------------------------------------------------------------------------------------------------

  /** Opens profitable gasless orders from the feed directory (openFor), journaled like fills. */
  private async ingestFeed(): Promise<void> {
    const dir = this.deps.config.feedDir;
    if (dir === undefined) return;
    const { store, origin, originWallet, config } = this.deps;
    for (const name of readdirSync(dir).filter((f) => f.endsWith(".json")).sort()) {
      const status = store.feedStatus(name);
      if (status?.status === "sent" && status.tx !== null) {
        const receipt = await receiptOf(origin, status.tx);
        if (receipt !== null) {
          store.setFeedStatus(name, receipt.status === "success" ? "opened" : "open-failed", status.tx);
        } else if (store.tx(status.tx)?.status === "replaced") {
          store.clearFeedStatus(name); // never mined: evaluate the order again
        }
        continue; // otherwise still pending: the journal flush re-sends it
      }
      if (status !== undefined) continue;

      const entry = JSON.parse(readFileSync(join(dir, name), "utf8")) as FeedEntry;
      const order: GaslessCrossChainOrder = {
        ...entry.order,
        nonce: BigInt(entry.order.nonce),
        originChainId: BigInt(entry.order.originChainId),
      };
      const intent = gaslessIntent(order);
      const mode = modeOf(config.deployment, intent.data.settlementModule);
      if (mode === undefined || !this.supported(intent)) {
        store.setFeedStatus(name, "unsupported");
        continue;
      }
      if ((await this.escrowStatus(orderIdOf(encodeOriginData(intent)))) !== EscrowStatus.None) {
        store.setFeedStatus(name, "opened-elsewhere");
        continue;
      }
      const decision = await this.quoteFor(intent, mode, true);
      if (decision.action === "skip") {
        store.setFeedStatus(name, `skipped:${decision.reason}`);
        continue;
      }
      const tx = await this.sender.sign(
        origin,
        originWallet,
        {
          to: config.deployment.origin.originSettler,
          data: encodeFunctionData({
            abi: originSettlerAbi,
            functionName: "openFor",
            args: [order, entry.signature, "0x"],
          }),
        },
        "open",
      );
      store.setFeedStatus(name, "sent", tx.hash, tx.raw, tx);
      await broadcast(origin, tx.raw);
      this.deps.log.info("opened gasless order", { feed: name, tx: tx.hash });
    }
  }

  /** Records every new Open event of the origin settler. */
  private async discover(): Promise<void> {
    const { store, origin, config, log } = this.deps;
    const latest = await origin.public.getBlockNumber();
    const from = BigInt(store.cursor("open") ?? 0);
    if (from > latest) return;
    const events = await origin.public.getContractEvents({
      address: config.deployment.origin.originSettler,
      abi: originSettlerAbi,
      eventName: "Open",
      fromBlock: from,
      toBlock: latest,
    });
    for (const event of events) {
      const orderId = event.args.orderId;
      const originData = event.args.resolvedOrder?.fillInstructions[0]?.originData;
      if (orderId === undefined || originData === undefined) continue;
      if (orderIdOf(originData) !== orderId) {
        log.warn("Open event whose originData does not hash to its orderId; ignored", { orderId });
        continue;
      }
      const intent = decodeOriginData(originData);
      const mode = modeOf(config.deployment, intent.data.settlementModule);
      if (store.discover(orderId, originData, mode ?? "mailbox")) {
        log.info("discovered order", { orderId, mode });
        if (mode === undefined || !this.supported(intent)) {
          store.transition(orderId, "DISCOVERED", "SKIPPED", { reason: "unsupported" });
        }
      }
    }
    store.setCursor("open", Number(latest) + 1);
  }

  /** Orders this deployment can fill and get repaid for. */
  private supported(intent: Intent): boolean {
    const { deployment } = this.deps.config;
    return (
      intent.originSettler.toLowerCase() === deployment.origin.originSettler.toLowerCase() &&
      intent.originChainId === BigInt(deployment.origin.chainId) &&
      intent.data.destinationChainId === BigInt(deployment.destination.chainId) &&
      intent.data.destinationSettler.toLowerCase() === deployment.destination.destinationSettler.toLowerCase()
    );
  }

  // ----------------------------------------------------------------------------------------------------------------
  // State machine
  // ----------------------------------------------------------------------------------------------------------------

  private async step(order: OrderRow): Promise<void> {
    switch (order.state) {
      case "DISCOVERED":
      case "WAITING":
        return this.evaluate(order);
      case "FILL_SIGNED":
      case "FILL_SENT":
        return this.trackFill(order);
      case "FILLED":
        return this.startSettlement(order);
      case "SETTLE_SENT":
        return this.trackSettlement(order);
      case "AWAITING_REPAYMENT":
        return this.awaitRepayment(order);
      default:
        return;
    }
  }

  private async evaluate(order: OrderRow): Promise<void> {
    const { store, dest, destWallet, config, log } = this.deps;
    const intent = decodeOriginData(order.originData);
    const record = await this.fillRecord(order.orderId);
    if (record.filler !== zeroAddress) {
      store.transition(order.orderId, order.state, "LOST", { reason: "filled by another solver" });
      return;
    }
    const now = await chainTime(dest);
    if (order.state === "WAITING" && order.waitUntil !== null && now < BigInt(order.waitUntil)) return;

    const decision = await this.quoteFor(intent, order.mode, false);
    if (decision.action === "skip") {
      const to = now > BigInt(intent.fillDeadline) ? "EXPIRED" : "SKIPPED";
      store.transition(order.orderId, order.state, to, { reason: decision.reason });
      log.info("not filling", { orderId: order.orderId, reason: decision.reason });
      return;
    }
    if (decision.action === "wait") {
      store.transition(order.orderId, order.state, "WAITING", { waitUntil: Number(decision.at) });
      return;
    }

    await this.ensureAllowance(dest, destWallet, intent.data.outputToken, config.deployment.destination.destinationSettler);
    const tx = await this.sender.sign(
      dest,
      destWallet,
      {
        to: config.deployment.destination.destinationSettler,
        data: encodeFunctionData({
          abi: destinationSettlerAbi,
          functionName: "fillWithRepayment",
          args: [order.orderId, order.originData, config.repaymentAddress],
        }),
      },
      "fill",
    );
    store.transition(order.orderId, order.state, "FILL_SIGNED", { fillTx: tx.hash, fillRaw: tx.raw }, tx);
    this.deps.onCheckpoint?.("after-fill-persist");
    await broadcast(dest, tx.raw);
    store.transition(order.orderId, "FILL_SIGNED", "FILL_SENT");
    this.deps.onCheckpoint?.("after-fill-broadcast");
    log.info("fill sent", { orderId: order.orderId, tx: tx.hash, expectedProfit: decision.expectedProfit });
  }

  /** Recovers or confirms a journaled fill. */
  private async trackFill(order: OrderRow): Promise<void> {
    const { store, dest, log } = this.deps;
    if (order.fillTx === null || order.fillRaw === null) throw new Error("fill journal entry is incomplete");
    const receipt = await receiptOf(dest, order.fillTx);
    if (receipt === null) {
      if (store.tx(order.fillTx)?.status === "replaced") return this.fillReplaced(order);
      const intent = decodeOriginData(order.originData);
      if ((await chainTime(dest)) > BigInt(intent.fillDeadline)) {
        // The settler rejects fills after the deadline, so this transaction can no longer fill. It stays in the
        // journal, which keeps re-sending it until it is mined (and reverts) so that its nonce is not left as a gap;
        // the output it reserved is released now.
        const filled = (await this.fillRecord(order.orderId)).filler !== zeroAddress;
        // Our own fill may have been mined (before the deadline) since the receipt lookup above: the next tick
        // records it from its receipt instead of giving the order up.
        if (filled && (await receiptOf(dest, order.fillTx)) !== null) return;
        store.transition(order.orderId, order.state, filled ? "LOST" : "EXPIRED", {
          reason: "fill not mined before the fill deadline",
        });
        return;
      }
      // Not mined yet: the journal flush at the start of this tick (re)sent it.
      if (order.state === "FILL_SIGNED") store.transition(order.orderId, "FILL_SIGNED", "FILL_SENT");
      return;
    }
    if (receipt.status === "success") {
      const block = await dest.public.getBlock({ blockNumber: receipt.blockNumber });
      store.transition(order.orderId, order.state, "FILLED", {
        fillBlock: Number(receipt.blockNumber),
        filledAt: Number(block.timestamp),
      });
      log.info("fill mined", { orderId: order.orderId, block: receipt.blockNumber });
      return;
    }
    const record = await this.fillRecord(order.orderId);
    const intent = decodeOriginData(order.originData);
    const now = await chainTime(dest);
    if (record.filler !== zeroAddress) {
      store.transition(order.orderId, order.state, "LOST", { reason: "fill reverted: already filled" });
    } else if (now > BigInt(intent.fillDeadline)) {
      store.transition(order.orderId, order.state, "EXPIRED", { reason: "fill reverted after deadline" });
    } else {
      store.transition(order.orderId, order.state, "DISCOVERED", { fillTx: null, fillRaw: null, reason: "fill reverted" });
    }
  }

  /** The journaled fill can never be mined (another transaction took its nonce): re-evaluate or give up. */
  private async fillReplaced(order: OrderRow): Promise<void> {
    const { store, dest } = this.deps;
    const record = await this.fillRecord(order.orderId);
    const intent = decodeOriginData(order.originData);
    if (record.filler !== zeroAddress) {
      store.transition(order.orderId, order.state, "LOST", { reason: "fill replaced; filled by someone else" });
    } else if ((await chainTime(dest)) > BigInt(intent.fillDeadline)) {
      store.transition(order.orderId, order.state, "EXPIRED", { reason: "fill replaced; deadline passed" });
    } else {
      store.transition(order.orderId, order.state, "DISCOVERED", {
        fillTx: null,
        fillRaw: null,
        reason: "fill replaced (nonce used by another transaction); re-signing",
      });
    }
  }

  /** Starts (or restarts) repayment through the order's settlement mode. */
  private async startSettlement(order: OrderRow): Promise<void> {
    if (await this.closeIfSettled(order)) return;
    const { config, origin, dest, originWallet, destWallet, store } = this.deps;
    const fillHash = await this.fillHash(order);
    switch (order.mode) {
      case "mailbox":
        return this.sendSettle(order, "report", dest, destWallet, this.reportCall(order));
      case "optimistic": {
        const module = config.deployment.origin.optimisticModule;
        const filledAt = BigInt(order.filledAt ?? 0);
        // Claims are keyed by (order, filler, time): other claims about this order cannot block ours. Only the very
        // same assertion can already be pending, posted by someone else; then we just wait for it to pay us.
        const ours = await this.claimOf(order.orderId, config.repaymentAddress, filledAt);
        if (ours.claimant !== zeroAddress) {
          store.transition(order.orderId, "FILLED", "AWAITING_REPAYMENT", {
            challengeDeadline: Number(ours.challengeDeadline),
            reason: "our claim was already posted by someone else",
          });
          return;
        }
        await this.ensureAllowance(origin, originWallet, config.deployment.origin.bondToken, module);
        return this.sendSettle(order, "claim", origin, originWallet, {
          to: module,
          data: encodeFunctionData({
            abi: optimisticSettlementModuleAbi,
            functionName: "claim",
            args: [order.orderId, config.repaymentAddress, filledAt, fillHash],
          }),
        });
      }
      case "proof": {
        if (order.fillBlock === null) throw new Error("filled order without fill block");
        const header = await findStoredHeader(
          origin,
          config.deployment.origin.headerStore,
          BigInt(config.deployment.destination.chainId),
          BigInt(order.fillBlock),
        );
        if (header === undefined) return; // wait for the header relayer
        const proof = await fillRecordProof(
          dest,
          config.deployment.destination.destinationSettler,
          order.orderId,
          header.blockNumber,
        );
        return this.sendSettle(order, "prove", origin, originWallet, {
          to: config.deployment.origin.proofModule,
          data: encodeFunctionData({
            abi: storageProofSettlementModuleAbi,
            functionName: "proveFill",
            args: [order.orderId, header.blockNumber, fillHash, proof.accountProof, proof.slotProof],
          }),
        });
      }
    }
  }

  private reportCall(order: OrderRow): Call {
    const intent = decodeOriginData(order.originData);
    return {
      to: this.deps.config.deployment.destination.reporter,
      data: encodeFunctionData({
        abi: mailboxFillReporterAbi,
        functionName: "report",
        args: [order.orderId, intent.originChainId],
      }),
    };
  }

  private async sendSettle(
    order: OrderRow,
    kind: SettleKind,
    clients: ChainClients,
    wallet: Wallet,
    call: Call,
  ): Promise<void> {
    const tx = await this.sender.sign(clients, wallet, call, kind);
    this.deps.store.transition(
      order.orderId,
      order.state,
      "SETTLE_SENT",
      { settleKind: kind, settleTx: tx.hash, settleRaw: tx.raw },
      tx,
    );
    await broadcast(clients, tx.raw);
    this.deps.log.info("settlement sent", { orderId: order.orderId, kind, tx: tx.hash });
  }

  private async trackSettlement(order: OrderRow): Promise<void> {
    const { store, origin, dest, config } = this.deps;
    if (order.settleTx === null || order.settleRaw === null || order.settleKind === null) {
      throw new Error("settlement journal entry is incomplete");
    }
    const clients = order.settleKind === "report" ? dest : origin;
    const receipt = await receiptOf(clients, order.settleTx);
    if (receipt === null) {
      if (store.tx(order.settleTx)?.status === "replaced") {
        if (await this.closeIfSettled(order)) return;
        store.transition(order.orderId, "SETTLE_SENT", "FILLED", { reason: `${order.settleKind} transaction replaced` });
      }
      return; // otherwise still pending: the journal flush re-sends it
    }
    if (receipt.status !== "success") {
      if (await this.closeIfSettled(order)) return;
      store.transition(order.orderId, "SETTLE_SENT", "FILLED", { reason: `${order.settleKind} reverted` });
      return;
    }
    if (order.settleKind === "report") {
      const recheck = BigInt(config.mailboxRecheckSec ?? DEFAULT_MAILBOX_RECHECK_SEC);
      store.transition(order.orderId, "SETTLE_SENT", "AWAITING_REPAYMENT", {
        recheckAt: Number((await chainTime(origin)) + recheck),
      });
    } else if (order.settleKind === "claim") {
      const ours = await this.claimOf(order.orderId, config.repaymentAddress, BigInt(order.filledAt ?? 0));
      store.transition(order.orderId, "SETTLE_SENT", "AWAITING_REPAYMENT", {
        challengeDeadline: Number(ours.challengeDeadline),
      });
    } else if (!(await this.closeIfSettled(order))) {
      store.transition(order.orderId, "SETTLE_SENT", "FILLED", { reason: `${order.settleKind} did not close the order` });
    }
  }

  private async awaitRepayment(order: OrderRow): Promise<void> {
    if (await this.closeIfSettled(order)) return;
    const { origin, dest, originWallet, destWallet, config, store } = this.deps;
    if (order.mode === "mailbox") {
      // The messaging layer should deliver the report. If it still has not when recheckAt passes, report again: the
      // new message is independent, and whichever is delivered first repays; the others are rejected harmlessly.
      if (order.recheckAt !== null && (await chainTime(origin)) > BigInt(order.recheckAt)) {
        this.deps.log.warn("report not delivered in time; reporting again", { orderId: order.orderId });
        await this.sendSettle(order, "report", dest, destWallet, this.reportCall(order));
      }
      return;
    }
    if (order.mode !== "optimistic") return;
    const filledAt = BigInt(order.filledAt ?? 0);
    const ours = await this.claimOf(order.orderId, config.repaymentAddress, filledAt);
    if (ours.claimant === zeroAddress) {
      // Our claim is resolved without repaying us (it cannot be disproven while the record matches, so this only
      // happens if someone else finalized it between our reads): start over; closeIfSettled sorts it out.
      store.transition(order.orderId, "AWAITING_REPAYMENT", "FILLED", { reason: "claim resolved" });
      return;
    }
    if ((await chainTime(origin)) <= ours.challengeDeadline) return;
    await this.sendSettle(order, "finalize", origin, originWallet, {
      to: config.deployment.origin.optimisticModule,
      data: encodeFunctionData({
        abi: optimisticSettlementModuleAbi,
        functionName: "finalize",
        args: [order.orderId, config.repaymentAddress, filledAt],
      }),
    });
  }

  /** Moves the order to SETTLED (repaid to us), or LOST (refunded, or repaid to someone else) if its escrow closed. */
  private async closeIfSettled(order: OrderRow): Promise<boolean> {
    const { store, log, config } = this.deps;
    const status = await this.escrowStatus(order.orderId);
    if (status === EscrowStatus.Repaid) {
      const payee = await this.repaidTo(order.orderId);
      if (payee !== undefined && payee.toLowerCase() !== config.repaymentAddress.toLowerCase()) {
        store.transition(order.orderId, order.state, "LOST", { reason: `escrow repaid to ${payee}` });
        return true;
      }
      store.transition(order.orderId, order.state, "SETTLED");
      log.info("repaid", { orderId: order.orderId });
      return true;
    }
    if (status === EscrowStatus.Refunded) {
      store.transition(order.orderId, order.state, "LOST", { reason: "escrow refunded" });
      return true;
    }
    return false;
  }

  // ----------------------------------------------------------------------------------------------------------------
  // Chain reads
  // ----------------------------------------------------------------------------------------------------------------

  private async quoteFor(intent: Intent, mode: SettlementMode, needsOpen: boolean) {
    const { origin, dest, config } = this.deps;
    this.refundGrace ??= await origin.public.readContract({
      address: config.deployment.origin.originSettler,
      abi: originSettlerAbi,
      functionName: "REFUND_GRACE",
    });
    const [now, balance, gasPriceOrigin, gasPriceDest] = await Promise.all([
      chainTime(dest),
      dest.public.readContract({
        address: intent.data.outputToken,
        abi: erc20Abi,
        functionName: "balanceOf",
        args: [this.me],
      }),
      origin.public.getGasPrice(),
      dest.public.getGasPrice(),
    ]);
    return quote({
      intent,
      mode,
      now,
      me: this.me,
      inventory: balance - this.reserved(intent.data.outputToken),
      gasPriceOrigin,
      gasPriceDest,
      needsOpen,
      refundGrace: this.refundGrace,
      config: config.pricing,
    });
  }

  /** Output already committed to signed-but-unmined fills of the same token. */
  private reserved(token: Address): bigint {
    let total = 0n;
    for (const row of this.deps.store.active()) {
      if (row.state !== "FILL_SIGNED" && row.state !== "FILL_SENT") continue;
      const intent = decodeOriginData(row.originData);
      if (intent.data.outputToken.toLowerCase() === token.toLowerCase()) total += intent.data.outputStartAmount;
    }
    return total;
  }

  private async ensureAllowance(clients: ChainClients, wallet: Wallet, token: Address, spender: Address): Promise<void> {
    const allowance = await clients.public.readContract({
      address: token,
      abi: erc20Abi,
      functionName: "allowance",
      args: [wallet.account.address, spender],
    });
    if (allowance >= maxUint256 / 2n) return;
    await this.sender.sendAndWait(
      clients,
      wallet,
      {
        to: token,
        data: encodeFunctionData({ abi: erc20Abi, functionName: "approve", args: [spender, maxUint256] }),
      },
      "approve",
    );
  }

  private async fillRecord(orderId: Hex) {
    return this.deps.dest.public.readContract({
      address: this.deps.config.deployment.destination.destinationSettler,
      abi: destinationSettlerAbi,
      functionName: "fillRecord",
      args: [orderId],
    });
  }

  private async fillHash(order: OrderRow): Promise<Hex> {
    const record = await this.fillRecord(order.orderId);
    return record.fillHash;
  }

  private async claimOf(orderId: Hex, filler: Address, filledAt: bigint) {
    return this.deps.origin.public.readContract({
      address: this.deps.config.deployment.origin.optimisticModule,
      abi: optimisticSettlementModuleAbi,
      functionName: "claimOf",
      args: [orderId, filler, filledAt],
    });
  }

  private async escrowStatus(orderId: Hex): Promise<number> {
    const escrow = await this.deps.origin.public.readContract({
      address: this.deps.config.deployment.origin.originSettler,
      abi: originSettlerAbi,
      functionName: "escrowOf",
      args: [orderId],
    });
    return escrow.status;
  }

  /** Who the OriginSettler actually repaid for `orderId` (from its OrderSettled event), if it can be found. */
  private async repaidTo(orderId: Hex): Promise<Address | undefined> {
    const events = await this.deps.origin.public.getContractEvents({
      address: this.deps.config.deployment.origin.originSettler,
      abi: originSettlerAbi,
      eventName: "OrderSettled",
      args: { orderId },
      fromBlock: 0n,
      toBlock: "latest",
    });
    return events.at(-1)?.args.filler;
  }
}
