// SPDX-License-Identifier: MIT
// Known-answer vectors captured from anvil by `npm run capture-proofs` (shared with the Foundry suite).
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import type { Address, Hex } from "viem";

import type { RpcBlock } from "../src/header.ts";

export interface FixtureOrder {
  orderId: Hex;
  originData: Hex;
  fillHash: Hex;
  slot: Hex;
  value: Hex;
  proof: Hex[];
}

export interface AnvilFixture {
  origin: { originSettler: Address; proofModule: Address; optimisticModule: Address; inputToken: Address };
  destinationSettler: Address;
  user: Address;
  repayment: Address;
  header: { number: number; hash: Hex; stateRoot: Hex; timestamp: number; rlp: Hex; rpcBlock: RpcBlock };
  account: { proof: Hex[]; storageHash: Hex };
  orders: Record<"filledProof" | "unfilledOptimistic" | "filledOptimistic", FixtureOrder>;
  storage: { slot: Hex; value: Hex }[];
}

const here = dirname(fileURLToPath(import.meta.url));

export const fixture = JSON.parse(
  readFileSync(join(here, "..", "..", "test", "fixtures", "anvil-proofs.json"), "utf8"),
) as AnvilFixture;
