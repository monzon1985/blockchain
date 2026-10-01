// SPDX-License-Identifier: MIT
// The transaction journal (store.ts) and the broadcast classification (tx.ts), without any chain.
import type { Address, Hex } from "viem";
import { describe, expect, it } from "vitest";

import { IllegalTransitionError, type JournaledTx, SolverStore } from "../src/store.ts";
import { classifyBroadcastError, gasWithHeadroom } from "../src/tx.ts";

const SENDER: Address = "0x00000000000000000000000000000000000000aA";
const ID: Hex = `0x${"22".repeat(32)}`;

function tx(nonce: number, chainId = 1002, purpose = "fill"): JournaledTx {
  const hash: Hex = `0x${nonce.toString(16).padStart(2, "0").repeat(32)}`;
  return { hash, raw: "0x02", chainId, sender: SENDER, nonce, purpose };
}

describe("journal nonces", () => {
  it("assigns the node's pending nonce when nothing is journaled, and one past the journal otherwise", () => {
    const store = new SolverStore(":memory:");
    expect(store.nextNonce(1002, SENDER, 5)).toBe(5);
    store.journalTx(tx(5));
    // The node does not know nonce 5 (never broadcast): the journal still reserves it.
    expect(store.nextNonce(1002, SENDER, 5)).toBe(6);
    // Transactions sent outside the journal moved the node ahead: follow the node.
    expect(store.nextNonce(1002, SENDER, 9)).toBe(9);
    // Other chains and other senders are independent nonce spaces.
    expect(store.nextNonce(1001, SENDER, 0)).toBe(0);
    expect(store.nextNonce(1002, "0x00000000000000000000000000000000000000bb", 0)).toBe(0);
    store.close();
  });

  it("lists pending transactions in nonce order and tracks their status", () => {
    const store = new SolverStore(":memory:");
    store.journalTx(tx(3));
    store.journalTx(tx(1));
    store.journalTx(tx(2, 1001));
    expect(store.pendingTxs(1002, SENDER).map((t) => t.nonce)).toEqual([1, 3]);
    store.setTxStatus(tx(1).hash, "mined");
    store.setTxStatus(tx(3).hash, "replaced");
    expect(store.pendingTxs(1002, SENDER)).toEqual([]);
    expect(store.tx(tx(3).hash)?.status).toBe("replaced");
    expect(store.tx(tx(3).hash)?.sender).toBe(SENDER.toLowerCase());
    store.close();
  });

  it("journals a transaction atomically with its order transition: an illegal transition journals nothing", () => {
    const store = new SolverStore(":memory:");
    store.discover(ID, "0x", "mailbox");
    expect(() => {
      store.transition(ID, "WAITING", "FILL_SIGNED", {}, tx(7));
    }).toThrow(IllegalTransitionError);
    expect(store.tx(tx(7).hash)).toBeUndefined();
    store.transition(ID, "DISCOVERED", "FILL_SIGNED", { fillTx: tx(7).hash, fillRaw: "0x02" }, tx(7));
    expect(store.tx(tx(7).hash)?.status).toBe("pending");
    expect(store.nextNonce(1002, SENDER, 0)).toBe(8);
    store.close();
  });

  it("journals a feed open atomically with its status, and forgets a feed entry on request", () => {
    const store = new SolverStore(":memory:");
    store.setFeedStatus("order-1.json", "sent", tx(4, 1001).hash, "0x02", tx(4, 1001));
    expect(store.feedStatus("order-1.json")?.status).toBe("sent");
    expect(store.pendingTxs(1001, SENDER).map((t) => t.purpose)).toEqual(["fill"]);
    store.clearFeedStatus("order-1.json");
    expect(store.feedStatus("order-1.json")).toBeUndefined();
    store.close();
  });
});

describe("broadcast classification", () => {
  it("tells a re-send of a known transaction and a consumed nonce apart from real failures", () => {
    expect(classifyBroadcastError("RPC error: already known")).toBe("known");
    expect(classifyBroadcastError("Transaction already imported")).toBe("known");
    expect(classifyBroadcastError("Details: nonce too low")).toBe("nonce-too-low");
    expect(classifyBroadcastError("nonce has already been used")).toBe("nonce-too-low");
    expect(classifyBroadcastError("max fee per gas less than block base fee")).toBeUndefined();
    expect(classifyBroadcastError("connection reset by peer")).toBeUndefined();
  });

  it("signs journaled transactions with gas headroom over the estimate", () => {
    expect(gasWithHeadroom(100_000n)).toBe(175_000n);
    expect(gasWithHeadroom(0n)).toBe(25_000n);
  });
});
