// SPDX-License-Identifier: MIT
// Profitability model of the solver. Pure: every input is passed in, so the policy is unit-tested in isolation.
//
// Values are in a common numeraire (e.g. 1e-18 USD). The solver fills when
//   value(input repaid) - value(output paid at fill time) - gas - capital cost - trust premium >= minProfit
// and, because the owed output decays over time, it can compute the earliest moment the order becomes worth
// filling instead of polling.
import type { Address } from "viem";

import { amountAt, earliestAffordable } from "./decay.ts";
import type { Intent } from "./orders.ts";

/** The three settlement modes, by trust model. */
export type SettlementMode = "mailbox" | "optimistic" | "proof";

/** Gas units the solver budgets per transaction kind. */
export interface GasUnits {
  open: bigint;
  fill: bigint;
  /** Settlement transactions by mode, summed (e.g. claim + finalize). */
  settle: Record<SettlementMode, bigint>;
}

/** Static pricing policy of the solver (values in a common numeraire, times in seconds). */
export interface PricingConfig {
  /** Numeraire value of one base unit of each token (lower-case address keys). */
  tokenPrices: Record<string, bigint>;
  /** Numeraire value of one wei on each chain. */
  nativePriceOrigin: bigint;
  nativePriceDest: bigint;
  gas: GasUnits;
  /** Opportunity cost of the capital advanced, in basis points per hour until repayment. */
  capitalCostBpsPerHour: bigint;
  /** Premium charged for the trust model of each settlement mode, in basis points of the repayment. */
  modeRiskBps: Record<SettlementMode, bigint>;
  /** Seconds from fill to repayment, by mode (relay latency, challenge window, header cadence). */
  settlementDelaySec: Record<SettlementMode, bigint>;
  /** Seconds the settlement transaction itself needs after the fill, by mode, to beat the refund window. */
  settlementLatencySec: Record<SettlementMode, bigint>;
  /** Minimum profit, in numeraire, to take an order. */
  minProfit: bigint;
  /** Never plan a fill closer than this to the fill deadline. */
  fillSafetyMarginSec: bigint;
}

/** Everything `quote` needs; the function is pure. */
export interface QuoteInput {
  intent: Intent;
  mode: SettlementMode;
  /** Current destination-chain timestamp. */
  now: bigint;
  /** This solver's filling address. */
  me: Address;
  /** Output-token balance not already reserved for other fills. */
  inventory: bigint;
  gasPriceOrigin: bigint;
  gasPriceDest: bigint;
  /** Whether the solver must also pay for `openFor`. */
  needsOpen: boolean;
  /** OriginSettler.REFUND_GRACE in seconds. */
  refundGrace: bigint;
  config: PricingConfig;
}

/** Decision for one order: fill now, wait until `at`, or skip (with the reason). Amounts in output-token units. */
export type Quote =
  | { action: "fill"; at: bigint; outputAmount: bigint; expectedProfit: bigint }
  | { action: "wait"; at: bigint; outputAmount: bigint; expectedProfit: bigint }
  | { action: "skip"; reason: SkipReason };

/** Why an order is not worth filling. */
export type SkipReason =
  | "unknown-token-price"
  | "deadline"
  | "unprofitable"
  | "decays-too-late"
  | "inventory"
  | "settlement-window";

const BPS = 10_000n;

function value(prices: Record<string, bigint>, token: Address, amount: bigint): bigint | null {
  const price = prices[token.toLowerCase()];
  return price === undefined ? null : amount * price;
}

/** Decide whether, and when, to fill `input.intent`. */
export function quote(input: QuoteInput): Quote {
  const { intent, mode, now, config } = input;
  const data = intent.data;
  const deadline = BigInt(intent.fillDeadline);
  const latestFill = deadline - config.fillSafetyMarginSec;
  if (now > latestFill) return { action: "skip", reason: "deadline" };

  const revenue = value(config.tokenPrices, data.inputToken, data.inputAmount);
  const outputPrice = config.tokenPrices[data.outputToken.toLowerCase()];
  if (revenue === null || outputPrice === undefined || outputPrice === 0n) {
    return { action: "skip", reason: "unknown-token-price" };
  }

  const originGas = config.gas.settle[mode] + (input.needsOpen ? config.gas.open : 0n);
  const gasCost =
    config.gas.fill * input.gasPriceDest * config.nativePriceDest +
    originGas * input.gasPriceOrigin * config.nativePriceOrigin;
  const holdingBps =
    config.modeRiskBps[mode] + (config.capitalCostBpsPerHour * config.settlementDelaySec[mode]) / 3600n;
  const holdingCost = (revenue * holdingBps) / BPS;
  const budget = revenue - gasCost - holdingCost - config.minProfit;
  if (budget <= 0n) return { action: "skip", reason: "unprofitable" };
  const maxOutput = budget / outputPrice;

  // Earliest time this solver may fill: after someone else's exclusivity window.
  let earliest = now;
  const exclusive = data.exclusiveFiller.toLowerCase();
  if (
    exclusive !== "0x0000000000000000000000000000000000000000" &&
    exclusive !== input.me.toLowerCase() &&
    now <= BigInt(data.exclusivityDeadline)
  ) {
    earliest = BigInt(data.exclusivityDeadline) + 1n;
  }

  const decayStart = BigInt(data.exclusivityDeadline);
  const at = earliestAffordable(
    data.outputStartAmount,
    data.outputEndAmount,
    decayStart,
    deadline,
    earliest,
    maxOutput,
  );
  if (at === null) return { action: "skip", reason: "unprofitable" };
  if (at > latestFill) return { action: "skip", reason: "decays-too-late" };

  const outputAmount = amountAt(data.outputStartAmount, data.outputEndAmount, decayStart, deadline, at);
  if (outputAmount > input.inventory) return { action: "skip", reason: "inventory" };
  if (at + config.settlementLatencySec[mode] >= deadline + input.refundGrace) {
    return { action: "skip", reason: "settlement-window" };
  }

  const expectedProfit = revenue - gasCost - holdingCost - outputAmount * outputPrice;
  return { action: at <= now ? "fill" : "wait", at, outputAmount, expectedProfit };
}
