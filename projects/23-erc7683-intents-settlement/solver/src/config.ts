// SPDX-License-Identifier: MIT
// Configuration of the off-chain actors. Loaded from JSON; big integers are written as decimal strings.
// Private keys never live in the file: they come from environment variables (see main.ts).
import { readFileSync } from "node:fs";

import type { Address, Hex } from "viem";

import type { PricingConfig, SettlementMode } from "./pricing.ts";

/** Addresses and endpoints of one deployment on the two chains. */
export interface Deployment {
  origin: {
    chainId: number;
    rpcUrl: string;
    originSettler: Address;
    permit2: Address;
    headerStore: Address;
    mailbox: Address;
    mailboxModule: Address;
    optimisticModule: Address;
    proofModule: Address;
    bondToken: Address;
  };
  destination: {
    chainId: number;
    rpcUrl: string;
    destinationSettler: Address;
    mailbox: Address;
    reporter: Address;
  };
}

/** Everything the off-chain actors read from their JSON config file. */
export interface SolverConfig {
  deployment: Deployment;
  /** Origin-chain address the solver asks to be repaid to. */
  repaymentAddress: Address;
  /** SQLite file with the solver's journal. */
  dbPath: string;
  /** Directory of signed gasless orders (JSON) the solver may open with openFor. */
  feedDir?: string;
  /** Milliseconds between two ticks of an actor's loop. */
  pollIntervalMs: number;
  /**
   * Mailbox mode: seconds (origin chain time) after a report is mined before the solver reports the fill again if
   * the escrow is still open, in case the messaging layer lost or failed to deliver the first message. Default 300.
   */
  mailboxRecheckSec?: number;
  pricing: PricingConfig;
}

/** Default of `SolverConfig.mailboxRecheckSec`. */
export const DEFAULT_MAILBOX_RECHECK_SEC = 300;

/** Settlement mode of an order, from its settlement module. */
export function modeOf(deployment: Deployment, module: Address): SettlementMode | undefined {
  const m = module.toLowerCase();
  if (m === deployment.origin.mailboxModule.toLowerCase()) return "mailbox";
  if (m === deployment.origin.optimisticModule.toLowerCase()) return "optimistic";
  if (m === deployment.origin.proofModule.toLowerCase()) return "proof";
  return undefined;
}

/** Converts every decimal-string leaf under `pricing` to a bigint. */
function bigints(value: unknown): unknown {
  if (typeof value === "string" && /^\d+$/.test(value)) return BigInt(value);
  if (Array.isArray(value)) return value.map(bigints);
  if (value !== null && typeof value === "object") {
    return Object.fromEntries(Object.entries(value).map(([k, v]) => [k, bigints(v)]));
  }
  return value;
}

/** Parses a config file's JSON (pricing amounts as decimal strings). */
export function parseSolverConfig(json: string): SolverConfig {
  const raw = JSON.parse(json) as SolverConfig & { pricing: unknown };
  return { ...raw, pricing: bigints(raw.pricing) as PricingConfig };
}

/** Reads and parses the config file at `path`. */
export function loadSolverConfig(path: string): SolverConfig {
  return parseSolverConfig(readFileSync(path, "utf8"));
}

/** Serializes a config back to JSON (bigints as decimal strings). */
export function stringifyConfig(config: unknown): string {
  return JSON.stringify(config, (_k, v: unknown) => (typeof v === "bigint" ? v.toString() : v), 2);
}

/** Reads a 0x-prefixed 32-byte private key from the environment. */
export function keyFromEnv(name: string): Hex {
  const value = process.env[name];
  if (value === undefined || !/^0x[0-9a-fA-F]{64}$/.test(value)) {
    throw new Error(`environment variable ${name} must hold a 0x-prefixed 32-byte private key`);
  }
  return value as Hex;
}
