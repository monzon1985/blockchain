// SPDX-License-Identifier: MIT
/**
 * Local end-to-end demo on the in-process EDR chain: deploys the protocol with the Ignition demo module, creates one
 * stream of each shape with a single `createBatch`, time-travels through the schedule while the recipient withdraws
 * and the sender cancels one stream, and writes the NFT art at each step to `demo-out/`.
 *
 *   npm run demo
 */
import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";

import { network } from "hardhat";
import { formatUnits } from "viem";

import DemoModule from "../ignition/modules/Demo.js";
import { decodeTokenUri } from "../test/support/metadata.js";
import { E18, MONTH, Shape, T0, evenMilestones, linearParams, milestoneParams } from "../test/support/params.js";

const OUT_DIR = path.join(import.meta.dirname, "..", "demo-out");
const STATUS = ["Pending", "Streaming", "Settled", "Canceled", "Depleted"] as const;

const { ignition, viem, networkHelpers } = await network.create();
const [, employee] = await viem.getWalletClients();
if (employee === undefined) throw new Error("need two accounts");

const { vesting, renderer, demoToken } = await ignition.deploy(DemoModule);
console.log(
  `VestingStreams ${vesting.address}\nStreamRenderer ${renderer.address}\nDemoToken      ${demoToken.address}\n`,
);

await networkHelpers.time.setNextBlockTimestamp(T0);
await vesting.write.createBatch([
  demoToken.address,
  [
    linearParams({
      recipient: employee.account.address,
      deposit: 48_000n * E18,
      start: T0,
      cliff: T0 + 3 * MONTH,
      end: T0 + 12 * MONTH,
    }),
    milestoneParams({
      recipient: employee.account.address,
      shape: Shape.Tranched,
      start: T0,
      milestones: evenMilestones(4, 2_500n * E18, T0, 3 * MONTH),
    }),
    milestoneParams({
      recipient: employee.account.address,
      shape: Shape.Segmented,
      start: T0,
      milestones: [
        { amount: 5_000n * E18, timestamp: T0 + 2 * MONTH },
        { amount: 0n, timestamp: T0 + 5 * MONTH },
        { amount: 15_000n * E18, timestamp: T0 + 12 * MONTH },
      ],
    }),
  ],
]);

await mkdir(OUT_DIR, { recursive: true });
async function snapshot(label: string): Promise<void> {
  for (const id of [1n, 2n, 3n]) {
    const { metadata, svg } = decodeTokenUri(await vesting.read.tokenURI([id]));
    const file = path.join(OUT_DIR, `${label}-stream-${id}.svg`);
    await writeFile(file, svg);
    const streamed = await vesting.read.streamedAmountOf([id]);
    const status = STATUS[await vesting.read.statusOf([id])];
    console.log(
      `  #${id} ${metadata.attributes[0]?.value}: ${status}, streamed ${formatUnits(streamed, 18)} DEMO -> ${path.relative(process.cwd(), file)}`,
    );
  }
}

console.log("Month 4:");
await networkHelpers.time.increaseTo(T0 + 4 * MONTH);
await snapshot("month-04");

await vesting.write.withdrawMax([1n, employee.account.address], { account: employee.account });
await vesting.write.cancel([3n]);
console.log("\nMonth 7 (after a withdrawal on #1 and the sender canceling #3 at month 4):");
await networkHelpers.time.increaseTo(T0 + 7 * MONTH);
await snapshot("month-07");

console.log("\nMonth 13:");
await networkHelpers.time.increaseTo(T0 + 13 * MONTH);
await snapshot("month-13");
console.log(`\nEmployee balance: ${formatUnits(await demoToken.read.balanceOf([employee.account.address]), 18)} DEMO`);
