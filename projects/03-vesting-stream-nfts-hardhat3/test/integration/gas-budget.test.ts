// SPDX-License-Identifier: MIT
import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { network } from "hardhat";
import { decodeFunctionResult, encodeFunctionData, toHex } from "viem";

import { DAY, Shape, T0, evenMilestones, milestoneParams } from "../support/params.js";

/** Budget from the spec: rendering the worst-case stream must stay under 3,000,000 gas in `eth_estimateGas`. */
const TOKEN_URI_GAS_BUDGET = 3_000_000n;

describe("tokenURI gas budget (eth_estimateGas)", async () => {
  const { viem, networkHelpers } = await network.create();
  const publicClient = await viem.getPublicClient();
  const [sender, recipient] = await viem.getWalletClients();
  assert.ok(sender !== undefined && recipient !== undefined);
  const caller = sender.account.address;

  const renderer = await viem.deployContract("StreamRenderer");
  const vesting = await viem.deployContract("VestingStreams", [renderer.address, sender.account.address]);
  // A 16-character symbol made of characters that all expand when escaped, and odd decimals.
  const token = await viem.deployContract("RawSymbolToken", [toHex(`<&>"'<&>"'<&>"'<&`), 17]);
  await token.write.mint([sender.account.address, 10n ** 40n]);
  await token.write.approve([vesting.address, 10n ** 40n]);

  // Amounts just below uint128 / 32 per milestone give the longest formatted numbers.
  const big = (2n ** 128n - 1n) / 33n;
  await vesting.write.createBatch([
    token.address,
    [
      milestoneParams({
        recipient: recipient.account.address,
        shape: Shape.Segmented,
        start: T0,
        milestones: evenMilestones(16, big, T0, 7 * DAY),
      }),
      milestoneParams({
        recipient: recipient.account.address,
        shape: Shape.Tranched,
        start: T0,
        milestones: evenMilestones(32, big, T0, 3 * DAY),
      }),
    ],
  ]);
  await networkHelpers.time.increaseTo(T0 + 50 * DAY); // mid-schedule: every curve point and the marker are live

  async function estimateTokenUri(streamId: bigint): Promise<bigint> {
    return publicClient.estimateGas({
      account: caller,
      to: vesting.address,
      data: encodeFunctionData({ abi: vesting.abi, functionName: "tokenURI", args: [streamId] }),
    });
  }

  async function callTokenUriWithBudget(streamId: bigint): Promise<string> {
    const { data } = await publicClient.call({
      account: caller,
      to: vesting.address,
      gas: TOKEN_URI_GAS_BUDGET,
      data: encodeFunctionData({ abi: vesting.abi, functionName: "tokenURI", args: [streamId] }),
    });
    assert.ok(data !== undefined);
    return decodeFunctionResult({ abi: vesting.abi, functionName: "tokenURI", data });
  }

  it("worst-case 16-segment stream renders under 3,000,000 gas", async () => {
    const gas = await estimateTokenUri(1n);
    console.log(`      tokenURI(16 segments) eth_estimateGas = ${gas}`);
    assert.ok(gas < TOKEN_URI_GAS_BUDGET, `tokenURI used ${gas} gas`);
  });

  it("worst-case 32-tranche stream renders under 3,000,000 gas", async () => {
    const gas = await estimateTokenUri(2n);
    console.log(`      tokenURI(32 tranches) eth_estimateGas = ${gas}`);
    assert.ok(gas < TOKEN_URI_GAS_BUDGET, `tokenURI used ${gas} gas`);
  });

  it("a token whose symbol() burns all forwarded gas still renders with the budget as the call's gas limit", async () => {
    // eth_estimateGas refuses to estimate here (by design, EDR reports that an inner call runs out of gas no matter
    // the limit), so the budget is enforced directly as the gas limit of the eth_call.
    await token.write.setSymbol(["0x", 3]); // SymbolMode.BurnGas
    const uri = await callTokenUriWithBudget(1n);
    assert.ok(uri.includes("base64,"));
    await token.write.setSymbol([toHex("SYM"), 0]);
  });

  it("the 32-tranche stream also renders in an eth_call capped at the budget", async () => {
    const uri = await callTokenUriWithBudget(2n);
    assert.ok(uri.startsWith("data:application/json;base64,") && uri.length > 1_000);
    assert.ok(big * 32n <= 2n ** 128n - 1n, "precondition: the 32 tranches fit in a uint128 deposit");
  });
});
