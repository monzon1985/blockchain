// SPDX-License-Identifier: MIT
// Builds and runs one off-chain actor from a config file. Shared by the production CLI (main.ts) and the test-only
// crash-injection entry point (e2e/crash-solver.ts), so both run exactly the same actor code.
import { clientsFor, walletFor } from "./chains.ts";
import { type SolverConfig, keyFromEnv } from "./config.ts";
import type { Logger } from "./log.ts";
import { HeaderRelayer, MailboxRelayer } from "./relayers.ts";
import { Solver, type SolverDeps } from "./solver.ts";
import { SolverStore } from "./store.ts";
import { Watchtower } from "./watchtower.ts";

/** The actors the CLI can run. */
export const ROLES = ["solver", "header-relayer", "mailbox-relayer", "watchtower"] as const;

/** One of ROLES. */
export type Role = (typeof ROLES)[number];

/** Narrows a CLI string to a Role, or throws. */
export function parseRole(value: string): Role {
  const role = ROLES.find((r) => r === value);
  if (role === undefined) throw new Error(`unknown role ${value}; expected one of ${ROLES.join(", ")}`);
  return role;
}

/** A running actor: `tick()` in a loop, `close()` once. */
export interface Actor {
  tick: () => Promise<unknown>;
  close: () => void;
}

/**
 * Builds `role` from `config`. Keys come from the environment: SOLVER_PRIVATE_KEY (solver), RELAYER_PRIVATE_KEY
 * (both relayers), WATCHER_PRIVATE_KEY (watchtower).
 * @param solverHooks Extra solver dependencies; only the crash-recovery e2e passes one (`onCheckpoint`).
 */
export function buildActor(
  role: Role,
  config: SolverConfig,
  log: Logger,
  solverHooks: Pick<SolverDeps, "onCheckpoint"> = {},
): Actor {
  const origin = clientsFor(config.deployment.origin.chainId, config.deployment.origin.rpcUrl);
  const dest = clientsFor(config.deployment.destination.chainId, config.deployment.destination.rpcUrl);
  switch (role) {
    case "solver": {
      const key = keyFromEnv("SOLVER_PRIVATE_KEY");
      const store = new SolverStore(config.dbPath);
      const solver = new Solver({
        config,
        origin,
        dest,
        originWallet: walletFor(origin, key),
        destWallet: walletFor(dest, key),
        store,
        log,
        ...solverHooks,
      });
      return {
        tick: () => solver.tick(),
        close: () => {
          store.close();
        },
      };
    }
    case "header-relayer": {
      const relayer = new HeaderRelayer({
        origin,
        dest,
        wallet: walletFor(origin, keyFromEnv("RELAYER_PRIVATE_KEY")),
        headerStore: config.deployment.origin.headerStore,
        log,
      });
      return { tick: () => relayer.tick(), close: () => undefined };
    }
    case "mailbox-relayer": {
      const store = new SolverStore(`${config.dbPath}.mailbox`);
      const relayer = new MailboxRelayer({
        origin,
        dest,
        wallet: walletFor(origin, keyFromEnv("RELAYER_PRIVATE_KEY")),
        destMailbox: config.deployment.destination.mailbox,
        originMailbox: config.deployment.origin.mailbox,
        store,
        log,
      });
      return {
        tick: () => relayer.tick(),
        close: () => {
          store.close();
        },
      };
    }
    case "watchtower": {
      const watchtower = new Watchtower({
        origin,
        dest,
        wallet: walletFor(origin, keyFromEnv("WATCHER_PRIVATE_KEY")),
        originSettler: config.deployment.origin.originSettler,
        optimisticModule: config.deployment.origin.optimisticModule,
        headerStore: config.deployment.origin.headerStore,
        destinationSettler: config.deployment.destination.destinationSettler,
        log,
      });
      return { tick: () => watchtower.tick(), close: () => undefined };
    }
  }
}

/**
 * Ticks `actor` every `config.pollIntervalMs` until SIGINT/SIGTERM or `maxTicks`, logging (not throwing) tick
 * errors, then closes it.
 */
export async function runActor(actor: Actor, config: SolverConfig, log: Logger, maxTicks = Infinity): Promise<void> {
  const shutdown = new AbortController();
  const stop = (): void => {
    shutdown.abort();
  };
  process.on("SIGINT", stop);
  process.on("SIGTERM", stop);
  log.info("started", { origin: config.deployment.origin.chainId, destination: config.deployment.destination.chainId });
  for (let i = 0; !shutdown.signal.aborted && i < maxTicks; i++) {
    try {
      await actor.tick();
    } catch (error) {
      log.error("tick failed", { error });
    }
    await new Promise((resolve) => setTimeout(resolve, config.pollIntervalMs));
  }
  actor.close();
  process.off("SIGINT", stop);
  process.off("SIGTERM", stop);
  log.info("stopped");
}
