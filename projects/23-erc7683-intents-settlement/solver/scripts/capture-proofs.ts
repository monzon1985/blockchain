// SPDX-License-Identifier: MIT
// `npm run capture-proofs`: runs the real system on two anvil chains and captures eth_getProof output. By default it
// writes a SCRATCH file (test/fixtures/anvil-proofs.capture.json, git-ignored; or $CAPTURE_OUT) that you can verify
// with `ANVIL_FIXTURE=test/fixtures/anvil-proofs.capture.json forge test --match-contract AnvilStorageProofTest`.
// Addresses, keys and timestamps are fresh on every capture, so replacing the COMMITTED fixture
// (test/fixtures/anvil-proofs.json, used by the Foundry suites and the vitest known-answer tests) also changes every
// gas number measured on it; that needs `--update-committed` and a snapshot regeneration (printed at the end).
import { writeFileSync } from "node:fs";
import { parseArgs } from "node:util";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { type Hex, keccak256, parseEther, toHex } from "viem";

import { type RpcBlock, encodeVerifiedHeader } from "../src/header.ts";
import { decodeOriginData, fillerSlot } from "../src/orders.ts";
import { fillDirect, openOnchain } from "./actions.ts";
import { fund, mineDest, newActor, startLocalnet } from "./localnet.ts";

const here = dirname(fileURLToPath(import.meta.url));
const fixtures = join(here, "..", "..", "test", "fixtures");
const { values } = parseArgs({ options: { "update-committed": { type: "boolean", default: false } } });
const updateCommitted = values["update-committed"];
// CAPTURE_OUT lets CI capture a fresh fixture next to the committed one and verify it with forge.
const target = updateCommitted
  ? join(fixtures, "anvil-proofs.json")
  : (process.env.CAPTURE_OUT ?? join(fixtures, "anvil-proofs.capture.json"));

const net = await startLocalnet();
try {
  const user = newActor();
  const filler = newActor();
  const repayment = newActor();
  await fund(net, [user.address, filler.address]);

  const base = {
    inputAmount: parseEther("1000"),
    outputStart: parseEther("995"),
    outputEnd: parseEther("990"),
    recipient: newActor().address,
    fillWindow: 3600n,
  };
  // Nonces 0, 1, 2 of the same user: the Foundry test re-opens them in this order to get the same order ids.
  const filledProof = await openOnchain(net, user, { ...base, mode: "proof" });
  const unfilledOptimistic = await openOnchain(net, user, { ...base, mode: "optimistic" });
  const filledOptimistic = await openOnchain(net, user, { ...base, mode: "optimistic" });
  await fillDirect(net, filler, filledProof.orderId, filledProof.originData, repayment.address);
  await fillDirect(net, filler, filledOptimistic.orderId, filledOptimistic.originData, repayment.address);
  await mineDest(net, 5n);

  const dest = net.dest.public;
  const settler = net.deployment.destination.destinationSettler;
  const blockNumber = await dest.getBlockNumber();
  const block = (await dest.request({
    method: "eth_getBlockByNumber",
    params: [toHex(blockNumber), false],
  })) as unknown as RpcBlock;
  const headerRlp = encodeVerifiedHeader(block);

  const orders = { filledProof, unfilledOptimistic, filledOptimistic };
  const slots = Object.fromEntries(Object.entries(orders).map(([k, o]) => [k, fillerSlot(o.orderId)]));
  // The record's second word (fillHash) is not needed on-chain; it is captured to measure what proving it would cost.
  const fillHashSlot = toHex(BigInt(slots.filledProof as Hex) + 1n, { size: 32 });
  const proof = await dest.getProof({
    address: settler,
    storageKeys: [slots.filledProof as Hex, slots.unfilledOptimistic as Hex, slots.filledOptimistic as Hex, fillHashSlot],
    blockNumber,
  });

  // Every non-empty slot of the settler: both record words of each filled order (it has no other storage).
  const storage: { slot: Hex; value: Hex }[] = [];
  for (const o of [filledProof, filledOptimistic]) {
    const first = BigInt(fillerSlot(o.orderId));
    for (const slot of [first, first + 1n]) {
      const key = toHex(slot, { size: 32 });
      storage.push({ slot: key, value: await dest.getStorageAt({ address: settler, slot: key, blockNumber }) ?? "0x" });
    }
  }

  const byKey = (i: number) => {
    const entry = proof.storageProof[i];
    if (entry === undefined) throw new Error("missing storage proof");
    return { slot: entry.key, value: toHex(entry.value, { size: 32 }), proof: entry.proof };
  };
  const fixture = {
    description: "eth_getProof output captured from anvil by solver/scripts/capture-proofs.ts",
    anvilChainIds: { origin: net.deployment.origin.chainId, destination: net.deployment.destination.chainId },
    origin: {
      accessManagerAdmin: net.admin.address,
      originSettler: net.deployment.origin.originSettler,
      permit2: net.deployment.origin.permit2,
      headerStore: net.deployment.origin.headerStore,
      optimisticModule: net.deployment.origin.optimisticModule,
      proofModule: net.deployment.origin.proofModule,
      bondToken: net.deployment.origin.bondToken,
      inputToken: net.inputToken,
      refundGrace: net.refundGrace.toString(),
      challengeWindow: net.challengeWindow.toString(),
      bond: net.bond.toString(),
    },
    destinationSettler: settler,
    user: user.address,
    repayment: repayment.address,
    header: {
      number: Number(blockNumber),
      hash: block.hash,
      stateRoot: block.stateRoot,
      timestamp: Number(BigInt(block.timestamp)),
      rlp: headerRlp,
      rpcBlock: block,
    },
    account: { proof: proof.accountProof, storageHash: proof.storageHash, codeHash: proof.codeHash },
    orders: Object.fromEntries(
      Object.entries(orders).map(([name, o], i) => [
        name,
        {
          orderId: o.orderId,
          originData: o.originData,
          fillHash: keccak256(o.originData),
          orderData: decodeOriginData(o.originData).data,
          ...byKey(i),
        },
      ]),
    ),
    fillHashSlotOfFilledProof: byKey(3),
    storage,
  };
  writeFileSync(
    target,
    `${JSON.stringify(fixture, (_k, v: unknown) => (typeof v === "bigint" ? v.toString() : v), 2)}\n`,
  );
  console.log(`wrote ${target} (destination block ${blockNumber.toString()})`);
  if (updateCommitted) {
    console.log(
      [
        "The committed fixture changed: regenerate the gas snapshots measured on it, from the project root:",
        "  forge test --match-contract GasBench      # rewrites snapshots/GasBench.json (FORGE_SNAPSHOT_CHECK unset)",
        "  forge snapshot --match-contract GasBench  # rewrites .gas-snapshot",
        "then update the README gas tables from snapshots/GasBench.json.",
      ].join("\n"),
    );
  } else {
    console.log("scratch capture; verify it with:");
    console.log(`  ANVIL_FIXTURE=${target} forge test --match-contract AnvilStorageProofTest`);
  }
} finally {
  net.stop();
}
