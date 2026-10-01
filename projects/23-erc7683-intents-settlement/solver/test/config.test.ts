// SPDX-License-Identifier: MIT
import type { Address } from "viem";
import { describe, expect, it } from "vitest";

import { type Deployment, modeOf, parseSolverConfig, stringifyConfig } from "../src/config.ts";

const a = (n: number): Address => `0x${n.toString(16).padStart(40, "0")}`;

const deployment: Deployment = {
  origin: {
    chainId: 1001,
    rpcUrl: "http://127.0.0.1:1",
    originSettler: a(1),
    permit2: a(2),
    headerStore: a(3),
    mailbox: a(4),
    mailboxModule: a(5),
    optimisticModule: a(6),
    proofModule: a(7),
    bondToken: a(8),
  },
  destination: { chainId: 1002, rpcUrl: "http://127.0.0.1:2", destinationSettler: a(9), mailbox: a(10), reporter: a(11) },
};

describe("config", () => {
  it("maps settlement modules to modes, case-insensitively", () => {
    expect(modeOf(deployment, a(5))).toBe("mailbox");
    expect(modeOf(deployment, a(6).toUpperCase() as Address)).toBe("optimistic");
    expect(modeOf(deployment, a(7))).toBe("proof");
    expect(modeOf(deployment, a(99))).toBeUndefined();
  });

  it("round-trips big integers in the pricing section through JSON", () => {
    const json = stringifyConfig({
      deployment,
      repaymentAddress: a(12),
      dbPath: "x.db",
      pollIntervalMs: 100,
      pricing: { minProfit: 10n ** 30n, tokenPrices: { [a(13)]: 1n } },
    });
    const parsed = parseSolverConfig(json);
    expect(parsed.pricing.minProfit).toBe(10n ** 30n);
    expect(parsed.pricing.tokenPrices[a(13)]).toBe(1n);
    expect(parsed.deployment.origin.chainId).toBe(1001);
    expect(parsed.repaymentAddress).toBe(a(12));
  });
});
