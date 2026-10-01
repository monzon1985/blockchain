// SPDX-License-Identifier: MIT
// Journaled sending for the solver: nonces are assigned from the journal, every signed transaction is persisted
// before it is broadcast, and at the start of every tick all journaled transactions that are not mined yet are
// re-sent in nonce order, before anything new is signed. This closes the gap a "sign with the node's pending nonce"
// scheme leaves open: a transaction journaled but never broadcast (crash, RPC error) keeps its nonce, so no later
// transaction can take it, and its re-send cannot bounce off "nonce too low".
import type { TransactionReceipt } from "viem";

import type { ChainClients, Wallet } from "./chains.ts";
import type { Logger } from "./log.ts";
import type { JournaledTx, SolverStore } from "./store.ts";
import { type Call, broadcast, receiptOf, signCall } from "./tx.ts";

/** How long `sendAndWait` waits for a receipt before giving up for this tick. */
const RECEIPT_TIMEOUT_MS = 60_000;

/** Signs, journals and (re)broadcasts the solver's transactions. */
export class JournaledSender {
  private readonly store: SolverStore;
  private readonly log: Logger;

  constructor(store: SolverStore, log: Logger) {
    this.store = store;
    this.log = log;
  }

  /**
   * Signs `call` from `wallet` on `clients`' chain with the next journal nonce. Nothing is persisted: the caller
   * journals the result atomically with the state change that motivates it (SolverStore.transition), then broadcasts.
   */
  async sign(clients: ChainClients, wallet: Wallet, call: Call, purpose: string): Promise<JournaledTx> {
    const sender = wallet.account.address;
    const chainId = clients.chain.id;
    const pending = await clients.public.getTransactionCount({ address: sender, blockTag: "pending" });
    const nonce = this.store.nextNonce(chainId, sender, pending);
    const signed = await signCall(wallet, call, nonce);
    return { ...signed, chainId, sender, purpose };
  }

  /**
   * Makes the node hold every journaled transaction of `wallet` on this chain that has no receipt yet, lowest nonce
   * first. A mined one is marked `mined`. One whose nonce was consumed by ANOTHER transaction (it can never be mined)
   * is marked `replaced`, and the order logic decides what to do (re-sign with a fresh nonce, or give up). Any other
   * broadcast error is thrown: nothing new should be signed on this chain while its queue cannot be flushed.
   */
  async flush(clients: ChainClients, wallet: Wallet): Promise<void> {
    const sender = wallet.account.address;
    for (const tx of this.store.pendingTxs(clients.chain.id, sender)) {
      if ((await receiptOf(clients, tx.hash)) !== null) {
        this.store.setTxStatus(tx.hash, "mined");
        continue;
      }
      const result = await broadcast(clients, tx.raw);
      if (result !== "nonce-too-low") continue;
      if ((await receiptOf(clients, tx.hash)) !== null) {
        this.store.setTxStatus(tx.hash, "mined");
        continue;
      }
      const mined = await clients.public.getTransactionCount({ address: sender, blockTag: "latest" });
      if (mined > tx.nonce) {
        this.store.setTxStatus(tx.hash, "replaced");
        this.log.warn("journaled transaction replaced: its nonce was used by another transaction", {
          tx: tx.hash,
          nonce: tx.nonce,
          purpose: tx.purpose,
        });
      }
    }
  }

  /**
   * Sends a transaction no order state records (an approval) through the journal and waits for it, so that it
   * takes its nonce from the journal like everything else. Throws if it reverts.
   */
  async sendAndWait(clients: ChainClients, wallet: Wallet, call: Call, purpose: string): Promise<TransactionReceipt> {
    const tx = await this.sign(clients, wallet, call, purpose);
    this.store.journalTx(tx);
    await broadcast(clients, tx.raw);
    // Bounded wait: if the node lost the transaction, the tick fails and the next flush re-sends it.
    const receipt = await clients.public.waitForTransactionReceipt({ hash: tx.hash, timeout: RECEIPT_TIMEOUT_MS });
    this.store.setTxStatus(tx.hash, "mined");
    if (receipt.status !== "success") throw new Error(`${purpose} transaction ${tx.hash} reverted`);
    return receipt;
  }
}
