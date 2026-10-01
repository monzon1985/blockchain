// SPDX-License-Identifier: MIT
// `npm run demo`: one order per settlement mode, plus a fraudulent claim, on two local anvil chains, with every
// off-chain actor running in-process. Prints what happened; takes about a minute. Requires `forge build` first.
// Exits non-zero if an order is not repaid in full or the fraudulent claim is not challenged (CI runs it).
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { type Hex, formatEther, parseEther } from "viem";

import { walletFor } from "../src/chains.ts";
import { createLogger } from "../src/log.ts";
import { HeaderRelayer, MailboxRelayer } from "../src/relayers.ts";
import { EscrowStatus, Solver } from "../src/solver.ts";
import { SolverStore } from "../src/store.ts";
import { Watchtower, claimIdOf } from "../src/watchtower.ts";
import { type Mode, balanceOf, escrowStatus, fraudulentClaim, mint, openOnchain } from "./actions.ts";
import { advanceTime, fund, mineDest, newActor, startLocalnet } from "./localnet.ts";

const log = createLogger({ role: "demo" }, "warn");
const say = (line: string): void => {
  console.log(line);
};

const net = await startLocalnet({ refundGrace: 600n, challengeWindow: 120n });
const failures: string[] = [];
const dir = mkdtempSync(join(tmpdir(), "intents-demo-"));
const store = new SolverStore(join(dir, "solver.db"));
const mailboxStore = new SolverStore(join(dir, "mailbox.db"));
try {
  const user = newActor();
  const solverKey = newActor();
  const repayment = newActor();
  const watcher = newActor();
  const attacker = newActor();
  await fund(net, [user.address, solverKey.address, watcher.address, attacker.address]);
  await mint(net, "dest", net.outputToken, solverKey.address, parseEther("100000"));
  await mint(net, "origin", net.deployment.origin.bondToken, solverKey.address, parseEther("1000"));
  say(`origin chain 1001 at ${net.originAnvil.rpcUrl}, destination chain 1002 at ${net.destAnvil.rpcUrl}`);

  const solver = new Solver({
    config: {
      deployment: net.deployment,
      repaymentAddress: repayment.address,
      dbPath: join(dir, "solver.db"),
      pollIntervalMs: 100,
      pricing: {
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
      },
    },
    origin: net.origin,
    dest: net.dest,
    originWallet: walletFor(net.origin, solverKey.key),
    destWallet: walletFor(net.dest, solverKey.key),
    store,
    log,
  });
  const headerRelayer = new HeaderRelayer({
    origin: net.origin,
    dest: net.dest,
    wallet: walletFor(net.origin, net.relayer.key),
    headerStore: net.deployment.origin.headerStore,
    log,
  });
  const mailboxRelayer = new MailboxRelayer({
    origin: net.origin,
    dest: net.dest,
    wallet: walletFor(net.origin, net.relayer.key),
    destMailbox: net.deployment.destination.mailbox,
    originMailbox: net.deployment.origin.mailbox,
    store: mailboxStore,
    log,
  });
  const watchtower = new Watchtower({
    origin: net.origin,
    dest: net.dest,
    wallet: walletFor(net.origin, watcher.key),
    originSettler: net.deployment.origin.originSettler,
    optimisticModule: net.deployment.origin.optimisticModule,
    headerStore: net.deployment.origin.headerStore,
    destinationSettler: net.deployment.destination.destinationSettler,
    log,
  });
  const tickAll = async (): Promise<void> => {
    await solver.tick();
    await headerRelayer.tick();
    await mailboxRelayer.tick();
    await watchtower.tick();
  };
  const waitRepaid = async (orderId: Hex, afterClaim?: () => Promise<void>): Promise<void> => {
    for (let i = 0; i < 200; i++) {
      if ((await escrowStatus(net, orderId)) === EscrowStatus.Repaid) return;
      if (afterClaim !== undefined && store.get(orderId)?.state === "AWAITING_REPAYMENT") await afterClaim();
      await tickAll();
    }
    throw new Error(`order ${orderId} was not repaid`);
  };

  const terms = (mode: Mode) => ({
    mode,
    inputAmount: parseEther("1000"),
    outputStart: parseEther("995"),
    outputEnd: parseEther("990"),
    recipient: user.address,
    fillWindow: 900n,
    exclusivityWindow: 30n,
  });

  for (const mode of ["mailbox", "proof", "optimistic"] as const) {
    const { orderId } = await openOnchain(net, user, terms(mode));
    const before = await balanceOf(net, "origin", net.inputToken, repayment.address);
    await waitRepaid(
      orderId,
      mode === "optimistic" ? () => advanceTime(net, net.challengeWindow + 1n) : undefined,
    );
    await solver.tick();
    const repaid = (await balanceOf(net, "origin", net.inputToken, repayment.address)) - before;
    const path = store.history(orderId).map((s) => s.to).join(" > ");
    say(`\n[${mode}] order ${orderId.slice(0, 10)}..: solver repaid ${formatEther(repaid)} IN on 1001`);
    say(`  solver journal: DISCOVERED > ${path}`);
    if (repaid !== terms(mode).inputAmount || store.get(orderId)?.state !== "SETTLED") {
      failures.push(`${mode}: repaid ${formatEther(repaid)} IN, journal state ${store.get(orderId)?.state ?? "none"}`);
    }
  }

  // A claim for an order nobody filled: the watchtower disputes it with an exclusion proof.
  const unfilled = await openOnchain(net, user, { ...terms("optimistic"), outputStart: parseEther("1000"), outputEnd: parseEther("1000") });
  await solver.tick();
  const claimedAt = await fraudulentClaim(net, attacker, unfilled.orderId, unfilled.originData);
  await mineDest(net, 2n);
  await headerRelayer.tick();
  const verdicts = await watchtower.tick();
  const verdict = verdicts.get(claimIdOf(unfilled.orderId, attacker.address, claimedAt)) ?? "none";
  say(`\n[fraud] attacker claimed unfilled order ${unfilled.orderId.slice(0, 10)}..; watchtower verdict: ${verdict}`);
  if (verdict !== "challenged") failures.push(`fraudulent claim not challenged (verdict: ${verdict})`);
  say(
    `  watcher bond balance: ${formatEther(await balanceOf(net, "origin", net.deployment.origin.bondToken, watcher.address))} BOND, escrow status: ${String(await escrowStatus(net, unfilled.orderId))} (1 = still open, refundable after the deadline)`,
  );
} finally {
  store.close();
  mailboxStore.close();
  net.stop();
  rmSync(dir, { recursive: true, force: true });
}
if (failures.length > 0) {
  console.error(`\ndemo FAILED:\n  ${failures.join("\n  ")}`);
  process.exitCode = 1;
} else {
  say("\ndemo OK: every mode repaid in full, the fraudulent claim was challenged");
}
