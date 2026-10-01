// SPDX-License-Identifier: MIT
// Unit tests of the Solver's journal, nonce and recovery logic on fake chains (test/fakechain.ts), with faults
// injected at the node: broadcasts that fail, a mempool that loses transactions, a nonce taken by another
// transaction, a report the messaging layer never delivers, false claims next to ours.
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  type Hex,
  TransactionReceiptNotFoundError,
  decodeFunctionData,
  encodeFunctionData,
  erc20Abi,
  keccak256,
  maxUint256,
  parseEther,
  parseTransaction,
} from "viem";
import { afterEach, describe, expect, it } from "vitest";

import { destinationSettlerAbi, mockMailboxAbi, optimisticSettlementModuleAbi } from "../src/abi.ts";
import { silentLogger } from "../src/log.ts";
import { MailboxRelayer } from "../src/relayers.ts";
import { Solver } from "../src/solver.ts";
import { SolverStore } from "../src/store.ts";
import { signCall } from "../src/tx.ts";
import { A, FakeWorld, addressOf, keyOf } from "./fakeworld.ts";

const SOLVER = keyOf("solver");
const REPAYMENT = addressOf("repayment");

const dirs: string[] = [];
const stores: SolverStore[] = [];
afterEach(() => {
  for (const store of stores.splice(0)) {
    try {
      store.close();
    } catch {
      // already closed by the test
    }
  }
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

function setup(options: { output?: bigint; recheck?: number } = {}) {
  const world = new FakeWorld();
  const me = addressOf("solver");
  world.outputToken.state.balances[me.toLowerCase()] = options.output ?? parseEther("100000");
  const dir = mkdtempSync(join(tmpdir(), "solver-unit-"));
  dirs.push(dir);
  const dbPath = join(dir, "solver.db");
  const store = new SolverStore(dbPath);
  stores.push(store);
  const make = (s: SolverStore) =>
    new Solver({
      config: world.config(REPAYMENT, dbPath, options.recheck === undefined ? {} : { mailboxRecheckSec: options.recheck }),
      origin: world.origin.clients(),
      dest: world.dest.clients(),
      originWallet: world.origin.wallet(SOLVER),
      destWallet: world.dest.wallet(SOLVER),
      store: s,
      log: silentLogger,
    });
  return { world, store, solver: make(store), make, dbPath };
}

function isFill(raw: Hex): boolean {
  const tx = parseTransaction(raw);
  if (tx.to?.toLowerCase() !== A.destinationSettler.toLowerCase() || tx.data === undefined) return false;
  return decodeFunctionData({ abi: destinationSettlerAbi, data: tx.data }).functionName === "fillWithRepayment";
}

/** Fails the first broadcast of each fill (a crash or an RPC error between journaling and broadcasting). */
function failFirstBroadcastOfEachFill(world: FakeWorld): void {
  const seen = new Set<Hex>();
  world.dest.failWhen = (raw) => {
    if (!isFill(raw) || seen.has(keccak256(raw))) return false;
    seen.add(keccak256(raw));
    return true;
  };
}

describe("Solver: journal-assigned nonces", () => {
  it("two active orders: a fill journaled but never broadcast keeps its nonce, the next fill takes the next one", async () => {
    const { world, store, solver } = setup();
    const a = world.open({ mode: "mailbox" });
    const b = world.open({ mode: "mailbox" });
    let failures = 0;
    world.dest.failWhen = (raw) => isFill(raw) && failures++ === 0; // only A's first broadcast fails

    await solver.tick();
    const rowA = store.get(a.orderId);
    const rowB = store.get(b.orderId);
    expect(rowA?.state).toBe("FILL_SIGNED");
    expect(rowB?.state).toBe("FILL_SENT");
    const txA = store.tx(rowA?.fillTx ?? "0x");
    const txB = store.tx(rowB?.fillTx ?? "0x");
    expect(txB?.nonce).toBe((txA?.nonce ?? -2) + 1); // B did not take A's nonce
    // B sits behind A's nonce gap in the node; nothing filled yet.
    expect(world.fills.state.records[b.orderId]).toBeUndefined();

    await solver.tick(); // the journal flush re-sends A first; A and then B are mined
    expect(world.dest.statusOf(txA?.hash ?? "0x")).toBe("success");
    expect(world.dest.statusOf(txB?.hash ?? "0x")).toBe("success");
    expect(store.get(a.orderId)?.state).toBe("FILLED");
    expect(store.get(b.orderId)?.state).toBe("FILLED");
    expect(world.fills.state.records[a.orderId]?.filler).toBe(REPAYMENT);
    expect(world.fills.state.records[b.orderId]?.filler).toBe(REPAYMENT);
  });

  it("restart: a new process on the same journal re-sends the journaled fill before signing anything new", async () => {
    const { world, store, make, dbPath } = setup();
    const a = world.open({ mode: "mailbox" });
    failFirstBroadcastOfEachFill(world);
    await make(store).tick();
    const journaled = store.get(a.orderId)?.fillTx;
    expect(store.get(a.orderId)?.state).toBe("FILL_SIGNED");
    store.close(); // the process dies

    const b = world.open({ mode: "mailbox" });
    const reopened = new SolverStore(dbPath);
    stores.push(reopened);
    const restarted = make(reopened);
    await restarted.tick();
    await restarted.tick();
    expect(reopened.history(a.orderId).map((t) => t.to)).toContain("FILLED");
    expect(reopened.get(a.orderId)?.fillTx).toBe(journaled);
    expect(world.dest.statusOf(journaled ?? "0x")).toBe("success");
    expect(["FILL_SENT", "FILLED"]).toContain(reopened.get(b.orderId)?.state);
  });

  it("a fill whose nonce was taken by another transaction is marked replaced and re-signed with a fresh nonce", async () => {
    const { world, store, solver } = setup();
    const a = world.open({ mode: "mailbox" });
    let failures = 0;
    world.dest.failWhen = (raw) => isFill(raw) && failures++ === 0; // only the first fill's broadcast fails
    await solver.tick();
    const first = store.get(a.orderId);
    expect(first?.state).toBe("FILL_SIGNED");
    const firstTx = store.tx(first?.fillTx ?? "0x");

    // Something outside the journal (an operator, another tool with the same key) uses that nonce.
    const wallet = world.dest.wallet(SOLVER);
    const other = await signCall(
      wallet,
      { to: A.outputToken, data: encodeFunctionData({ abi: erc20Abi, functionName: "approve", args: [A.reporter, 1n] }) },
      firstTx?.nonce,
    );
    await world.dest.clients().public.sendRawTransaction({ serializedTransaction: other.raw });
    expect(world.dest.nonceOf(addressOf("solver"))).toBe((firstTx?.nonce ?? 0) + 1);

    await solver.tick(); // flush: "nonce too low" and no receipt -> replaced; the order goes back to DISCOVERED
    expect(store.tx(firstTx?.hash ?? "0x")?.status).toBe("replaced");
    expect(store.get(a.orderId)?.state).toBe("DISCOVERED");
    await solver.tick(); // re-evaluated and re-signed
    await solver.tick();
    const final = store.get(a.orderId);
    expect(final?.state).toBe("FILLED");
    expect(final?.fillTx).not.toBe(firstTx?.hash);
    expect(store.tx(final?.fillTx ?? "0x")?.nonce).toBe((firstTx?.nonce ?? 0) + 1);
    expect(store.history(a.orderId).map((t) => t.to)).toEqual(["FILL_SIGNED", "DISCOVERED", "FILL_SIGNED", "FILL_SENT", "FILLED"]);
  });

  it("a fill that is never mined expires at the fill deadline, releases its output, and its nonce is still consumed", async () => {
    const { world, store, solver } = setup({ output: parseEther("1000") }); // inventory for one order only
    world.outputToken.state.allowances[`${addressOf("solver").toLowerCase()}:${A.destinationSettler.toLowerCase()}`] =
      maxUint256;
    world.dest.blackHole = true; // the node accepts transactions and loses them
    const a = world.open({ mode: "mailbox", fillWindow: 120n });
    await solver.tick();
    expect(store.get(a.orderId)?.state).toBe("FILL_SENT");
    const lost = store.get(a.orderId)?.fillTx ?? "0x";

    const b = world.open({ mode: "mailbox" });
    await solver.tick();
    expect(store.get(b.orderId)?.state).toBe("SKIPPED"); // A's pending fill still reserves the inventory
    expect(store.get(b.orderId)?.reason).toBe("inventory");

    world.dest.advance(200n); // past A's fill deadline
    await solver.tick();
    expect(store.get(a.orderId)?.state).toBe("EXPIRED");
    expect(store.get(a.orderId)?.reason).toBe("fill not mined before the fill deadline");
    expect(store.tx(lost)?.status).toBe("pending"); // still journaled: it must consume its nonce

    world.dest.blackHole = false;
    const c = world.open({ mode: "mailbox" });
    await solver.tick(); // the flush re-sends A (it reverts: too late), then C is filled with the next nonce
    await solver.tick();
    expect(world.dest.statusOf(lost)).toBe("reverted");
    expect(store.tx(lost)?.status).toBe("mined");
    expect(store.get(c.orderId)?.state).toBe("FILLED");
  });

  it("a fill mined before the deadline whose receipt is seen only after it is recorded as FILLED, not given up", async () => {
    const { world, store, dbPath } = setup();
    world.outputToken.state.allowances[`${addressOf("solver").toLowerCase()}:${A.destinationSettler.toLowerCase()}`] =
      maxUint256;
    const real = world.dest.clients();
    const fill: { tx: Hex | null | undefined } = { tx: undefined };
    let lookups = 0;
    // The node misses the fill's receipt exactly once, right after the journal flush saw it: the race between
    // trackFill's receipt lookup and its deadline check.
    const getTransactionReceipt: typeof real.public.getTransactionReceipt = async (args) => {
      if (args.hash === fill.tx && ++lookups === 2) throw new TransactionReceiptNotFoundError({ hash: args.hash });
      return real.public.getTransactionReceipt(args);
    };
    const solver = new Solver({
      config: world.config(REPAYMENT, dbPath),
      origin: world.origin.clients(),
      dest: { ...real, public: { ...real.public, getTransactionReceipt } },
      originWallet: world.origin.wallet(SOLVER),
      destWallet: world.dest.wallet(SOLVER),
      store,
      log: silentLogger,
    });
    const a = world.open({ mode: "mailbox", fillWindow: 120n });
    await solver.tick(); // the fake node mines the fill at once, well before the deadline
    expect(store.get(a.orderId)?.state).toBe("FILL_SENT");
    fill.tx = store.get(a.orderId)?.fillTx;
    expect(world.dest.statusOf(fill.tx ?? "0x")).toBe("success");

    world.dest.advance(200n); // past the fill deadline
    await solver.tick(); // the receipt lookup misses, the deadline has passed and the record is ours: not LOST
    expect(store.get(a.orderId)?.state).toBe("FILL_SENT");
    await solver.tick();
    expect(store.get(a.orderId)?.state).toBe("FILLED");
  });
});

describe("Solver: settlement recovery", () => {
  it("mailbox: a report the messaging layer never delivers is sent again after mailboxRecheckSec", async () => {
    const { world, store, solver } = setup({ recheck: 100 });
    const a = world.open({ mode: "mailbox" });
    for (let i = 0; i < 4; i++) await solver.tick();
    expect(store.get(a.orderId)?.state).toBe("AWAITING_REPAYMENT");
    const recheckAt = store.get(a.orderId)?.recheckAt ?? 0;
    expect(recheckAt).toBeGreaterThan(Number(world.origin.time));

    await solver.tick();
    expect(store.get(a.orderId)?.state).toBe("AWAITING_REPAYMENT"); // too early to report again
    world.origin.advance(150n);
    await solver.tick();
    expect(store.get(a.orderId)?.state).toBe("SETTLE_SENT");
    await solver.tick();
    expect(store.get(a.orderId)?.state).toBe("AWAITING_REPAYMENT");
    expect(world.reporter.state.nonce).toBe(2n); // two reports dispatched

    // The relayer delivers one; the other is rejected by the origin chain (order no longer open) and skipped.
    const mailboxStore = new SolverStore(":memory:");
    const relayer = new MailboxRelayer({
      origin: world.origin.clients(),
      dest: world.dest.clients(),
      wallet: world.origin.wallet(keyOf("relayer")),
      destMailbox: A.destMailbox,
      originMailbox: A.originMailbox,
      store: mailboxStore,
      log: silentLogger,
    });
    expect(await relayer.tick()).toHaveLength(1);
    expect(mailboxStore.cursor("dispatch")).toBe(Number(world.dest.blockNumber) + 1);
    await solver.tick();
    expect(store.get(a.orderId)?.state).toBe("SETTLED");
    mailboxStore.close();
  });

  it("optimistic: a false claim already pending on the order does not stop our claim, which is finalized", async () => {
    const { world, store, solver } = setup();
    const a = world.open({ mode: "optimistic" });
    world.bondToken.state.allowances[`${addressOf("solver").toLowerCase()}:${A.optimisticModule.toLowerCase()}`] = maxUint256;
    await solver.tick();
    await solver.tick();
    expect(store.get(a.orderId)?.state).toBe("FILLED");

    // The user squats the order with a false claim before the solver claims.
    const squatter = world.origin.wallet(keyOf("user"));
    const squat = await signCall(squatter, {
      to: A.optimisticModule,
      data: encodeFunctionData({
        abi: optimisticSettlementModuleAbi,
        functionName: "claim",
        args: [a.orderId, addressOf("user"), world.origin.time, keccak256(a.originData)],
      }),
    });
    await world.origin.clients().public.sendRawTransaction({ serializedTransaction: squat.raw });
    expect(Object.keys(world.optimistic.state.claims)).toHaveLength(1);

    await solver.tick(); // our claim lands next to it
    await solver.tick();
    expect(store.get(a.orderId)?.state).toBe("AWAITING_REPAYMENT");
    expect(Object.keys(world.optimistic.state.claims)).toHaveLength(2);

    world.origin.advance(400n);
    await solver.tick(); // finalize our claim
    await solver.tick();
    expect(store.get(a.orderId)?.state).toBe("SETTLED");
    expect(world.escrows.state.escrows[a.orderId]?.status).toBe(2);
  });

  it("optimistic: when exactly our claim was already posted by someone else, the solver waits for it without a bond", async () => {
    const { world, store, solver } = setup();
    const a = world.open({ mode: "optimistic" });
    await solver.tick();
    await solver.tick();
    const filledAt = BigInt(store.get(a.orderId)?.filledAt ?? 0);
    const helper = world.origin.wallet(keyOf("helper"));
    const claim = await signCall(helper, {
      to: A.optimisticModule,
      data: encodeFunctionData({
        abi: optimisticSettlementModuleAbi,
        functionName: "claim",
        args: [a.orderId, REPAYMENT, filledAt, keccak256(a.originData)],
      }),
    });
    await world.origin.clients().public.sendRawTransaction({ serializedTransaction: claim.raw });

    await solver.tick();
    const row = store.get(a.orderId);
    expect(row?.state).toBe("AWAITING_REPAYMENT");
    expect(row?.reason).toBe("our claim was already posted by someone else");
    expect(row?.settleTx).toBeNull(); // no transaction of ours
    world.origin.advance(400n);
    await solver.tick();
    await solver.tick();
    expect(store.get(a.orderId)?.state).toBe("SETTLED");
  });
});

describe("MailboxRelayer", () => {
  function relayer(world: FakeWorld, store: SolverStore) {
    return new MailboxRelayer({
      origin: world.origin.clients(),
      dest: world.dest.clients(),
      wallet: world.origin.wallet(keyOf("relayer")),
      destMailbox: A.destMailbox,
      originMailbox: A.originMailbox,
      store,
      log: silentLogger,
    });
  }

  async function reportedOrder(world: FakeWorld): Promise<Hex> {
    const { solver, store } = setupOn(world);
    const a = world.open({ mode: "mailbox" });
    for (let i = 0; i < 4; i++) await solver.tick();
    expect(store.get(a.orderId)?.state).toBe("AWAITING_REPAYMENT");
    return a.orderId;
  }

  function setupOn(world: FakeWorld) {
    world.outputToken.state.balances[addressOf("solver").toLowerCase()] = parseEther("100000");
    const store = new SolverStore(":memory:");
    const solver = new Solver({
      config: world.config(REPAYMENT, ":memory:"),
      origin: world.origin.clients(),
      dest: world.dest.clients(),
      originWallet: world.origin.wallet(SOLVER),
      destWallet: world.dest.wallet(SOLVER),
      store,
      log: silentLogger,
    });
    return { solver, store };
  }

  it("keeps the cursor on a message whose delivery failed for a transient reason, and delivers it next tick", async () => {
    const world = new FakeWorld();
    const orderId = await reportedOrder(world);
    const store = new SolverStore(":memory:");
    world.origin.failBroadcasts = 1; // the process transaction's broadcast fails once (connection reset)
    expect(await relayer(world, store).tick()).toHaveLength(0);
    expect(world.escrows.state.escrows[orderId]?.status).toBe(1);
    expect(store.cursor("dispatch")).toBeLessThanOrEqual(Number(world.dest.blockNumber)); // not moved past it

    expect(await relayer(world, store).tick()).toHaveLength(1);
    expect(world.escrows.state.escrows[orderId]?.status).toBe(2);
    expect(store.cursor("dispatch")).toBe(Number(world.dest.blockNumber) + 1);
    store.close();
  });

  it("moves the cursor past a message the origin chain rejects (the order was refunded)", async () => {
    const world = new FakeWorld();
    const orderId = await reportedOrder(world);
    world.refund(orderId);
    const store = new SolverStore(":memory:");
    expect(await relayer(world, store).tick()).toHaveLength(0);
    expect(store.cursor("dispatch")).toBe(Number(world.dest.blockNumber) + 1);
    const processed = world.origin.received.filter((raw) => {
      const tx = parseTransaction(raw);
      return tx.to?.toLowerCase() === A.originMailbox.toLowerCase() && tx.data !== undefined &&
        decodeFunctionData({ abi: mockMailboxAbi, data: tx.data }).functionName === "process";
    });
    expect(processed).toHaveLength(0); // rejected at simulation: no transaction was even sent
    store.close();
  });
});
