// SPDX-License-Identifier: MIT
/**
 * Deterministic gas table. Replays a fixed scenario on a fresh simulated chain (every transaction pinned to an
 * explicit timestamp), measures `gasUsed` of create / withdraw / cancel / renounce / transfer and the
 * `eth_estimateGas` of `tokenURI`, and compares the result with the committed `gas-table.json`.
 *
 *   npm run gas:check    # fails on any difference
 *   npm run gas:update   # rewrites gas-table.json
 */
import { readFile, writeFile } from "node:fs/promises";
import path from "node:path";

import { network } from "hardhat";
import { encodeFunctionData, type Hash } from "viem";

import { DAY, E18, MONTH, Shape, T0, evenMilestones, linearParams, milestoneParams } from "../test/support/params.js";
import { deployAll } from "../test/support/scenario.js";

const TABLE_PATH = path.join(import.meta.dirname, "..", "gas-table.json");
/** `npm run gas:update` (or UPDATE_GAS_TABLE=1) rewrites the table; npm sets `npm_lifecycle_event` on every OS. */
const UPDATE = process.env.UPDATE_GAS_TABLE === "1" || process.env.npm_lifecycle_event === "gas:update";

const connection = await network.create();
const { viem, networkHelpers } = connection;
const publicClient = await viem.getPublicClient();
const { vesting, renderer, demoToken, usd, alice, bob, deployer } = await deployAll(connection);
const recording = await viem.deployContract("RecordingRecipient");
const bench = await viem.deployContract("MilestoneStorageBench");

const measured: Record<string, number> = {};
let clock = T0;

/** Runs `send` in a block at the next scenario timestamp and records its gasUsed under `label`. */
async function measure(label: string, send: () => Promise<Hash>, at?: number): Promise<number> {
  clock = at ?? clock + 60;
  await networkHelpers.time.setNextBlockTimestamp(clock);
  const receipt = await publicClient.waitForTransactionReceipt({ hash: await send() });
  if (receipt.status !== "success") throw new Error(`${label} reverted`);
  measured[label] = Number(receipt.gasUsed);
  return measured[label];
}

async function estimateTokenUri(label: string, streamId: bigint): Promise<void> {
  const gas = await publicClient.estimateGas({
    account: deployer.account.address,
    to: vesting.address,
    data: encodeFunctionData({ abi: vesting.abi, functionName: "tokenURI", args: [streamId] }),
  });
  measured[label] = Number(gas);
}

const recipient = alice.account.address;
const segments16 = evenMilestones(16, 1_000n * E18, T0, 15 * DAY);
const tranches32 = evenMilestones(32, 500n * E18, T0, 10 * DAY);

// Warm-up stream so that every measured creation sees the same (non-zero) nextStreamId slot.
await measure(
  "warm-up (not reported)",
  () =>
    vesting.write.create([demoToken.address, linearParams({ recipient, deposit: E18, start: T0, end: T0 + MONTH })]),
  T0,
);
delete measured["warm-up (not reported)"];

// Creation, one stream per shape. Ids 2..7.
await measure("create: linear", () =>
  vesting.write.create([
    demoToken.address,
    linearParams({ recipient, deposit: 1_200n * E18, start: T0, end: T0 + 12 * MONTH }),
  ]),
);
await measure("create: linear with cliff", () =>
  vesting.write.create([
    demoToken.address,
    linearParams({ recipient, deposit: 1_200n * E18, start: T0, cliff: T0 + 3 * MONTH, end: T0 + 12 * MONTH }),
  ]),
);
await measure("create: tranched x12", () =>
  vesting.write.create([
    demoToken.address,
    milestoneParams({
      recipient,
      shape: Shape.Tranched,
      start: T0,
      milestones: evenMilestones(12, 100n * E18, T0, MONTH),
    }),
  ]),
);
await measure("create: tranched x32", () =>
  vesting.write.create([
    demoToken.address,
    milestoneParams({ recipient, shape: Shape.Tranched, start: T0, milestones: tranches32 }),
  ]),
);
await measure("create: segmented x4", () =>
  vesting.write.create([
    demoToken.address,
    milestoneParams({
      recipient,
      shape: Shape.Segmented,
      start: T0,
      milestones: evenMilestones(4, 250n * E18, T0, 3 * MONTH),
    }),
  ]),
);
await measure("create: segmented x16", () =>
  vesting.write.create([
    demoToken.address,
    milestoneParams({ recipient, shape: Shape.Segmented, start: T0, milestones: segments16 }),
  ]),
);
// Ids 8..17.
const batch = Array.from({ length: 10 }, (_, i) =>
  linearParams({
    recipient: i % 2 === 0 ? alice.account.address : bob.account.address,
    deposit: 1_000n * 10n ** 6n,
    start: T0,
    end: T0 + 12 * MONTH,
  }),
);
const batchTotal = await measure("createBatch: 10 x linear (total)", () =>
  vesting.write.createBatch([usd.address, batch]),
);
measured["createBatch: 10 x linear (per stream)"] = Math.round(batchTotal / 10);
// Id 18: owned by a contract with the cancel hook.
await measure("create: linear to hook recipient", () =>
  vesting.write.create([
    demoToken.address,
    linearParams({ recipient: recording.address, deposit: 1_000n * E18, start: T0, end: T0 + 12 * MONTH }),
  ]),
);

// Withdrawals and sender actions, mid-schedule.
const asAlice = { account: alice.account };
await measure(
  "withdraw: linear (first)",
  () => vesting.write.withdraw([2n, recipient, 100n * E18], asAlice),
  T0 + 5 * MONTH,
);
await measure("withdraw: linear (second)", () => vesting.write.withdraw([2n, recipient, 100n * E18], asAlice));
await measure("withdrawMax: linear with cliff", () => vesting.write.withdrawMax([3n, recipient], asAlice));
await measure("withdrawMax: tranched x32", () => vesting.write.withdrawMax([5n, recipient], asAlice));
await measure("withdrawMax: segmented x16", () => vesting.write.withdrawMax([7n, recipient], asAlice));
await measure("cancel: EOA recipient", () => vesting.write.cancel([4n]));
await measure("cancel: contract recipient (hook)", () => vesting.write.cancel([18n]));
await measure("renounceCancelability", () => vesting.write.renounceCancelability([6n]));
await measure("transferFrom (stream NFT)", () =>
  vesting.write.transferFrom([alice.account.address, bob.account.address, 8n], asAlice),
);

// Rendering cost at a fixed time.
await networkHelpers.time.increaseTo(T0 + 6 * MONTH);
clock = T0 + 6 * MONTH;
await estimateTokenUri("tokenURI: linear with cliff (eth_estimateGas)", 3n);
await estimateTokenUri("tokenURI: tranched x32 (eth_estimateGas)", 5n);
await estimateTokenUri("tokenURI: segmented x16 (eth_estimateGas)", 7n);
await estimateTokenUri("tokenURI: canceled tranched x12 (eth_estimateGas)", 4n);

// Storage layout benchmark: one slot per milestone versus one SSTORE2 data contract.
for (const [label, milestones] of [
  ["x16", segments16],
  ["x32", tranches32],
] as const) {
  await measure(`bench: store ${label} milestones in slots`, () => bench.write.storeInSlots([milestones]));
  const slotsId = (await bench.read.nextId()) - 1n;
  await measure(`bench: store ${label} milestones via SSTORE2`, () => bench.write.storeViaSstore2([milestones]));
  const pointerId = (await bench.read.nextId()) - 1n;
  measured[`bench: read ${label} milestones from slots (eth_estimateGas)`] = Number(
    await publicClient.estimateGas({
      to: bench.address,
      data: encodeFunctionData({ abi: bench.abi, functionName: "sumFromSlots", args: [slotsId] }),
    }),
  );
  measured[`bench: read ${label} milestones via SSTORE2 (eth_estimateGas)`] = Number(
    await publicClient.estimateGas({
      to: bench.address,
      data: encodeFunctionData({ abi: bench.abi, functionName: "sumViaSstore2", args: [pointerId] }),
    }),
  );
}

// Runtime bytecode sizes (EIP-170 limit: 24,576 bytes).
for (const [label, address] of [
  ["VestingStreams", vesting.address],
  ["StreamRenderer", renderer.address],
] as const) {
  const code = await publicClient.getCode({ address });
  measured[`runtime size: ${label} (bytes)`] = code === undefined ? 0 : (code.length - 2) / 2;
}

/*//////////////////////////////////////////////////////////////
                         COMPARE / UPDATE
//////////////////////////////////////////////////////////////*/

const rows = Object.entries(measured);
if (UPDATE) {
  await writeFile(TABLE_PATH, `${JSON.stringify(measured, null, 2)}\n`);
  console.log(`Wrote ${rows.length} entries to gas-table.json`);
}

const committed = JSON.parse(await readFile(TABLE_PATH, "utf8")) as Record<string, number>;
let failures = 0;
console.log("| Operation | Gas | Committed | Delta |");
console.log("|---|---:|---:|---:|");
for (const [label, value] of rows) {
  const expected = committed[label];
  const delta = expected === undefined ? "new" : value - expected;
  if (delta !== 0) failures++;
  console.log(
    `| ${label} | ${value.toLocaleString("en-US")} | ${expected?.toLocaleString("en-US") ?? "-"} | ${delta === 0 ? "0" : String(delta)} |`,
  );
}
for (const label of Object.keys(committed)) {
  if (!(label in measured)) {
    failures++;
    console.log(`| ${label} | missing | ${committed[label]} | removed |`);
  }
}

if (failures > 0) {
  console.error(
    `\ngas:check failed: ${failures} entr${failures === 1 ? "y differs" : "ies differ"} from gas-table.json (run \`npm run gas:update\` if intended)`,
  );
  process.exitCode = 1;
} else {
  console.log(`\ngas:check passed: ${rows.length} entries match gas-table.json`);
}
