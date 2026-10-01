// SPDX-License-Identifier: MIT
import { network } from "hardhat";
import { toHex } from "viem";

import DemoModule from "../../ignition/modules/Demo.js";

import {
  DAY,
  E18,
  E6,
  MONTH,
  Shape,
  T0,
  YEAR,
  evenMilestones,
  linearParams,
  milestoneParams,
  type CreateParams,
} from "./params.js";

export type Connection = Awaited<ReturnType<typeof network.create>>;

/** Deploys the protocol and the demo token through the Ignition module, plus a 6-decimal mock stablecoin. */
export async function deployAll(connection: Connection) {
  const { viem, ignition } = connection;
  const { renderer, vesting, demoToken } = await ignition.deploy(DemoModule);
  const [deployer, alice, bob, carol] = await viem.getWalletClients();
  if (deployer === undefined || alice === undefined || bob === undefined || carol === undefined) {
    throw new Error("expected at least four wallet clients");
  }
  const usd = await viem.deployContract("MockERC20", ["Mock USD", "mUSD", 6]);
  await usd.write.mint([deployer.account.address, 10n ** 12n * E6]);
  await usd.write.approve([vesting.address, 2n ** 256n - 1n]);
  return { renderer, vesting, demoToken, usd, deployer, alice, bob, carol };
}

/** Time at which every golden image is rendered: 7.5 months after T0. */
export const RENDER_TIME = T0 + 7 * MONTH + 15 * DAY;

/**
 * The deterministic scenario behind the golden files. Every transaction is pinned to an explicit timestamp, so the
 * rendered SVGs are byte-for-byte reproducible on any machine.
 */
export async function buildGoldenScenario(connection: Connection) {
  const { viem, networkHelpers } = connection;
  const deployed = await deployAll(connection);
  const { vesting, demoToken, usd, alice, bob, carol, deployer } = deployed;
  const at = async (timestamp: number) => networkHelpers.time.setNextBlockTimestamp(timestamp);

  const hostile = await viem.deployContract("RawSymbolToken", [toHex('<b>"Q&A\'s"</b>'), 18]);
  await hostile.write.mint([deployer.account.address, 1_000n * E18]);
  await hostile.write.approve([vesting.address, 1_000n * E18]);

  const usdStreams: CreateParams[] = [
    linearParams({
      recipient: alice.account.address,
      deposit: 120_000n * E6,
      start: T0,
      cliff: T0 + 3 * MONTH,
      end: T0 + 12 * MONTH,
    }),
    linearParams({ recipient: bob.account.address, deposit: 9_999n * E6 + 990_000n, start: T0, end: T0 + 6 * MONTH }),
    milestoneParams({
      recipient: bob.account.address,
      shape: Shape.Segmented,
      start: T0,
      milestones: evenMilestones(16, 0n, T0, MONTH / 2).map((m, i) => ({
        ...m,
        amount: BigInt(i + 1) * 1_000n * E6 + 123_456n,
      })),
    }),
  ];
  const demoStreams: CreateParams[] = [
    linearParams({
      recipient: bob.account.address,
      deposit: 50_000n * E18,
      start: T0 + 8 * MONTH,
      end: T0 + 20 * MONTH,
      cancelable: false,
    }),
    milestoneParams({
      recipient: carol.account.address,
      shape: Shape.Tranched,
      start: T0,
      milestones: evenMilestones(12, 1_000n * E18, T0, MONTH),
    }),
    milestoneParams({
      recipient: alice.account.address,
      shape: Shape.Segmented,
      start: T0,
      milestones: [
        { amount: 10_000n * E18, timestamp: T0 + 2 * MONTH },
        { amount: 0n, timestamp: T0 + 4 * MONTH },
        { amount: 30_000n * E18, timestamp: T0 + 6 * MONTH },
        { amount: 60_000n * E18, timestamp: T0 + 12 * MONTH },
      ],
    }),
    milestoneParams({
      recipient: carol.account.address,
      shape: Shape.Tranched,
      start: T0,
      milestones: evenMilestones(32, 250n * E18, T0, 10 * DAY),
    }),
    linearParams({ recipient: alice.account.address, deposit: 1_000n * E18, start: T0, end: T0 + MONTH }),
  ];

  await at(T0);
  await vesting.write.createBatch([usd.address, usdStreams]);
  await at(T0 + 60);
  await vesting.write.createBatch([demoToken.address, demoStreams]);
  await at(T0 + 120);
  await vesting.write.create([
    hostile.address,
    linearParams({ recipient: carol.account.address, deposit: 777n * E18, start: T0, end: T0 + 10 * MONTH }),
  ]);
  // Dust: a non-zero amount below 0.0001 tokens is displayed as `<0.0001`, which is markup unless escaped.
  await at(T0 + 180);
  await vesting.write.createBatch([
    demoToken.address,
    [
      // 10,000 DEMO over four years, rendered one second after its start: 0.00008 DEMO streamed and withdrawable.
      linearParams({
        recipient: bob.account.address,
        deposit: 10_000n * E18,
        start: RENDER_TIME - 1,
        end: RENDER_TIME - 1 + 4 * YEAR,
      }),
      // 100 DEMO over two months, canceled one second before the end: a dust refund, displayed for good.
      linearParams({ recipient: carol.account.address, deposit: 100n * E18, start: T0, end: T0 + 2 * MONTH }),
    ],
  ]);

  const ids = {
    linearCliff: 1n,
    linearSettled: 2n,
    segmented16: 3n,
    linearPending: 4n,
    tranched12: 5n,
    segmentedCanceled: 6n,
    tranched32: 7n,
    linearDepleted: 8n,
    hostileSymbol: 9n,
    linearDust: 10n,
    canceledDust: 11n,
  } as const;

  await at(T0 + MONTH + DAY);
  await vesting.write.withdrawMax([ids.linearDepleted, alice.account.address], { account: alice.account });
  await at(T0 + 2 * MONTH - 1);
  await vesting.write.cancel([ids.canceledDust]);
  await at(T0 + 5 * MONTH);
  await vesting.write.withdraw([ids.linearCliff, alice.account.address, 20_000n * E6], { account: alice.account });
  await at(T0 + 5 * MONTH + 60);
  await vesting.write.cancel([ids.segmentedCanceled]);
  await at(T0 + 7 * MONTH);
  await vesting.write.withdrawMax([ids.tranched12, carol.account.address], { account: carol.account });
  await networkHelpers.time.increaseTo(RENDER_TIME);

  return { ...deployed, hostile, ids };
}
