// SPDX-License-Identifier: MIT
import { toHex, type Address } from "viem";

import { DAY, Shape, YEAR, T0, evenMilestones, milestoneParams } from "./params.js";
import type { Connection } from "./scenario.js";

/** Largest deposit a stream can hold. */
export const MAX_UINT128 = 2n ** 128n - 1n;

/**
 * Rendering stress case. Everything that makes `tokenURI` longer is maxed out at once:
 *
 * - the most milestones a stream can have (32 tranches, each drawn as two chart points; 16 segments);
 * - deposits close to `2^128`, rendered with 0 decimals, so every amount row is a 39-digit number with 12 separators;
 * - a large withdrawal, then a cancellation, so all four amount rows are long and the art adds the cancel marker, the
 *   REFUNDED row and the cancellation date;
 * - a 16-character symbol (the sanitizer's maximum) made of `"`, the character with the longest escape in both
 *   grammars: `&quot;` in the SVG (four times) and `\"` in the JSON (twice).
 *
 * A token whose `symbol()` or `decimals()` burns the whole 50,000 gas cap is a separate case: `eth_estimateGas` cannot
 * estimate it on EDR, so the gas-budget test checks it with an `eth_call` capped at the budget instead.
 */
export const STRESS_SYMBOL = '"'.repeat(16);

/** Start of both stress streams; later than every timestamp the gas-table scenario uses before it. */
export const STRESS_START = T0 + YEAR;

/**
 * Creates the two stress-case streams on `vesting` and drives them to the state described above. Every block is
 * pinned to `STRESS_START + offset`, so the gas of rendering them is reproducible.
 */
export async function createStressStreams(connection: Connection, vestingAddress: Address) {
  const { viem, networkHelpers } = connection;
  const [sender, recipient] = await viem.getWalletClients();
  if (sender === undefined || recipient === undefined) throw new Error("expected two wallet clients");
  const by = (wallet: typeof sender) => ({ account: wallet.account });
  const at = (offset: number) => networkHelpers.time.setNextBlockTimestamp(STRESS_START + offset);
  const vesting = await viem.getContractAt("VestingStreams", vestingAddress);

  await at(-3);
  const token = await viem.deployContract("RawSymbolToken", [toHex(STRESS_SYMBOL), 0]);
  await at(-2);
  await token.write.mint([sender.account.address, MAX_UINT128 * 2n], by(sender));
  await at(-1);
  await token.write.approve([vesting.address, MAX_UINT128 * 2n], by(sender));

  const tranche = MAX_UINT128 / 32n;
  const segment = MAX_UINT128 / 16n;
  const tranched = await vesting.read.nextStreamId();
  const segmented = tranched + 1n;
  const to = recipient.account.address;
  await at(0);
  await vesting.write.createBatch(
    [
      token.address,
      [
        milestoneParams({
          recipient: to,
          shape: Shape.Tranched,
          start: STRESS_START,
          milestones: evenMilestones(32, tranche, STRESS_START, 10 * DAY),
        }),
        milestoneParams({
          recipient: to,
          shape: Shape.Segmented,
          start: STRESS_START,
          milestones: evenMilestones(16, segment, STRESS_START, 20 * DAY),
        }),
      ],
    ],
    by(sender),
  );
  // 200 days in: 20 of 32 tranches and 10 of 16 segments have vested.
  await at(200 * DAY);
  await vesting.write.withdraw([tranched, to, 10n * tranche], by(recipient));
  await at(200 * DAY + 60);
  await vesting.write.withdraw([segmented, to, 5n * segment], by(recipient));
  await at(200 * DAY + 120);
  await vesting.write.cancel([tranched], by(sender));
  await at(200 * DAY + 180);
  await vesting.write.cancel([segmented], by(sender));
  return { token, tranched, segmented };
}
