// SPDX-License-Identifier: MIT
// End-to-end on two real anvil chains (origin 1001, destination 1002): the contracts from the Foundry artifacts,
// the solver, the header relayer, the mailbox relayer and the watchtower, all talking JSON-RPC.
// Crash tests run the solver as a child process: e2e/crash-solver.ts (the production actor plus a kill switch) for
// the run that dies, src/main.ts for the restart.
import { type ChildProcess, spawn } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { type Address, type Hex, parseEther } from "viem";
import { afterAll, beforeAll, describe, expect, it } from "vitest";

import { destinationSettlerAbi, mailboxFillReporterAbi, resolverAdapterAbi } from "../src/abi.ts";
import { walletFor } from "../src/chains.ts";
import { type SolverConfig, stringifyConfig } from "../src/config.ts";
import { silentLogger } from "../src/log.ts";
import { encodeResolverPayload } from "../src/orders.ts";
import type { PricingConfig } from "../src/pricing.ts";
import { HeaderRelayer, MailboxRelayer } from "../src/relayers.ts";
import { EscrowStatus, type FeedEntry, Solver } from "../src/solver.ts";
import { SolverStore } from "../src/store.ts";
import { type Verdict, Watchtower, claimIdOf } from "../src/watchtower.ts";
import {
  type Mode,
  type OrderTerms,
  balanceOf,
  challengeAt,
  escrowStatus,
  encodeRepayment,
  fraudulentClaim,
  importAncestors,
  mint,
  openOnchain,
  prepareFiller,
  refund,
  signGasless,
} from "../scripts/actions.ts";
import { type Actor, type Localnet, advanceTime, fund, mineDest, newActor, startLocalnet } from "../scripts/localnet.ts";

const solverDir = join(dirname(fileURLToPath(import.meta.url)), "..");

let net: Localnet;
let workdir: string;
let feedDir: string;
const user = newActor();
const solverKey = newActor();
const repayment = newActor();
const watcherKey = newActor();
const attacker = newActor();
const recipient = newActor();

let store: SolverStore;
let mailboxStore: SolverStore;
let solver: Solver;
let headerRelayer: HeaderRelayer;
let mailboxRelayer: MailboxRelayer;
let watchtower: Watchtower;

function pricing(): PricingConfig {
  return {
    tokenPrices: { [net.inputToken.toLowerCase()]: 1n, [net.outputToken.toLowerCase()]: 1n },
    nativePriceOrigin: 3000n,
    nativePriceDest: 3000n,
    gas: { open: 250_000n, fill: 150_000n, settle: { mailbox: 100_000n, optimistic: 300_000n, proof: 350_000n } },
    capitalCostBpsPerHour: 1n,
    modeRiskBps: { mailbox: 5n, optimistic: 10n, proof: 2n },
    settlementDelaySec: { mailbox: 60n, optimistic: net.challengeWindow, proof: 30n },
    settlementLatencySec: { mailbox: 60n, optimistic: 30n, proof: 60n },
    minProfit: parseEther("1"),
    fillSafetyMarginSec: 5n,
  };
}

function solverConfig(repaymentAddress: Address, dbPath: string, feed?: string): SolverConfig {
  return {
    deployment: net.deployment,
    repaymentAddress,
    dbPath,
    ...(feed === undefined ? {} : { feedDir: feed }),
    pollIntervalMs: 150,
    pricing: pricing(),
  };
}

function terms(mode: Mode, overrides: Partial<OrderTerms> = {}): OrderTerms {
  return {
    mode,
    inputAmount: parseEther("1000"),
    outputStart: parseEther("995"),
    outputEnd: parseEther("990"),
    recipient: recipient.address,
    fillWindow: 900n,
    exclusivityWindow: 30n,
    ...overrides,
  };
}

/** Orders no solver will take: they pay nothing for the output. */
function unprofitable(mode: Mode, overrides: Partial<OrderTerms> = {}): OrderTerms {
  return terms(mode, { outputStart: parseEther("1000"), outputEnd: parseEther("1000"), ...overrides });
}

type Tickable = { tick: () => Promise<unknown> };

/** Ticks `actors` round-robin until `done()` holds. */
async function until(done: () => Promise<boolean>, actors: Tickable[], label: string, rounds = 120): Promise<void> {
  for (let i = 0; i < rounds; i++) {
    if (await done()) return;
    for (const actor of actors) await actor.tick();
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  if (!(await done())) throw new Error(`timed out waiting for: ${label}`);
}

const repaid = (orderId: Hex) => async () => (await escrowStatus(net, orderId)) === EscrowStatus.Repaid;

async function fillEvents(orderId: Hex) {
  return net.dest.public.getContractEvents({
    address: net.deployment.destination.destinationSettler,
    abi: destinationSettlerAbi,
    eventName: "OrderFilled",
    args: { orderId },
    fromBlock: 0n,
    toBlock: "latest",
  });
}

beforeAll(async () => {
  net = await startLocalnet({ refundGrace: 600n, challengeWindow: 300n });
  workdir = mkdtempSync(join(tmpdir(), "intents-e2e-"));
  feedDir = join(workdir, "feed");
  mkdirSync(feedDir);

  await fund(net, [user.address, solverKey.address, watcherKey.address, attacker.address]);
  await mint(net, "dest", net.outputToken, solverKey.address, parseEther("100000"));
  await mint(net, "origin", net.deployment.origin.bondToken, solverKey.address, parseEther("1000"));

  store = new SolverStore(join(workdir, "solver.db"));
  mailboxStore = new SolverStore(join(workdir, "mailbox.db"));
  solver = new Solver({
    config: solverConfig(repayment.address, join(workdir, "solver.db"), feedDir),
    origin: net.origin,
    dest: net.dest,
    originWallet: walletFor(net.origin, solverKey.key),
    destWallet: walletFor(net.dest, solverKey.key),
    store,
    log: silentLogger,
  });
  headerRelayer = new HeaderRelayer({
    origin: net.origin,
    dest: net.dest,
    wallet: walletFor(net.origin, net.relayer.key),
    headerStore: net.deployment.origin.headerStore,
    log: silentLogger,
  });
  mailboxRelayer = new MailboxRelayer({
    origin: net.origin,
    dest: net.dest,
    wallet: walletFor(net.origin, net.relayer.key),
    destMailbox: net.deployment.destination.mailbox,
    originMailbox: net.deployment.origin.mailbox,
    store: mailboxStore,
    log: silentLogger,
  });
  watchtower = new Watchtower({
    origin: net.origin,
    dest: net.dest,
    wallet: walletFor(net.origin, watcherKey.key),
    originSettler: net.deployment.origin.originSettler,
    optimisticModule: net.deployment.origin.optimisticModule,
    headerStore: net.deployment.origin.headerStore,
    destinationSettler: net.deployment.destination.destinationSettler,
    log: silentLogger,
  });
});

afterAll(() => {
  store.close();
  mailboxStore.close();
  net.stop();
  rmSync(workdir, { recursive: true, force: true });
});

describe("two-chain intents e2e", () => {
  it("happy path: gasless order via Permit2, filled on 1002, repaid on 1001 through the mailbox", async () => {
    const t = terms("mailbox");
    const signed = await signGasless(net, user, t, 1n);

    // The resolver-centric view of the same signed order, by eth_call on the origin chain.
    const resolved = await net.origin.public.readContract({
      address: net.adapter,
      abi: resolverAdapterAbi,
      functionName: "resolve",
      args: [encodeResolverPayload(signed.order, signed.signature)],
    });
    expect(resolved.steps).toHaveLength(3);

    const entry: FeedEntry = {
      order: { ...signed.order, nonce: signed.order.nonce.toString(), originChainId: signed.order.originChainId.toString() },
      signature: signed.signature,
    };
    writeFileSync(join(feedDir, "order-1.json"), JSON.stringify(entry));

    const before = await balanceOf(net, "dest", net.outputToken, recipient.address);
    await until(repaid(signed.orderId), [solver, mailboxRelayer], "mailbox repayment");

    expect((await balanceOf(net, "dest", net.outputToken, recipient.address)) - before).toBeGreaterThanOrEqual(t.outputEnd);
    expect(await balanceOf(net, "origin", net.inputToken, repayment.address)).toBe(t.inputAmount);
    expect(store.feedStatus("order-1.json")?.status).toBe("opened");
    const row = store.get(signed.orderId);
    expect(row?.state).toBe("AWAITING_REPAYMENT"); // repaid on-chain; the solver notices on its next tick
    await solver.tick();
    expect(store.get(signed.orderId)?.state).toBe("SETTLED");
    expect(store.history(signed.orderId).map((s) => s.to)).toEqual([
      "FILL_SIGNED",
      "FILL_SENT",
      "FILLED",
      "SETTLE_SENT",
      "AWAITING_REPAYMENT",
      "SETTLED",
    ]);
  });

  it("proof-based repayment: the fill record is proven against a relayed 1002 header", async () => {
    const t = terms("proof");
    const { orderId } = await openOnchain(net, user, t);
    const before = await balanceOf(net, "origin", net.inputToken, repayment.address);
    await until(repaid(orderId), [solver, headerRelayer], "proof repayment");
    expect((await balanceOf(net, "origin", net.inputToken, repayment.address)) - before).toBe(t.inputAmount);
    await solver.tick();
    const row = store.get(orderId);
    expect(row?.state).toBe("SETTLED");
    expect(row?.settleKind).toBe("prove");
  });

  it("optimistic repayment: bonded claim, unchallenged window, finalize, bond returned", async () => {
    const t = terms("optimistic");
    const { orderId } = await openOnchain(net, user, t);
    const bondBefore = await balanceOf(net, "origin", net.deployment.origin.bondToken, solverKey.address);
    const verdicts: Verdict[] = [];
    const recordingWatchtower = {
      tick: async () => {
        const v = await watchtower.tick();
        const filledAt = store.get(orderId)?.filledAt;
        if (filledAt === null || filledAt === undefined) return;
        const verdict = v.get(claimIdOf(orderId, repayment.address, BigInt(filledAt)));
        if (verdict !== undefined) verdicts.push(verdict);
      },
    };
    await until(
      () => Promise.resolve(store.get(orderId)?.state === "AWAITING_REPAYMENT"),
      [solver, headerRelayer, recordingWatchtower],
      "claim",
    );
    expect(await balanceOf(net, "origin", net.deployment.origin.bondToken, solverKey.address)).toBe(bondBefore - net.bond);
    await recordingWatchtower.tick();
    expect(verdicts.length).toBeGreaterThan(0);
    expect(verdicts.every((v) => v === "honest")).toBe(true);

    await advanceTime(net, net.challengeWindow + 1n);
    const before = await balanceOf(net, "origin", net.inputToken, repayment.address);
    await until(repaid(orderId), [solver], "finalize");
    expect((await balanceOf(net, "origin", net.inputToken, repayment.address)) - before).toBe(t.inputAmount);
    expect(await balanceOf(net, "origin", net.deployment.origin.bondToken, solverKey.address)).toBe(bondBefore);
  });

  it("fraudulent claim slashed: the watchtower proves non-fill with an exclusion proof and takes the bond", async () => {
    const t = unprofitable("optimistic", { fillWindow: 120n });
    const { orderId, originData } = await openOnchain(net, user, t);
    await solver.tick();
    expect(store.get(orderId)?.state).toBe("SKIPPED");

    const claimedAt = await fraudulentClaim(net, attacker, orderId, originData);
    await mineDest(net, 2n); // a destination block after the claimed fill time
    await headerRelayer.tick();
    const verdicts = await watchtower.tick();
    expect(verdicts.get(claimIdOf(orderId, attacker.address, claimedAt))).toBe("challenged");
    expect(await balanceOf(net, "origin", net.deployment.origin.bondToken, watcherKey.address)).toBe(net.bond);
    expect(await balanceOf(net, "origin", net.deployment.origin.bondToken, attacker.address)).toBe(0n);
    expect(await escrowStatus(net, orderId)).toBe(EscrowStatus.Open);

    // Nobody filled: once the grace period is over the user takes the escrow back.
    await advanceTime(net, t.fillWindow + net.refundGrace + 1n);
    const before = await balanceOf(net, "origin", net.inputToken, user.address);
    await refund(net, user, orderId);
    expect((await balanceOf(net, "origin", net.inputToken, user.address)) - before).toBe(t.inputAmount);
    expect(await escrowStatus(net, orderId)).toBe(EscrowStatus.Refunded);
  });

  it("fraud proofs survive imported pre-deployment ancestors: a filledAt = 0 claim is still slashed", async () => {
    // The attack from the review: the header relayer is honest, but ANYONE can import ancestors of a stored header
    // down to a block where the DestinationSettler did not exist yet, and a false claim may say filledAt = 0.
    const t = unprofitable("optimistic", { fillWindow: 120n });
    const { orderId, originData } = await openOnchain(net, user, t);
    await solver.tick();
    expect(store.get(orderId)?.state).toBe("SKIPPED");
    await mineDest(net, 2n);
    await headerRelayer.tick();
    const ancestorImporter = newActor();
    await fund(net, [ancestorImporter.address]);
    expect(await importAncestors(net, ancestorImporter, 1n)).toBe(1n);

    const squatter = newActor();
    await fund(net, [squatter.address]);
    await fraudulentClaim(net, squatter, orderId, originData, 0n);
    const watcherBefore = await balanceOf(net, "origin", net.deployment.origin.bondToken, watcherKey.address);
    const verdicts = await watchtower.tick(); // proves against the NEWEST header, not block 1
    expect(verdicts.get(claimIdOf(orderId, squatter.address, 0n))).toBe("challenged");
    expect(await balanceOf(net, "origin", net.deployment.origin.bondToken, watcherKey.address)).toBe(
      watcherBefore + net.bond,
    );

    // On-chain, even the oldest header disproves it: anvil's proof at block 1 is an EXCLUSION proof of the settler
    // account, and an account that does not exist has no fill record.
    const second = newActor();
    const challenger = newActor();
    await fund(net, [second.address, challenger.address]);
    await fraudulentClaim(net, second, orderId, originData, 0n);
    await challengeAt(net, challenger, orderId, second.address, 0n, 1n);
    expect(await balanceOf(net, "origin", net.deployment.origin.bondToken, challenger.address)).toBe(net.bond);
    expect(await escrowStatus(net, orderId)).toBe(EscrowStatus.Open);
  });

  it("claim squatting: a false claim by the user, posted first, does not block the solver; the squatter is slashed", async () => {
    const t = terms("optimistic");
    const { orderId, originData } = await openOnchain(net, user, t);
    await until(() => Promise.resolve(store.get(orderId)?.state === "FILLED"), [solver], "fill");
    // Before the solver claims, the user squats its own order with a false claim.
    const squatAt = await fraudulentClaim(net, user, orderId, originData);
    await until(
      () => Promise.resolve(store.get(orderId)?.state === "AWAITING_REPAYMENT"),
      [solver, headerRelayer],
      "solver claim next to the squat",
    );
    await mineDest(net, 2n);
    await headerRelayer.tick();
    const verdicts = await watchtower.tick();
    expect(verdicts.get(claimIdOf(orderId, user.address, squatAt))).toBe("challenged");

    await advanceTime(net, net.challengeWindow + 1n);
    const before = await balanceOf(net, "origin", net.inputToken, repayment.address);
    await until(repaid(orderId), [solver, watchtower], "finalize despite the squat");
    expect((await balanceOf(net, "origin", net.inputToken, repayment.address)) - before).toBe(t.inputAmount);
    await advanceTime(net, t.fillWindow + net.refundGrace);
    await expect(refund(net, user, orderId)).rejects.toThrow();
  });

  it("late fill refund: a fill after the deadline reverts, the user is refunded, nothing can repay", async () => {
    const t = unprofitable("mailbox", { fillWindow: 60n });
    const { orderId, originData } = await openOnchain(net, user, t);
    await advanceTime(net, 61n);
    const lateFiller = newActor();
    await fund(net, [lateFiller.address]);
    await prepareFiller(net, lateFiller);
    await expect(
      net.dest.public.simulateContract({
        account: lateFiller.address,
        address: net.deployment.destination.destinationSettler,
        abi: destinationSettlerAbi,
        functionName: "fill",
        args: [orderId, originData, encodeRepayment(lateFiller.address)],
      }),
    ).rejects.toThrow(/FillDeadlinePassed/);
    await expect(
      net.dest.public.simulateContract({
        account: lateFiller.address,
        address: net.deployment.destination.reporter,
        abi: mailboxFillReporterAbi,
        functionName: "report",
        args: [orderId, 1001n],
      }),
    ).rejects.toThrow(/OrderNotFilled/);

    await advanceTime(net, net.refundGrace);
    const before = await balanceOf(net, "origin", net.inputToken, user.address);
    await refund(net, user, orderId);
    expect((await balanceOf(net, "origin", net.inputToken, user.address)) - before).toBe(t.inputAmount);
    await solver.tick();
    expect(["SKIPPED", "EXPIRED"]).toContain(store.get(orderId)?.state);
  });

  for (const point of ["after-fill-persist", "after-fill-broadcast"] as const) {
    it(`solver crash mid-fill (${point}): restart resumes from the journal, fills once, gets repaid`, async () => {
      const crashSolver = newActor();
      const crashRepayment = newActor();
      await fund(net, [crashSolver.address]);
      await mint(net, "dest", net.outputToken, crashSolver.address, parseEther("100000"));
      const dbPath = join(workdir, `crash-${point}.db`);
      const configPath = join(workdir, `crash-${point}.json`);
      writeFileSync(configPath, stringifyConfig(solverConfig(crashRepayment.address, dbPath)));

      const t = terms("proof");
      const { orderId } = await openOnchain(net, user, t);

      const crashed = await runCrashingSolver(configPath, crashSolver, point);
      expect(crashed.stderr).toContain("crash injected");
      expect(crashed.code === 0, crashed.stderr).toBe(false); // killed, not a clean exit
      const journal = new SolverStore(dbPath);
      const journaled = journal.get(orderId);
      journal.close();
      expect(journaled?.state).toBe(point === "after-fill-persist" ? "FILL_SIGNED" : "FILL_SENT");
      const journaledTx = journaled?.fillTx;
      expect(journaledTx).toMatch(/^0x[0-9a-f]{64}$/);
      if (point === "after-fill-broadcast") {
        // anvil accepted the fill before the kill, but its automine can finish that block a moment after
        // eth_sendRawTransaction returned, so wait for it (no solver is running) instead of racing it.
        await until(async () => (await fillEvents(orderId)).length > 0, [], "the broadcast fill to be mined");
      }
      expect(await fillEvents(orderId)).toHaveLength(point === "after-fill-persist" ? 0 : 1);

      const restarted = startSolver(configPath, crashSolver);
      try {
        await until(repaid(orderId), [headerRelayer], "repayment after restart", 400);
      } finally {
        restarted.kill();
        await new Promise((resolve) => restarted.once("exit", resolve));
      }

      const events = await fillEvents(orderId);
      expect(events).toHaveLength(1);
      expect(events[0]?.transactionHash).toBe(journaledTx);
      expect(await balanceOf(net, "origin", net.inputToken, crashRepayment.address)).toBe(t.inputAmount);
      const after = new SolverStore(dbPath);
      const finalRow = after.get(orderId);
      after.close();
      expect(["AWAITING_REPAYMENT", "SETTLE_SENT", "SETTLED"]).toContain(finalRow?.state);
      expect(finalRow?.fillTx).toBe(journaledTx);
    });
  }

  it("solver crash with two active orders: the journaled fill keeps its nonce, the other order takes the next one", async () => {
    // The scenario of the review: order A waits (exclusive to another filler), order B's fill is journaled and the
    // process dies before broadcasting it. After the restart A becomes fillable first in the loop; with nonces from
    // the node, A's fill would take B's nonce and B's journaled fill would be stuck forever.
    const crashSolver = newActor();
    const crashRepayment = newActor();
    const exclusive = newActor();
    await fund(net, [crashSolver.address]);
    await mint(net, "dest", net.outputToken, crashSolver.address, parseEther("100000"));
    const dbPath = join(workdir, "crash-two-orders.db");
    const configPath = join(workdir, "crash-two-orders.json");
    writeFileSync(configPath, stringifyConfig(solverConfig(crashRepayment.address, dbPath)));

    const a = await openOnchain(net, user, terms("proof", { exclusiveFiller: exclusive.address, exclusivityWindow: 60n }));
    const b = await openOnchain(net, user, terms("proof"));
    const crashed = await runCrashingSolver(configPath, crashSolver, "after-fill-persist");
    expect(crashed.stderr).toContain("crash injected");
    const journal = new SolverStore(dbPath);
    expect(journal.get(a.orderId)?.state).toBe("WAITING");
    const journaledB = journal.get(b.orderId);
    expect(journaledB?.state).toBe("FILL_SIGNED");
    const nonceB = journal.tx(journaledB?.fillTx ?? "0x")?.nonce;
    journal.close();

    await advanceTime(net, 61n); // A's exclusivity is over: it is fillable as soon as the solver restarts
    const restarted = startSolver(configPath, crashSolver);
    try {
      await until(
        async () => (await repaid(a.orderId)()) && (await repaid(b.orderId)()),
        [headerRelayer],
        "both orders repaid after restart",
        400,
      );
    } finally {
      restarted.kill();
      await new Promise((resolve) => restarted.once("exit", resolve));
    }
    const eventsB = await fillEvents(b.orderId);
    expect(eventsB).toHaveLength(1);
    expect(eventsB[0]?.transactionHash).toBe(journaledB?.fillTx);
    expect(await fillEvents(a.orderId)).toHaveLength(1);
    expect(await balanceOf(net, "origin", net.inputToken, crashRepayment.address)).toBe(2n * parseEther("1000"));
    const after = new SolverStore(dbPath);
    const rowA = after.get(a.orderId);
    expect(after.tx(rowA?.fillTx ?? "0x")?.nonce).toBe((nonceB ?? -2) + 1);
    after.close();
  });
});

/** Starts the production solver (src/main.ts) as a child process. */
function startSolver(configPath: string, actor: Actor): ChildProcess {
  return spawn(process.execPath, ["src/main.ts", "--config", configPath, "--role", "solver"], {
    cwd: solverDir,
    env: { ...process.env, SOLVER_PRIVATE_KEY: actor.key },
    stdio: "ignore",
  });
}

/** Runs the test-only crash build (e2e/crash-solver.ts) until it kills itself at `crashAt`. */
function runCrashingSolver(
  configPath: string,
  actor: Actor,
  crashAt: string,
): Promise<{ code: number | null; signal: NodeJS.Signals | null; stderr: string }> {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, ["e2e/crash-solver.ts", "--config", configPath, "--crash-at", crashAt], {
      cwd: solverDir,
      env: { ...process.env, SOLVER_PRIVATE_KEY: actor.key },
      stdio: ["ignore", "ignore", "pipe"],
    });
    let stderr = "";
    child.stderr.on("data", (chunk: Buffer) => {
      stderr += chunk.toString();
    });
    const timer = setTimeout(() => {
      child.kill();
      reject(new Error(`solver did not crash at ${crashAt}: ${stderr}`));
    }, 120_000);
    child.on("exit", (code, signal) => {
      clearTimeout(timer);
      resolve({ code, signal, stderr });
    });
  });
}
