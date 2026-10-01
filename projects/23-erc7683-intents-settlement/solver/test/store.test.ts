// SPDX-License-Identifier: MIT
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import type { Hex } from "viem";
import { afterEach, describe, expect, it } from "vitest";

import {
  IllegalTransitionError,
  ORDER_STATES,
  type OrderState,
  SolverStore,
  TERMINAL_STATES,
  TRANSITIONS,
} from "../src/store.ts";

const ID: Hex = `0x${"11".repeat(32)}`;
const DATA: Hex = "0xabcdef";
const dirs: string[] = [];

function freshPath(): string {
  const dir = mkdtempSync(join(tmpdir(), "solver-store-"));
  dirs.push(dir);
  return join(dir, "solver.db");
}

afterEach(() => {
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

describe("state machine definition", () => {
  it("has no exits from terminal states and exits from every other state", () => {
    for (const state of ORDER_STATES) {
      if (TERMINAL_STATES.has(state)) expect(TRANSITIONS[state]).toEqual([]);
      else expect(TRANSITIONS[state].length).toBeGreaterThan(0);
    }
  });

  it("reaches SETTLED from DISCOVERED in every settlement mode", () => {
    const paths: OrderState[][] = [
      // mode 1: fill, report, repaid when the mailbox delivers
      ["DISCOVERED", "FILL_SIGNED", "FILL_SENT", "FILLED", "SETTLE_SENT", "AWAITING_REPAYMENT", "SETTLED"],
      // mode 2: fill, claim, wait the window, finalize
      ["DISCOVERED", "WAITING", "FILL_SIGNED", "FILL_SENT", "FILLED", "SETTLE_SENT", "AWAITING_REPAYMENT", "SETTLE_SENT", "SETTLED"],
      // mode 3: fill, prove
      ["DISCOVERED", "FILL_SIGNED", "FILL_SENT", "FILLED", "SETTLE_SENT", "SETTLED"],
      // recovery after a crash between journaling and broadcasting: straight from FILL_SIGNED to FILLED
      ["DISCOVERED", "FILL_SIGNED", "FILLED", "SETTLE_SENT", "SETTLED"],
    ];
    for (const path of paths) {
      for (let i = 0; i + 1 < path.length; i++) {
        const from = path[i] as OrderState;
        expect(TRANSITIONS[from]).toContain(path[i + 1]);
      }
    }
  });

  it("never allows paying twice or refilling after a fill", () => {
    expect(TRANSITIONS.FILLED).not.toContain("FILL_SIGNED");
    expect(TRANSITIONS.SETTLE_SENT).not.toContain("FILL_SIGNED");
    expect(TRANSITIONS.SETTLED).toEqual([]);
  });
});

describe("SolverStore", () => {
  it("discovers an order once", () => {
    const store = new SolverStore(freshPath());
    expect(store.discover(ID, DATA, "mailbox")).toBe(true);
    expect(store.discover(ID, DATA, "proof")).toBe(false);
    expect(store.get(ID)?.mode).toBe("mailbox");
    store.close();
  });

  it("applies legal transitions with their patch and records history", () => {
    const store = new SolverStore(freshPath());
    store.discover(ID, DATA, "optimistic");
    store.transition(ID, "DISCOVERED", "WAITING", { waitUntil: 123 });
    store.transition(ID, "WAITING", "FILL_SIGNED", { fillTx: "0xaa", fillRaw: "0xbb", waitUntil: null });
    const row = store.get(ID);
    expect(row?.state).toBe("FILL_SIGNED");
    expect(row?.fillTx).toBe("0xaa");
    expect(row?.waitUntil).toBeNull();
    expect(store.history(ID)).toEqual([
      { from: "DISCOVERED", to: "WAITING" },
      { from: "WAITING", to: "FILL_SIGNED" },
    ]);
    store.close();
  });

  it("rejects transitions outside the table", () => {
    const store = new SolverStore(freshPath());
    store.discover(ID, DATA, "mailbox");
    expect(() => {
      store.transition(ID, "DISCOVERED", "SETTLED");
    }).toThrow(IllegalTransitionError);
    expect(store.get(ID)?.state).toBe("DISCOVERED");
    store.close();
  });

  it("rejects a stale transition (the order already moved) and rolls back", () => {
    const store = new SolverStore(freshPath());
    store.discover(ID, DATA, "mailbox");
    store.transition(ID, "DISCOVERED", "SKIPPED", { reason: "unprofitable" });
    expect(() => {
      store.transition(ID, "DISCOVERED", "FILL_SIGNED", { fillTx: "0x01" });
    }).toThrow(IllegalTransitionError);
    expect(store.get(ID)?.fillTx).toBeNull();
    expect(store.history(ID)).toHaveLength(1);
    store.close();
  });

  it("keeps the journaled fill across a restart (new process, same file)", () => {
    const path = freshPath();
    const first = new SolverStore(path);
    first.discover(ID, DATA, "proof");
    first.transition(ID, "DISCOVERED", "FILL_SIGNED", { fillTx: "0xfeed", fillRaw: "0x02f8" });
    first.setCursor("open", 42);
    first.setFeedStatus("order-1.json", "sent", "0x01", "0x02");
    first.close();

    const second = new SolverStore(path);
    const [active] = second.active();
    expect(active?.orderId).toBe(ID);
    expect(active?.state).toBe("FILL_SIGNED");
    expect(active?.fillRaw).toBe("0x02f8");
    expect(second.cursor("open")).toBe(42);
    expect(second.feedStatus("order-1.json")).toEqual({ status: "sent", tx: "0x01", raw: "0x02" });
    second.close();
  });

  it("excludes terminal orders from the active set", () => {
    const store = new SolverStore(freshPath());
    store.discover(ID, DATA, "mailbox");
    store.discover(`0x${"22".repeat(32)}`, DATA, "mailbox");
    store.transition(ID, "DISCOVERED", "EXPIRED");
    expect(store.active().map((o) => o.orderId)).toEqual([`0x${"22".repeat(32)}`]);
    expect(store.all()).toHaveLength(2);
    store.close();
  });
});
