// SPDX-License-Identifier: MIT
// Unit tests of the watchtower on fake chains: which header it proves against, what it does when a proof cannot be
// produced, and that one claim it cannot handle never blinds it to the others.
import { type Address, type Hex, encodeFunctionData, keccak256 } from "viem";
import { describe, expect, it } from "vitest";

import { optimisticSettlementModuleAbi } from "../src/abi.ts";
import { silentLogger } from "../src/log.ts";
import { signCall } from "../src/tx.ts";
import { Watchtower, claimIdOf } from "../src/watchtower.ts";
import { RpcFault } from "./fakechain.ts";
import { A, FakeWorld, addressOf, keyOf } from "./fakeworld.ts";

function watchtower(world: FakeWorld): Watchtower {
  return new Watchtower({
    origin: world.origin.clients(),
    dest: world.dest.clients(),
    wallet: world.origin.wallet(keyOf("watcher")),
    originSettler: A.originSettler,
    optimisticModule: A.optimisticModule,
    headerStore: A.headerStore,
    destinationSettler: A.destinationSettler,
    log: silentLogger,
  });
}

/** An attacker claims `orderId` was filled by itself at `filledAt`. */
async function falseClaim(world: FakeWorld, orderId: Hex, originData: Hex, filledAt: bigint): Promise<Address> {
  const attacker = addressOf("attacker");
  const signed = await signCall(world.origin.wallet(keyOf("attacker")), {
    to: A.optimisticModule,
    data: encodeFunctionData({
      abi: optimisticSettlementModuleAbi,
      functionName: "claim",
      args: [orderId, attacker, filledAt, keccak256(originData)],
    }),
  });
  await world.origin.clients().public.sendRawTransaction({ serializedTransaction: signed.raw });
  return attacker;
}

/** Headers as an attacker leaves them: a relayed recent one plus imported ancestors down to block 1. */
function storeHeadersWithAncestors(world: FakeWorld): void {
  for (let i = 0; i < 10; i++) world.dest.advance(1n);
  for (let n = 1n; n <= world.dest.blockNumber; n++) world.storeHeader(n, 1_750_000_000n + n);
}

describe("Watchtower", () => {
  it("challenges a filledAt = 0 claim with the NEWEST stored header, even after ancestors down to block 1 were imported", async () => {
    const world = new FakeWorld();
    const { orderId, originData } = world.open({ mode: "optimistic" });
    storeHeadersWithAncestors(world);
    const attacker = await falseClaim(world, orderId, originData, 0n);

    const verdicts = await watchtower(world).tick();
    expect(verdicts.get(claimIdOf(orderId, attacker, 0n))).toBe("challenged");
    expect(world.optimistic.state.lastChallengeBlock).toBe(world.dest.blockNumber);
    expect(Object.keys(world.optimistic.state.claims)).toHaveLength(0);
  });

  it("falls back to an older header when the node cannot prove the newest one", async () => {
    const world = new FakeWorld();
    const { orderId, originData } = world.open({ mode: "optimistic" });
    storeHeadersWithAncestors(world);
    const newest = world.dest.blockNumber;
    world.dest.proofHook = (_address, block) => {
      if (block === newest) throw new RpcFault(-32000, "missing trie node");
    };
    const attacker = await falseClaim(world, orderId, originData, 0n);

    const verdicts = await watchtower(world).tick();
    expect(verdicts.get(claimIdOf(orderId, attacker, 0n))).toBe("challenged");
    expect(world.optimistic.state.lastChallengeBlock).toBe(newest - 1n);
  });

  it("a claim it cannot disprove this tick does not stop it from challenging the other claims", async () => {
    const world = new FakeWorld();
    const poisoned = world.open({ mode: "optimistic" });
    const other = world.open({ mode: "optimistic" });
    storeHeadersWithAncestors(world);
    world.unchallengeable.add(poisoned.orderId); // every challenge of this one reverts
    const attacker = await falseClaim(world, poisoned.orderId, poisoned.originData, 0n);
    await falseClaim(world, other.orderId, other.originData, 0n);

    const tower = watchtower(world);
    const verdicts = await tower.tick();
    expect(verdicts.get(claimIdOf(poisoned.orderId, attacker, 0n))).toBe("failed");
    expect(verdicts.get(claimIdOf(other.orderId, attacker, 0n))).toBe("challenged");

    world.unchallengeable.delete(poisoned.orderId); // retried on the next tick
    const again = await tower.tick();
    expect(again.get(claimIdOf(poisoned.orderId, attacker, 0n))).toBe("challenged");
  });

  it("leaves honest claims alone and waits when no header is newer than the claimed fill time", async () => {
    const world = new FakeWorld();
    const { orderId, originData } = world.open({ mode: "optimistic" });
    await falseClaim(world, orderId, originData, world.origin.time);
    const verdicts = await watchtower(world).tick();
    expect([...verdicts.values()]).toEqual(["waiting-for-header"]);

    // An honest claim: the destination record matches it.
    const honest = world.open({ mode: "optimistic" });
    world.fills.state.records[honest.orderId] = { filler: addressOf("repay"), filledAt: 7n, fillHash: keccak256(honest.originData) };
    const signed = await signCall(world.origin.wallet(keyOf("solver")), {
      to: A.optimisticModule,
      data: encodeFunctionData({
        abi: optimisticSettlementModuleAbi,
        functionName: "claim",
        args: [honest.orderId, addressOf("repay"), 7n, keccak256(honest.originData)],
      }),
    });
    await world.origin.clients().public.sendRawTransaction({ serializedTransaction: signed.raw });
    const next = await watchtower(world).tick();
    expect(next.get(claimIdOf(honest.orderId, addressOf("repay"), 7n))).toBe("honest");
  });
});
