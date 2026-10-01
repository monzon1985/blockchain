// SPDX-License-Identifier: MIT
// The Solver's less travelled paths on fake chains: the gasless feed, malformed or unsupported Open events, orders
// lost to other fillers, settlement transactions that are replaced, escrows closed by someone else.
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { encodeFunctionData, erc20Abi, keccak256, maxUint256, parseEther, parseTransaction } from "viem";
import { afterEach, describe, expect, it } from "vitest";

import { originSettlerAbi } from "../src/abi.ts";
import { silentLogger } from "../src/log.ts";
import { type FeedEntry, Solver } from "../src/solver.ts";
import { SolverStore } from "../src/store.ts";
import { signCall } from "../src/tx.ts";
import { A, FakeWorld, addressOf, keyOf } from "./fakeworld.ts";

const SOLVER = keyOf("solver");
const REPAYMENT = addressOf("repayment");
const dirs: string[] = [];
const stores: SolverStore[] = [];
afterEach(() => {
  for (const store of stores.splice(0)) store.close();
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

function setup(withFeed = false) {
  const world = new FakeWorld();
  world.outputToken.state.balances[addressOf("solver").toLowerCase()] = parseEther("100000");
  const dir = mkdtempSync(join(tmpdir(), "solver-paths-"));
  dirs.push(dir);
  const feedDir = join(dir, "feed");
  mkdirSync(feedDir);
  const store = new SolverStore(":memory:");
  stores.push(store);
  const solver = new Solver({
    config: world.config(REPAYMENT, ":memory:", withFeed ? { feedDir } : {}),
    origin: world.origin.clients(),
    dest: world.dest.clients(),
    originWallet: world.origin.wallet(SOLVER),
    destWallet: world.dest.wallet(SOLVER),
    store,
    log: silentLogger,
  });
  return { world, store, solver, feedDir };
}

function feed(dir: string, name: string, order: ReturnType<FakeWorld["gasless"]>): void {
  const entry: FeedEntry = {
    order: { ...order, nonce: order.nonce.toString(), originChainId: order.originChainId.toString() },
    signature: "0x",
  };
  writeFileSync(join(dir, name), JSON.stringify(entry));
}

describe("Solver: gasless feed", () => {
  it("opens a profitable feed order through the journal and records the outcome", async () => {
    const { world, store, solver, feedDir } = setup(true);
    feed(feedDir, "a.json", world.gasless({ mode: "mailbox" }, 1n));
    await solver.tick();
    expect(store.feedStatus("a.json")?.status).toBe("sent");
    expect(store.pendingTxs(1001, addressOf("solver")).map((t) => t.purpose)).toEqual(["open"]);
    await solver.tick();
    expect(store.feedStatus("a.json")?.status).toBe("opened");
    expect(store.all()).toHaveLength(1); // discovered from its Open event
  });

  it("skips unsupported, already opened and unprofitable feed orders", async () => {
    const { world, store, solver, feedDir } = setup(true);
    feed(feedDir, "unsupported.json", world.gasless({ mode: "mailbox", module: "0x00000000000000000000000000000000000000ee" }, 1n));
    const taken = world.gasless({ mode: "mailbox" }, 2n);
    feed(feedDir, "taken.json", taken);
    await world.origin.clients().public.sendRawTransaction({
      serializedTransaction: (
        await signCall(world.origin.wallet(keyOf("other")), {
          to: A.originSettler,
          data: encodeFunctionData({
            abi: originSettlerAbi,
            functionName: "openFor",
            args: [taken, "0x", "0x"],
          }),
        })
      ).raw,
    });
    feed(feedDir, "cheap.json", world.gasless({ mode: "mailbox", outputStart: parseEther("1000"), outputEnd: parseEther("1000") }, 3n));
    await solver.tick();
    expect(store.feedStatus("unsupported.json")?.status).toBe("unsupported");
    expect(store.feedStatus("taken.json")?.status).toBe("opened-elsewhere");
    expect(store.feedStatus("cheap.json")?.status).toBe("skipped:unprofitable");
  });

  it("forgets a feed order whose openFor was replaced, so it is evaluated again", async () => {
    const { world, store, solver, feedDir } = setup(true);
    feed(feedDir, "a.json", world.gasless({ mode: "mailbox" }, 1n));
    let failed = false;
    world.origin.failWhen = (raw) => {
      const isOpen = parseTransaction(raw).to?.toLowerCase() === A.originSettler.toLowerCase();
      if (!isOpen || failed) return false;
      failed = true;
      return true;
    };
    await expect(solver.tick()).rejects.toThrow(); // the broadcast fails; the entry stays "sent"
    const sent = store.feedStatus("a.json");
    expect(sent?.status).toBe("sent");
    const nonce = store.tx(sent?.tx ?? "0x")?.nonce;
    // Another transaction of the same key takes that nonce.
    const other = await signCall(
      world.origin.wallet(SOLVER),
      { to: A.bondToken, data: encodeFunctionData({ abi: erc20Abi, functionName: "approve", args: [A.reporter, 1n] }) },
      nonce,
    );
    await world.origin.clients().public.sendRawTransaction({ serializedTransaction: other.raw });
    await solver.tick(); // replaced -> forgotten
    expect(store.feedStatus("a.json")).toBeUndefined();
    await solver.tick(); // evaluated and opened again
    await solver.tick();
    expect(store.feedStatus("a.json")?.status).toBe("opened");
  });
});

describe("Solver: discovery and evaluation", () => {
  it("ignores an Open event whose originData does not hash to its id, and skips unsupported destinations", async () => {
    const { world, store, solver } = setup();
    const real = world.open({ mode: "mailbox" });
    world.emitOpen(keccak256("0x1234"), real.originData);
    const elsewhere = world.open({ mode: "mailbox", destinationSettler: "0x00000000000000000000000000000000000000dd" });
    await solver.tick();
    expect(store.get(keccak256("0x1234"))).toBeUndefined();
    expect(store.get(elsewhere.orderId)?.state).toBe("SKIPPED");
    expect(store.get(elsewhere.orderId)?.reason).toBe("unsupported");
  });

  it("waits out someone else's exclusivity window, and loses an order another solver filled first", async () => {
    const { world, store, solver } = setup();
    const exclusive = world.open({ mode: "mailbox", exclusiveFiller: addressOf("other-solver"), exclusivityWindow: 60n });
    await solver.tick();
    expect(store.get(exclusive.orderId)?.state).toBe("WAITING");
    world.fills.state.records[exclusive.orderId] = {
      filler: addressOf("other-repayment"),
      filledAt: world.dest.time,
      fillHash: keccak256(exclusive.originData),
    };
    await solver.tick();
    expect(store.get(exclusive.orderId)?.state).toBe("LOST");
    expect(store.get(exclusive.orderId)?.reason).toBe("filled by another solver");
  });

  it("a replaced fill of an order someone else filled meanwhile is LOST", async () => {
    const { world, store, solver } = setup();
    const a = world.open({ mode: "mailbox" });
    let failures = 0;
    world.dest.failWhen = (raw) => parseTransaction(raw).to?.toLowerCase() === A.destinationSettler.toLowerCase() && failures++ === 0;
    await solver.tick();
    const nonce = store.tx(store.get(a.orderId)?.fillTx ?? "0x")?.nonce;
    const other = await signCall(
      world.dest.wallet(SOLVER),
      { to: A.outputToken, data: encodeFunctionData({ abi: erc20Abi, functionName: "approve", args: [A.reporter, 1n] }) },
      nonce,
    );
    await world.dest.clients().public.sendRawTransaction({ serializedTransaction: other.raw });
    world.fills.state.records[a.orderId] = { filler: addressOf("x"), filledAt: world.dest.time, fillHash: keccak256(a.originData) };
    await solver.tick();
    expect(store.get(a.orderId)?.state).toBe("LOST");
    expect(store.get(a.orderId)?.reason).toBe("fill replaced; filled by someone else");
  });
});

describe("Solver: settlement edge cases", () => {
  it("a replaced settlement transaction sends the order back to FILLED, and it is settled again", async () => {
    const { world, store, solver } = setup();
    const a = world.open({ mode: "mailbox" });
    await solver.tick();
    await solver.tick();
    expect(store.get(a.orderId)?.state).toBe("FILLED");
    let failures = 0;
    world.dest.failWhen = (raw) => parseTransaction(raw).to?.toLowerCase() === A.reporter.toLowerCase() && failures++ === 0;
    await solver.tick(); // report journaled, broadcast fails
    const row = store.get(a.orderId);
    expect(row?.state).toBe("SETTLE_SENT");
    const nonce = store.tx(row?.settleTx ?? "0x")?.nonce;
    const other = await signCall(
      world.dest.wallet(SOLVER),
      { to: A.outputToken, data: encodeFunctionData({ abi: erc20Abi, functionName: "approve", args: [A.reporter, 1n] }) },
      nonce,
    );
    await world.dest.clients().public.sendRawTransaction({ serializedTransaction: other.raw });
    await solver.tick();
    expect(store.get(a.orderId)?.state).toBe("FILLED");
    expect(store.get(a.orderId)?.reason).toBe("report transaction replaced");
    await solver.tick();
    await solver.tick();
    expect(store.get(a.orderId)?.state).toBe("AWAITING_REPAYMENT");
  });

  it("an escrow repaid to someone else is LOST, and a refunded one too", async () => {
    const { world, store, solver } = setup();
    const repaidElsewhere = world.open({ mode: "mailbox" });
    const refunded = world.open({ mode: "mailbox" });
    for (let i = 0; i < 4; i++) await solver.tick();
    expect(store.get(repaidElsewhere.orderId)?.state).toBe("AWAITING_REPAYMENT");
    world.repay(repaidElsewhere.orderId, addressOf("impostor"));
    world.refund(refunded.orderId);
    await solver.tick();
    expect(store.get(repaidElsewhere.orderId)?.state).toBe("LOST");
    expect(store.get(repaidElsewhere.orderId)?.reason).toBe(`escrow repaid to ${addressOf("impostor")}`);
    expect(store.get(refunded.orderId)?.state).toBe("LOST");
    expect(store.get(refunded.orderId)?.reason).toBe("escrow refunded");
  });

  it("starts over when its optimistic claim disappears without repaying it", async () => {
    const { world, store, solver } = setup();
    world.bondToken.state.allowances[`${addressOf("solver").toLowerCase()}:${A.optimisticModule.toLowerCase()}`] = maxUint256;
    const a = world.open({ mode: "optimistic" });
    for (let i = 0; i < 4; i++) await solver.tick();
    expect(store.get(a.orderId)?.state).toBe("AWAITING_REPAYMENT");
    world.optimistic.state.claims = {}; // resolved by someone else without closing the order
    await solver.tick();
    expect(store.get(a.orderId)?.state).toBe("FILLED");
    expect(store.get(a.orderId)?.reason).toBe("claim resolved");
  });
});
