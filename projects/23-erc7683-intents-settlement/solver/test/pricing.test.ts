// SPDX-License-Identifier: MIT
import { type Address, parseEther, zeroAddress } from "viem";
import { describe, expect, it } from "vitest";

import { amountAt } from "../src/decay.ts";
import type { Intent } from "../src/orders.ts";
import { type PricingConfig, type QuoteInput, type SettlementMode, quote } from "../src/pricing.ts";

const IN: Address = "0x00000000000000000000000000000000000000a1";
const OUT: Address = "0x00000000000000000000000000000000000000b2";
const ME: Address = "0x000000000000000000000000000000000000000c";
const OTHER: Address = "0x000000000000000000000000000000000000000d";
const NOW = 1_000_000n;

const config: PricingConfig = {
  tokenPrices: { [IN]: 1n, [OUT]: 1n },
  nativePriceOrigin: 3000n,
  nativePriceDest: 3000n,
  gas: { open: 200_000n, fill: 150_000n, settle: { mailbox: 80_000n, optimistic: 250_000n, proof: 300_000n } },
  capitalCostBpsPerHour: 10n,
  modeRiskBps: { mailbox: 5n, optimistic: 10n, proof: 2n },
  settlementDelaySec: { mailbox: 300n, optimistic: 1800n, proof: 120n },
  settlementLatencySec: { mailbox: 300n, optimistic: 30n, proof: 180n },
  minProfit: parseEther("1"),
  fillSafetyMarginSec: 10n,
};

function intent(overrides: Partial<Intent["data"]> = {}, fillDeadline = Number(NOW + 600n)): Intent {
  return {
    originSettler: zeroAddress,
    user: zeroAddress,
    nonce: 0n,
    originChainId: 1001n,
    openDeadline: 0xffffffff,
    fillDeadline,
    data: {
      inputToken: IN,
      inputAmount: parseEther("1000"),
      outputToken: OUT,
      outputStartAmount: parseEther("995"),
      outputEndAmount: parseEther("990"),
      recipient: zeroAddress,
      destinationChainId: 1002n,
      destinationSettler: zeroAddress,
      exclusiveFiller: zeroAddress,
      exclusivityDeadline: Number(NOW + 60n),
      settlementModule: zeroAddress,
      ...overrides,
    },
  };
}

function input(i: Intent, mode: SettlementMode = "mailbox", extra: Partial<QuoteInput> = {}): QuoteInput {
  return {
    intent: i,
    mode,
    now: NOW,
    me: ME,
    inventory: parseEther("1000000"),
    gasPriceOrigin: 1_000_000_000n,
    gasPriceDest: 1_000_000_000n,
    needsOpen: false,
    refundGrace: 600n,
    config,
    ...extra,
  };
}

/** Highest output the model accepts for `mode` (the budget divided by the output price). */
function budget(i: Intent, mode: SettlementMode, needsOpen = false): bigint {
  const gas =
    config.gas.fill * 1_000_000_000n * 3000n +
    (config.gas.settle[mode] + (needsOpen ? config.gas.open : 0n)) * 1_000_000_000n * 3000n;
  const bps = config.modeRiskBps[mode] + (config.capitalCostBpsPerHour * config.settlementDelaySec[mode]) / 3600n;
  return i.data.inputAmount - gas - (i.data.inputAmount * bps) / 10_000n - config.minProfit;
}

describe("quote", () => {
  it("fills immediately when the start amount is already profitable", () => {
    const q = quote(input(intent()));
    expect(q.action).toBe("fill");
    if (q.action !== "fill") return;
    expect(q.at).toBe(NOW);
    expect(q.outputAmount).toBe(parseEther("995"));
    expect(q.expectedProfit).toBeGreaterThanOrEqual(config.minProfit);
  });

  it("waits for the decay to reach its budget, to the second", () => {
    const i = intent({ outputStartAmount: parseEther("999.9"), outputEndAmount: parseEther("990") });
    const q = quote(input(i));
    expect(q.action).toBe("wait");
    if (q.action !== "wait") return;
    const max = budget(i, "mailbox");
    const curve = (t: bigint) =>
      amountAt(i.data.outputStartAmount, i.data.outputEndAmount, BigInt(i.data.exclusivityDeadline), BigInt(i.fillDeadline), t);
    expect(curve(q.at)).toBeLessThanOrEqual(max);
    expect(curve(q.at - 1n)).toBeGreaterThan(max);
    expect(q.expectedProfit).toBeGreaterThanOrEqual(config.minProfit);
  });

  it("skips orders that are unprofitable even at the floor", () => {
    const q = quote(input(intent({ outputStartAmount: parseEther("1000"), outputEndAmount: parseEther("1000") })));
    expect(q).toEqual({ action: "skip", reason: "unprofitable" });
  });

  it("respects another solver's exclusivity window", () => {
    const i = intent({ exclusiveFiller: OTHER });
    const q = quote(input(i));
    expect(q.action).toBe("wait");
    if (q.action === "wait") expect(q.at).toBe(BigInt(i.data.exclusivityDeadline) + 1n);
  });

  it("fills its own exclusive orders immediately", () => {
    expect(quote(input(intent({ exclusiveFiller: ME }))).action).toBe("fill");
  });

  it("skips when the inventory cannot cover the output", () => {
    expect(quote(input(intent(), "mailbox", { inventory: parseEther("994") }))).toEqual({
      action: "skip",
      reason: "inventory",
    });
  });

  it("skips too close to the fill deadline", () => {
    const i = intent({}, Number(NOW + 5n));
    expect(quote(input(i))).toEqual({ action: "skip", reason: "deadline" });
  });

  it("skips when settlement could not land before the refund window opens", () => {
    const slow = { ...config, settlementLatencySec: { ...config.settlementLatencySec, proof: 10_000n } };
    expect(quote(input(intent(), "proof", { config: slow }))).toEqual({ action: "skip", reason: "settlement-window" });
  });

  it("charges more for weaker trust models and slower settlement", () => {
    const i = intent();
    expect(budget(i, "optimistic")).toBeLessThan(budget(i, "mailbox"));
    // An order priced between the two budgets is filled at once under mode 1 but must decay under mode 2.
    const start = (budget(i, "optimistic") + budget(i, "mailbox")) / 2n;
    const between = intent({ outputStartAmount: start, outputEndAmount: parseEther("990") });
    expect(quote(input(between, "mailbox")).action).toBe("fill");
    expect(quote(input(between, "optimistic")).action).toBe("wait");
  });

  it("includes the openFor gas for gasless orders", () => {
    const i = intent();
    const start = (budget(i, "mailbox", true) + budget(i, "mailbox", false)) / 2n;
    const tight = intent({ outputStartAmount: start, outputEndAmount: parseEther("990") });
    expect(quote(input(tight, "mailbox", { needsOpen: false })).action).toBe("fill");
    expect(quote(input(tight, "mailbox", { needsOpen: true })).action).toBe("wait");
  });

  it("skips tokens without a price", () => {
    const i = intent({ outputToken: OTHER });
    expect(quote(input(i))).toEqual({ action: "skip", reason: "unknown-token-price" });
  });
});
